use crate::model::{Pack, Phases, Preset, safe_filename};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    io::{Cursor, Read, Write},
    path::{Component, Path},
};
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

pub const MAX_ARCHIVE: usize = 128 * 1024 * 1024;
pub type Files = BTreeMap<String, Vec<u8>>;

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PresetBundle {
    pub schema_version: u32,
    pub preset: Preset,
    pub packs: Vec<Pack>,
}

pub struct PackFiles {
    pub pack: Pack,
    pub files: Files,
}

pub fn read_zip(bytes: &[u8]) -> Result<Files, String> {
    if bytes.len() > MAX_ARCHIVE {
        return Err("The bundle is larger than 128 MB.".into());
    }
    let mut zip =
        ZipArchive::new(Cursor::new(bytes)).map_err(|e| format!("Cannot read ZIP: {e}"))?;
    if zip.len() > 4096 {
        return Err("The bundle contains too many files.".into());
    }
    let mut files = Files::new();
    let mut names = HashSet::new();
    let mut total = 0usize;
    for index in 0..zip.len() {
        let mut entry = zip.by_index(index).map_err(|e| e.to_string())?;
        let enclosed = entry
            .enclosed_name()
            .ok_or("The bundle contains a path outside its folder.")?;
        if entry.is_symlink()
            || Path::new(entry.name())
                .components()
                .any(|c| !matches!(c, Component::Normal(_)))
            || entry.name().contains('\\')
            || entry.name().contains(':')
            || entry.name().chars().any(char::is_control)
        {
            return Err("The bundle contains an unsafe path or symbolic link.".into());
        }
        if entry.is_dir() {
            continue;
        }
        let name = enclosed
            .to_str()
            .ok_or("A bundle path is not UTF-8.")?
            .to_string();
        if !names.insert(name.to_lowercase()) {
            return Err("The bundle contains duplicate file names.".into());
        }
        if entry.size() > MAX_ARCHIVE as u64
            || total.saturating_add(entry.size() as usize) > MAX_ARCHIVE
        {
            return Err("The expanded bundle is larger than 128 MB.".into());
        }
        let remaining = MAX_ARCHIVE - total;
        let mut data = vec![];
        (&mut entry)
            .take(remaining as u64 + 1)
            .read_to_end(&mut data)
            .map_err(|e| e.to_string())?;
        if data.len() > remaining {
            return Err("The expanded bundle is larger than 128 MB.".into());
        }
        total += data.len();
        files.insert(name, data);
    }
    Ok(files)
}

pub fn write_zip(files: &Files) -> Result<Vec<u8>, String> {
    let mut writer = ZipWriter::new(Cursor::new(vec![]));
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for (name, data) in files {
        writer
            .start_file(name, options)
            .map_err(|e| e.to_string())?;
        writer.write_all(data).map_err(|e| e.to_string())?;
    }
    Ok(writer.finish().map_err(|e| e.to_string())?.into_inner())
}

pub fn fingerprint(pack: &Pack, files: &Files) -> Result<String, String> {
    let mut descriptor = pack.clone();
    descriptor.id.clear();
    descriptor.version.clear();
    let mut hash = Sha256::new();
    let manifest = serde_json::to_vec(&descriptor).map_err(|e| e.to_string())?;
    hash.update((manifest.len() as u64).to_le_bytes());
    hash.update(manifest);
    for (name, data) in files {
        hash.update((name.len() as u64).to_le_bytes());
        hash.update(name.as_bytes());
        hash.update((data.len() as u64).to_le_bytes());
        hash.update(data);
    }
    Ok(format!("{:x}", hash.finalize()))
}

pub fn seal(mut pack: Pack, files: Files) -> Result<PackFiles, String> {
    pack.validate()?;
    for filename in pack.files.values().chain(pack.sprite_file.iter()) {
        if !files.contains_key(filename) {
            return Err("The pack is missing a required audio file.".into());
        }
    }
    pack.version = fingerprint(&pack, &files)?;
    pack.id = format!("pack-{}", pack.version);
    Ok(PackFiles { pack, files })
}

pub fn read_manifest<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, String> {
    if bytes.len() > 1024 * 1024 {
        return Err("The manifest is larger than 1 MB.".into());
    }
    serde_json::from_slice(bytes).map_err(|e| format!("Invalid sound manifest: {e}"))
}

pub fn audio_file(path: &Path, bytes: Vec<u8>) -> Result<PackFiles, String> {
    let extension = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if !["wav", "mp3", "ogg", "flac"].contains(&extension.as_str()) {
        return Err("Choose a WAV, MP3, OGG, or FLAC recording.".into());
    }
    let name = path
        .file_stem()
        .and_then(|n| n.to_str())
        .unwrap_or("Imported recording")
        .chars()
        .take(80)
        .collect::<String>();
    let filename = format!("sound.{extension}");
    let pack = Pack {
        id: "imported".into(),
        original_id: "recording".into(),
        version: String::new(),
        source_id: String::new(),
        name,
        brand: "Your recordings".into(),
        kind: "Custom".into(),
        color: "#9aabd1".into(),
        description: "Your own sound, on every key.".into(),
        author: "Not specified".into(),
        supports_key_up: false,
        sample_count: 1,
        source: String::new(),
        license: serde_json::json!({"type":"Not specified","url":""}),
        credits: "User-imported recording. Author and license were not supplied.".into(),
        files: BTreeMap::from([("sound".into(), filename.clone())]),
        sprite_file: None,
        sprite: BTreeMap::new(),
        sounds: BTreeMap::from([(
            "default".into(),
            Phases {
                down: vec!["sound".into()],
                up: vec![],
            },
        )]),
    };
    seal(pack, BTreeMap::from([(filename, bytes)]))
}

#[derive(Deserialize)]
struct Thock {
    id: String,
    metadata: ThockMetadata,
    license: serde_json::Value,
    sounds: BTreeMap<String, Phases>,
}
#[derive(Deserialize)]
struct ThockMetadata {
    name: String,
    brand: String,
    author: String,
}

pub fn thock(files: Files) -> Result<PackFiles, String> {
    let source: Thock = read_manifest(
        files
            .get("config.json")
            .ok_or("Choose a Thock pack with config.json at the ZIP root.")?,
    )?;
    let mut assets = Files::new();
    let mut mapping = BTreeMap::new();
    let mut source_names: BTreeMap<String, String> = BTreeMap::new();
    let mut sounds = BTreeMap::new();
    for (key, phases) in source.sounds {
        // These reviewed Cherry archives label their scan-code 14 recording as "del".
        let cherry_backspace = key == "del"
            && phases.down == ["14.wav"]
            && [
                "de401889-0ccb-4522-a213-836aad88c447",
                "980c6cc1-7daf-4584-8b0e-643b3a811a6d",
                "cf535c6d-9cc7-46a0-bf53-af6d3aeef534",
                "ca2d54d7-31d0-4177-b26a-43d99a3bcaaf",
                "186ca33e-9998-4a28-974c-c21ac353c16e",
                "3aa3c556-ab47-4ab9-a791-498bf9910bf7",
                "31071be3-c9ad-44a4-8d38-aaa7fe414a58",
                "e05fa018-400e-4d9c-b357-d5467b07650c",
            ]
            .contains(&source.id.as_str());
        let aliases = if cherry_backspace {
            vec!["Backspace".into()]
        } else {
            thock_key(&key)
        };
        let mut convert = |names: Vec<String>| -> Result<Vec<String>, String> {
            names
                .into_iter()
                .map(|name| {
                    if let Some(id) = source_names.get(&name) {
                        return Ok(id.clone());
                    }
                    if !safe_filename(&name) {
                        return Err("Sound references must use plain file names.".into());
                    }
                    let data = files
                        .get(&name)
                        .ok_or("A sound referenced in config.json is missing.")?;
                    let extension = Path::new(&name)
                        .extension()
                        .and_then(|e| e.to_str())
                        .unwrap_or("")
                        .to_ascii_lowercase();
                    if !["wav", "mp3", "ogg", "flac"].contains(&extension.as_str()) {
                        return Err("This pack uses an unsupported audio format.".into());
                    }
                    let id = format!("clip-{}", source_names.len());
                    let filename = format!("{id}.{extension}");
                    mapping.insert(id.clone(), filename.clone());
                    assets.insert(filename, data.clone());
                    source_names.insert(name, id.clone());
                    Ok(id)
                })
                .collect()
        };
        let normalized = Phases {
            down: convert(phases.down)?,
            up: convert(phases.up)?,
        };
        for alias in aliases {
            if sounds.insert(alias, normalized.clone()).is_some() {
                return Err("Two source keys map to the same logical key.".into());
            }
        }
    }
    let mut credits = format!(
        "{} - {}\nAuthor: {}\nSource pack: {}\nLicense declaration: {}\n",
        source.metadata.brand,
        source.metadata.name,
        source.metadata.author,
        source.id,
        source.license
    );
    for (name, bytes) in &files {
        if name.to_ascii_lowercase().contains("license")
            || name.to_ascii_lowercase().contains("notice")
        {
            if bytes.len() > 128 * 1024 {
                return Err("A credit file is too large.".into());
            }
            credits.push('\n');
            credits
                .push_str(std::str::from_utf8(bytes).map_err(|_| "Credits must be UTF-8 text.")?);
        }
    }
    let pack = Pack {
        id: "imported".into(),
        original_id: source.id.clone(),
        source_id: source.id,
        version: String::new(),
        name: source.metadata.name,
        brand: source.metadata.brand,
        author: source.metadata.author,
        kind: "Imported".into(),
        description: "Imported from a compatible Thock sound pack.".into(),
        color: "#a6b890".into(),
        supports_key_up: sounds.values().any(|p| !p.up.is_empty()),
        sample_count: assets.len(),
        source: String::new(),
        license: source.license,
        credits,
        files: mapping,
        sprite_file: None,
        sprite: BTreeMap::new(),
        sounds,
    };
    seal(pack, assets)
}

fn thock_key(key: &str) -> Vec<String> {
    let named = match key {
        "default" => "default",
        "space" => "Space",
        "enter" => "Enter",
        "tab" => "Tab",
        "esc" => "Escape",
        "backspace" => "Backspace",
        "del" => "Delete",
        "capsLock" => "CapsLock",
        "fn" => "Fn",
        "shiftLeft" => "ShiftLeft",
        "shiftRight" => "ShiftRight",
        "ctrlLeft" => "ControlLeft",
        "ctrlRight" => "ControlRight",
        "optionLeft" => "AltLeft",
        "optionRight" => "AltRight",
        "arrLeft" => "ArrowLeft",
        "arrRight" => "ArrowRight",
        "arrUp" => "ArrowUp",
        "arrDown" => "ArrowDown",
        "home" => "Home",
        "end" => "End",
        "pgUp" => "PageUp",
        "pgDn" => "PageDown",
        "`" => "Backquote",
        "-" => "Minus",
        "=" => "Equal",
        "[" => "BracketLeft",
        "]" => "BracketRight",
        "\\" => "Backslash",
        ";" => "Semicolon",
        "'" => "Quote",
        "," => "Comma",
        "." => "Period",
        "/" => "Slash",
        "command" => return vec!["MetaLeft".into(), "MetaRight".into()],
        _ if key.len() == 1 && key.as_bytes()[0].is_ascii_lowercase() => {
            return vec![format!("Key{}", key.to_uppercase())];
        }
        _ if key.len() == 1 && key.as_bytes()[0].is_ascii_digit() => {
            return vec![format!("Digit{key}")];
        }
        _ if key
            .strip_prefix('f')
            .and_then(|n| n.parse::<u8>().ok())
            .is_some_and(|n| (1..=24).contains(&n)) =>
        {
            return vec![key.to_uppercase()];
        }
        _ => key,
    };
    vec![named.into()]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn compatible_import_preserves_variants_silence_and_pack_specific_aliases() {
        let mut config = serde_json::json!({
            "id": "cf535c6d-9cc7-46a0-bf53-af6d3aeef534",
            "metadata": {"name":"Blue ABS", "brand":"Cherry MX", "author":"mechvibes"},
            "license": {"type":"MIT", "url":""},
            "sounds": {
                "default": {"down":["20.wav", "21.wav"], "up":[]},
                "del": {"down":["14.wav"], "up":[]},
                "command": {"down":["20.wav", "21.wav"], "up":[]},
                "space": {"down":[], "up":[]}
            }
        });
        let mut files = Files::from([
            ("20.wav".into(), vec![1]),
            ("21.wav".into(), vec![2]),
            ("14.wav".into(), vec![3]),
        ]);
        files.insert("config.json".into(), serde_json::to_vec(&config).unwrap());
        let imported = thock(read_zip(&write_zip(&files).unwrap()).unwrap()).unwrap();
        assert!(imported.pack.sounds.contains_key("Backspace"));
        assert!(!imported.pack.sounds.contains_key("Delete"));
        assert_eq!(imported.pack.sounds["MetaLeft"].down.len(), 2);
        assert_eq!(imported.pack.sounds["MetaRight"].down.len(), 2);
        assert!(imported.pack.sounds["Space"].down.is_empty());
        assert!(!imported.pack.supports_key_up);
        config["id"] = "unrelated-third-party-pack".into();
        files.insert("config.json".into(), serde_json::to_vec(&config).unwrap());
        let imported = thock(files).unwrap();
        assert!(imported.pack.sounds.contains_key("Delete"));
        assert!(!imported.pack.sounds.contains_key("Backspace"));
    }
    #[test]
    fn rejects_archive_traversal_and_duplicate_paths() {
        let traversal = write_zip(&BTreeMap::from([("../outside.wav".into(), vec![0])])).unwrap();
        assert!(read_zip(&traversal).is_err());
        let duplicate = write_zip(&BTreeMap::from([
            ("A.wav".into(), vec![0]),
            ("a.wav".into(), vec![1]),
        ]))
        .unwrap();
        assert!(read_zip(&duplicate).is_err());
        let safe = BTreeMap::from([("clips/a.wav".into(), vec![1, 2, 3])]);
        assert_eq!(read_zip(&write_zip(&safe).unwrap()).unwrap(), safe);
    }
}
