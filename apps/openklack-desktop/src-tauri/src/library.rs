use crate::{
    audio,
    model::{Pack, Preferences, Preset},
    pack_io::{self, Files, PackFiles, PresetBundle},
};
use std::{
    collections::{BTreeMap, HashSet},
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Mutex, RwLock,
        atomic::{AtomicU64, Ordering},
    },
};

pub struct Library {
    root: PathBuf,
    resources: PathBuf,
    packs: RwLock<Vec<Pack>>,
    import_lock: Mutex<()>,
    pub warnings: Vec<String>,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Imported {
    pub pack_ids: Vec<String>,
    pub preset: Option<Preset>,
}

impl Library {
    pub fn open(resources: PathBuf, data: &Path) -> Result<Self, String> {
        let root = data.join("packs");
        fs::create_dir_all(&root).map_err(|e| e.to_string())?;
        let mut packs = vec![];
        let mut warnings = vec![];
        for entry in fs::read_dir(&root).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            if !entry.file_type().map_err(|e| e.to_string())?.is_dir()
                || entry.file_name().to_string_lossy().starts_with('.')
            {
                continue;
            }
            let read_pack = || -> Result<Pack, String> {
                let pack: Pack = pack_io::read_manifest(&read_limited(
                    &entry.path().join("pack.json"),
                    1024 * 1024,
                )?)?;
                pack.validate()?;
                if entry.file_name().to_str() != Some(pack.id.as_str()) {
                    return Err("Inconsistent pack metadata.".into());
                }
                Ok(pack)
            };
            match read_pack() {
                Ok(pack) => packs.push(pack),
                Err(_) => warnings.push("An installed pack could not be read. Its files have been kept; reimport the original pack to repair it.".into()),
            }
        }
        let library = Self {
            root,
            resources,
            packs: RwLock::new(packs),
            import_lock: Mutex::new(()),
            warnings,
        };
        let bundled: Vec<Pack> = pack_io::read_manifest(&read_limited(
            &library.resources.join("soundpacks.json"),
            1024 * 1024,
        )?)?;
        for pack in bundled {
            if !library
                .packs
                .read()
                .unwrap()
                .iter()
                .any(|p| p.original_id == pack.id)
            {
                let content = library.bundled_pack(pack)?;
                library.install(&content)?;
                library.packs.write().unwrap().push(content.pack);
            }
        }
        Ok(library)
    }

    pub fn catalog(&self) -> Vec<Pack> {
        self.packs.read().unwrap().clone()
    }
    pub fn pack(&self, id: &str) -> Result<Pack, String> {
        self.packs
            .read()
            .unwrap()
            .iter()
            .find(|p| p.id == id)
            .cloned()
            .ok_or("This sound pack is not installed.".into())
    }
    pub fn verified_directory(&self, id: &str) -> Result<PathBuf, String> {
        let pack = self.pack(id)?;
        let directory = self.root.join(id);
        if !directory
            .symlink_metadata()
            .map_err(|e| e.to_string())?
            .file_type()
            .is_dir()
        {
            return Err("The installed pack is not a regular directory.".into());
        }
        let mut assets = Files::new();
        let mut total = 0usize;
        for name in pack.files.values().chain(pack.sprite_file.iter()) {
            let bytes = read_limited(&directory.join(name), pack_io::MAX_ARCHIVE - total)?;
            total += bytes.len();
            assets.insert(name.clone(), bytes);
        }
        if pack.version != pack_io::fingerprint(&pack, &assets)?
            || pack.id != format!("pack-{}", pack.version)
        {
            return Err(format!(
                "{} has changed on disk. Reimport its original recording before using it.",
                pack.name
            ));
        }
        Ok(directory)
    }

    pub fn migrate_preferences(&self, prefs: &mut Preferences) {
        let packs = self.packs.read().unwrap();
        let migrate = |id: &mut String| {
            if !packs.iter().any(|p| p.id == *id)
                && let Some(pack) = packs.iter().find(|p| p.original_id == *id)
            {
                *id = pack.id.clone();
            }
        };
        for preset in &mut prefs.presets {
            migrate(&mut preset.pack_id);
            for voice in preset.overrides.values_mut() {
                migrate(&mut voice.pack_id);
            }
        }
    }

    fn bundled_pack(&self, mut pack: Pack) -> Result<PackFiles, String> {
        let audio = read_limited(
            &self
                .resources
                .join("sounds")
                .join(format!("{}.ogg", pack.id)),
            pack_io::MAX_ARCHIVE,
        )?;
        pack.original_id = pack.id.clone();
        pack.sprite_file = Some("audio.ogg".into());
        pack.credits = String::from_utf8(read_limited(
            &self.resources.join("sounds/NOTICE.txt"),
            262_144,
        )?)
        .map_err(|e| e.to_string())?;
        pack_io::seal(pack, BTreeMap::from([("audio.ogg".into(), audio)]))
    }

    pub fn install_bundled_updates(&self) -> Result<usize, String> {
        let _lock = self.import_lock.lock().unwrap();
        let bundled: Vec<Pack> = pack_io::read_manifest(&read_limited(
            &self.resources.join("soundpacks.json"),
            1024 * 1024,
        )?)?;
        let mut added = 0;
        for pack in bundled {
            let content = self.bundled_pack(pack)?;
            if self.pack(&content.pack.id).is_err() {
                self.install(&content)?;
                self.packs.write().unwrap().push(content.pack);
                added += 1;
            }
        }
        Ok(added)
    }

    pub fn import(&self, path: &Path) -> Result<Imported, String> {
        let _lock = self.import_lock.lock().unwrap();
        let bytes = read_limited(path, pack_io::MAX_ARCHIVE)?;
        let extension = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let (contents, mut preset) = if ["zip", "openklack"].contains(&extension.as_str()) {
            let mut files = pack_io::read_zip(&bytes)?;
            if let Some(manifest) = files.remove("preset.json") {
                let bundle: PresetBundle = pack_io::read_manifest(&manifest)?;
                if bundle.schema_version != 1 || bundle.packs.len() > 32 || bundle.packs.is_empty()
                {
                    return Err("Unsupported preset bundle version or pack count.".into());
                }
                let mut contents = vec![];
                let mut seen = HashSet::new();
                for pack in bundle.packs {
                    pack.validate()?;
                    if !seen.insert(pack.id.clone()) {
                        return Err("The preset contains duplicate pack identifiers.".into());
                    }
                    let mut assets = Files::new();
                    for name in pack.files.values().chain(pack.sprite_file.iter()) {
                        let path = format!("packs/{}/{}", pack.id, name);
                        assets.insert(
                            name.clone(),
                            files
                                .get(&path)
                                .ok_or("The preset is missing required audio.")?
                                .clone(),
                        );
                    }
                    if pack.version != pack_io::fingerprint(&pack, &assets)?
                        || pack.id != format!("pack-{}", pack.version)
                    {
                        return Err(
                            "A bundled recording does not match its declared version.".into()
                        );
                    }
                    contents.push(PackFiles {
                        pack,
                        files: assets,
                    });
                }
                let check = Preferences {
                    active_preset_id: bundle.preset.id.clone(),
                    presets: vec![bundle.preset.clone()],
                    ..Preferences::default()
                };
                check.validate(&contents.iter().map(|p| p.pack.clone()).collect::<Vec<_>>())?;
                (contents, Some(bundle.preset))
            } else {
                (vec![pack_io::thock(files)?], None)
            }
        } else {
            (vec![pack_io::audio_file(path, bytes)?], None)
        };
        let added = contents
            .iter()
            .filter(|p| self.pack(&p.pack.id).is_err())
            .count();
        if self.packs.read().unwrap().len() + added > 500 {
            return Err("The library supports up to 500 installed pack versions.".into());
        }
        // Validate all recordings before installing any part of a preset bundle.
        for content in &contents {
            self.check_audio(content)?;
        }
        for content in &contents {
            self.install(content)?;
            let mut catalog = self.packs.write().unwrap();
            if !catalog.iter().any(|p| p.id == content.pack.id) {
                catalog.push(content.pack.clone());
            }
        }
        if let Some(preset) = &mut preset {
            preset.id = format!("imported-{}", unique_suffix());
        }
        Ok(Imported {
            pack_ids: contents.into_iter().map(|p| p.pack.id).collect(),
            preset,
        })
    }

    pub fn export(&self, preset: &Preset, destination: &Path) -> Result<(), String> {
        let mut ids = HashSet::from([preset.pack_id.clone()]);
        ids.extend(preset.overrides.values().map(|v| v.pack_id.clone()));
        let mut ids: Vec<_> = ids.into_iter().collect();
        ids.sort();
        let mut packs = vec![];
        let mut files = Files::new();
        let mut total = 0usize;
        for id in ids {
            let pack = self.pack(&id)?;
            let directory = self.verified_directory(&id)?;
            let license = pack
                .license
                .get("type")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if license.contains("proprietary") || license.contains("all rights reserved") {
                return Err(format!(
                    "{} declares restricted redistribution and cannot be bundled.",
                    pack.name
                ));
            }
            for name in pack.files.values().chain(pack.sprite_file.iter()) {
                let content = read_limited(&directory.join(name), pack_io::MAX_ARCHIVE - total)?;
                total = total.saturating_add(content.len());
                if total > pack_io::MAX_ARCHIVE {
                    return Err("This preset's audio is larger than 128 MB.".into());
                }
                files.insert(format!("packs/{id}/{name}"), content);
            }
            files.insert(
                format!("packs/{id}/CREDITS.txt"),
                pack.credits.as_bytes().to_vec(),
            );
            packs.push(pack);
        }
        let bundle = PresetBundle {
            schema_version: 1,
            preset: preset.clone(),
            packs,
        };
        let manifest = serde_json::to_vec_pretty(&bundle).map_err(|e| e.to_string())?;
        if manifest.len() > 1024 * 1024 {
            return Err("This preset's metadata is larger than 1 MB.".into());
        }
        files.insert("preset.json".into(), manifest);
        if files.values().map(Vec::len).sum::<usize>() > pack_io::MAX_ARCHIVE {
            return Err("This preset bundle is larger than 128 MB.".into());
        }
        let bytes = pack_io::write_zip(&files)?;
        if bytes.len() > pack_io::MAX_ARCHIVE {
            return Err("This preset bundle is larger than 128 MB.".into());
        }
        write_atomic(destination, &bytes)
    }

    fn install(&self, content: &PackFiles) -> Result<(), String> {
        let destination = self.root.join(&content.pack.id);
        if destination.exists() && self.verified_directory(&content.pack.id).is_ok() {
            return Ok(());
        }
        let staging = Staging::new(&self.root)?;
        write_content(content, &staging.0)?;
        let backup = self.root.join(format!(".recovery-{}", unique_suffix()));
        let repairing = destination.symlink_metadata().is_ok();
        if repairing {
            fs::rename(&destination, &backup).map_err(|e| e.to_string())?;
        }
        if let Err(error) = fs::rename(&staging.0, &destination) {
            if repairing {
                fs::rename(&backup, &destination).map_err(|rollback| {
                    format!("{error}; the original pack remains in its recovery folder: {rollback}")
                })?;
            }
            return Err(error.to_string());
        }
        Ok(())
    }

    fn check_audio(&self, content: &PackFiles) -> Result<(), String> {
        let staging = Staging::new(&self.root)?;
        write_content(content, &staging.0)?;
        audio::decode_pack(&content.pack, &staging.0)?;
        Ok(())
    }
}

fn write_content(content: &PackFiles, directory: &Path) -> Result<(), String> {
    for (name, bytes) in &content.files {
        if !crate::model::safe_filename(name) {
            return Err("Invalid audio file name.".into());
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(directory.join(name))
            .map_err(|e| e.to_string())?;
        file.write_all(bytes).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
    }
    fs::write(
        directory.join("pack.json"),
        serde_json::to_vec_pretty(&content.pack).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())
}

pub fn read_limited(path: &Path, limit: usize) -> Result<Vec<u8>, String> {
    let metadata = path.symlink_metadata().map_err(|e| e.to_string())?;
    if !metadata.file_type().is_file() || metadata.len() > limit as u64 {
        return Err("Choose a regular file within the size limit.".into());
    }
    let mut bytes = vec![];
    fs::File::open(path)
        .map_err(|e| e.to_string())?
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > limit {
        return Err("The file exceeds the size limit.".into());
    }
    Ok(bytes)
}

pub fn write_atomic(destination: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = destination
        .parent()
        .ok_or("The destination has no parent folder.")?;
    let staging = Staging::new(parent)?;
    let source = staging.0.join("export");
    let mut file = fs::File::create(&source).map_err(|e| e.to_string())?;
    file.write_all(bytes).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    fs::rename(source, destination).map_err(|e| e.to_string())
}

pub fn unique_suffix() -> String {
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    format!(
        "{}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    )
}
struct Staging(PathBuf);
impl Staging {
    fn new(parent: &Path) -> Result<Self, String> {
        let path = parent.join(format!(".openklack-{}", unique_suffix()));
        fs::create_dir(&path).map_err(|e| e.to_string())?;
        Ok(Self(path))
    }
}
impl Drop for Staging {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn individual_recordings_are_immutable_and_failed_imports_leave_them_intact() {
        let resources = Staging::new(&std::env::temp_dir()).unwrap();
        fs::write(resources.0.join("soundpacks.json"), b"[]").unwrap();
        let data = Staging::new(&std::env::temp_dir()).unwrap();
        let library = Library::open(resources.0.clone(), &data.0).unwrap();
        let mut wav = b"RIFF".to_vec();
        wav.extend(836_u32.to_le_bytes());
        wav.extend(b"WAVEfmt ");
        wav.extend(16_u32.to_le_bytes());
        wav.extend(1_u16.to_le_bytes());
        wav.extend(1_u16.to_le_bytes());
        wav.extend(8000_u32.to_le_bytes());
        wav.extend(16000_u32.to_le_bytes());
        wav.extend(2_u16.to_le_bytes());
        wav.extend(16_u16.to_le_bytes());
        wav.extend(b"data");
        wav.extend(800_u32.to_le_bytes());
        for index in 0..400 {
            wav.extend((if index % 2 == 0 { 500_i16 } else { -500_i16 }).to_le_bytes());
        }
        let recording = data.0.join("click.wav");
        fs::write(&recording, &wav).unwrap();
        let first = library.import(&recording).unwrap().pack_ids.remove(0);
        wav[44] = 9;
        fs::write(&recording, &wav).unwrap();
        let second = library.import(&recording).unwrap().pack_ids.remove(0);
        assert_ne!(first, second);
        assert_eq!(library.import(&recording).unwrap().pack_ids, [second]);
        assert_eq!(library.catalog().len(), 2);
        let original = library.verified_directory(&first).unwrap();
        assert_ne!(fs::read(original.join("sound.wav")).unwrap(), wav);
        fs::write(&recording, b"invalid audio").unwrap();
        assert!(library.import(&recording).is_err());
        assert_eq!(library.catalog().len(), 2);
        library.verified_directory(&first).unwrap();
        let broken = library.verified_directory(&first).unwrap();
        fs::write(broken.join("pack.json"), b"broken manifest").unwrap();
        let reopened = Library::open(resources.0.clone(), &data.0).unwrap();
        assert_eq!(reopened.catalog().len(), 1);
        assert_eq!(
            fs::read(broken.join("pack.json")).unwrap(),
            b"broken manifest"
        );
        wav[44] = 244; // Restore the original 500_i16 sample.
        fs::write(&recording, &wav).unwrap();
        assert_eq!(
            reopened.import(&recording).unwrap().pack_ids.as_slice(),
            std::slice::from_ref(&first)
        );
        fs::write(broken.join("sound.wav"), b"broken audio").unwrap();
        assert!(reopened.verified_directory(&first).is_err());
        reopened.import(&recording).unwrap();
        reopened.verified_directory(&first).unwrap();
    }
    #[test]
    fn preset_round_trip_keeps_audio_versions_assignments_and_credits() {
        let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let resources = Staging::new(&std::env::temp_dir()).unwrap();
        fs::copy(
            workspace.join("packages/soundpacks/catalog.json"),
            resources.0.join("soundpacks.json"),
        )
        .unwrap();
        std::os::unix::fs::symlink(
            workspace.join("packages/soundpacks/sounds"),
            resources.0.join("sounds"),
        )
        .unwrap();
        let data = Staging::new(&std::env::temp_dir()).unwrap();
        let library = Library::open(resources.0.clone(), &data.0).unwrap();
        let mut prefs = Preferences::default();
        library.migrate_preferences(&mut prefs);
        let mut preset = prefs.presets.remove(0);
        preset.overrides.insert(
            "Space".into(),
            crate::model::Assignment {
                pack_id: library
                    .catalog()
                    .iter()
                    .find(|p| p.original_id == "novelkeys-cream")
                    .unwrap()
                    .id
                    .clone(),
                volume: 71.0,
            },
        );
        let file = data.0.join("test.openklack");
        library.export(&preset, &file).unwrap();
        let second = Staging::new(&std::env::temp_dir()).unwrap();
        let receiver = Library::open(resources.0.clone(), &second.0).unwrap();
        let restored = receiver.import(&file).unwrap().preset.unwrap();
        assert_eq!(restored.pack_id, preset.pack_id);
        assert_eq!(
            restored.overrides["Space"].pack_id,
            preset.overrides["Space"].pack_id
        );
        assert_eq!(restored.overrides["Space"].volume, 71.0);
        let content =
            pack_io::read_zip(&read_limited(&file, pack_io::MAX_ARCHIVE).unwrap()).unwrap();
        assert!(content.keys().any(|name| name.ends_with("CREDITS.txt")));
        assert!(
            receiver
                .pack(&preset.pack_id)
                .unwrap()
                .credits
                .contains("MIT")
        );
        let mut modified = content;
        modified
            .iter_mut()
            .find(|(name, _)| name.ends_with("audio.ogg"))
            .unwrap()
            .1
            .push(0);
        fs::write(&file, pack_io::write_zip(&modified).unwrap()).unwrap();
        assert!(
            receiver
                .import(&file)
                .err()
                .unwrap()
                .contains("declared version")
        );
        assert_eq!(receiver.catalog().len(), 18);
        let original_version = library
            .catalog()
            .iter()
            .find(|p| p.original_id == "alps-skcm-blue")
            .unwrap()
            .id
            .clone();
        let mut bundled: Vec<Pack> =
            serde_json::from_slice(&fs::read(resources.0.join("soundpacks.json")).unwrap())
                .unwrap();
        bundled
            .iter_mut()
            .find(|p| p.id == "alps-skcm-blue")
            .unwrap()
            .description
            .push_str(" Updated metadata.");
        fs::write(
            resources.0.join("soundpacks.json"),
            serde_json::to_vec(&bundled).unwrap(),
        )
        .unwrap();
        let reopened = Library::open(resources.0.clone(), &data.0).unwrap();
        assert_eq!(reopened.catalog().len(), 18);
        reopened.pack(&original_version).unwrap();
        assert_eq!(reopened.install_bundled_updates().unwrap(), 1);
        assert_eq!(reopened.catalog().len(), 19);
        reopened.pack(&original_version).unwrap();
        assert_eq!(
            Library::open(resources.0.clone(), &data.0)
                .unwrap()
                .catalog()
                .len(),
            19
        );
    }
}
