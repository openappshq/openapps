use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Deserialize, Serialize)]
pub struct Phases {
    pub down: Vec<String>,
    pub up: Vec<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Pack {
    pub id: String,
    #[serde(default)]
    pub original_id: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub source_id: String,
    pub name: String,
    pub brand: String,
    pub kind: String,
    pub description: String,
    pub color: String,
    pub author: String,
    pub supports_key_up: bool,
    pub sample_count: usize,
    pub source: String,
    pub license: serde_json::Value,
    #[serde(default)]
    pub credits: String,
    #[serde(default)]
    pub files: BTreeMap<String, String>,
    #[serde(default)]
    pub sprite_file: Option<String>,
    #[serde(default)]
    pub sprite: BTreeMap<String, [f64; 2]>,
    pub sounds: BTreeMap<String, Phases>,
}

impl Pack {
    pub fn validate(&self) -> Result<(), String> {
        if self.id.is_empty()
            || self.id.len() > 160
            || !self
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_@".contains(&b))
        {
            return Err("The pack has an invalid identifier.".into());
        }
        if self.name.trim().is_empty()
            || self.name.len() > 120
            || self.brand.len() > 120
            || self.author.len() > 256
            || self.description.len() > 2000
            || self.credits.len() > 262_144
            || self.source.len() > 2048
            || self.original_id.len() > 256
            || self.source_id.len() > 256
            || self.version.len() > 80
            || self.kind.len() > 80
            || serde_json::to_vec(&self.license)
                .map_err(|e| e.to_string())?
                .len()
                > 8192
        {
            return Err("The pack metadata is missing or too large.".into());
        }
        if self.color.len() != 7
            || !self.color.starts_with('#')
            || !self.color[1..].bytes().all(|c| c.is_ascii_hexdigit())
        {
            return Err("Use a six-digit hex color for the pack.".into());
        }
        if self.sounds.len() > 256
            || !self.sounds.contains_key("default")
            || self.sprite.len() + self.files.len() > 1024
        {
            return Err(
                "A pack needs a default mapping, at most 256 keys, and at most 1024 clips.".into(),
            );
        }
        for name in self.files.values().chain(self.sprite_file.iter()) {
            if !safe_filename(name)
                || ["pack.json", "credits.txt"].contains(&name.to_ascii_lowercase().as_str())
            {
                return Err("Audio references must be plain, non-reserved file names.".into());
            }
        }
        for (key, phases) in &self.sounds {
            if key.is_empty()
                || key.len() > 40
                || key.chars().any(char::is_control)
                || phases.down.len() + phases.up.len() > 128
            {
                return Err("The pack has an invalid key mapping.".into());
            }
            for sample in phases.down.iter().chain(&phases.up) {
                if !self.files.contains_key(sample) && !self.sprite.contains_key(sample) {
                    return Err("A key refers to a missing audio clip.".into());
                }
            }
        }
        if !self.sprite.is_empty() && !self.files.is_empty() {
            return Err("Use files or sprite regions in one pack, not both.".into());
        }
        if self
            .sounds
            .values()
            .all(|p| p.down.is_empty() && p.up.is_empty())
        {
            return Err("This pack contains no playable sounds.".into());
        }
        Ok(())
    }
}

pub fn safe_filename(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value != "."
        && value != ".."
        && !value.chars().any(|c| c.is_control() || "/\\:".contains(c))
}

#[derive(Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Assignment {
    pub pack_id: String,
    pub volume: f32,
}

#[derive(Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Preset {
    pub id: String,
    pub name: String,
    pub pack_id: String,
    pub volume: f32,
    pub release_volume: f32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub tone: f32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub pitch: f32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub width: f32,
    pub variation: bool,
    pub favorite: bool,
    pub overrides: BTreeMap<String, Assignment>,
}

#[derive(Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppRule {
    pub bundle_id: String,
    #[serde(default)]
    pub name: String,
    pub preset_id: Option<String>,
    pub mute: bool,
}

#[derive(Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Preferences {
    pub schema_version: u32,
    pub muted: bool,
    pub pause_on_microphone: bool,
    pub active_preset_id: String,
    pub presets: Vec<Preset>,
    pub app_rules: Vec<AppRule>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub favorite_pack_ids: Vec<String>,
}

fn is_zero(value: &f32) -> bool {
    *value == 0.0
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            schema_version: 1,
            muted: false,
            pause_on_microphone: true,
            active_preset_id: "everyday".into(),
            presets: vec![Preset {
                id: "everyday".into(),
                name: "Everyday".into(),
                pack_id: "cherry-mx-brown-pbt".into(),
                volume: 45.0,
                release_volume: 65.0,
                tone: 0.0,
                pitch: 0.0,
                width: 0.0,
                variation: true,
                favorite: true,
                overrides: BTreeMap::new(),
            }],
            app_rules: vec![],
            favorite_pack_ids: vec![],
        }
    }
}

impl Preferences {
    pub fn only_mute_changed(&self, previous: &Self) -> bool {
        if self.muted == previous.muted {
            return false;
        }
        let mut previous = previous.clone();
        previous.muted = self.muted;
        *self == previous
    }

    pub fn validate(&self, catalog: &[Pack]) -> Result<(), String> {
        self.validate_shape()?;
        let packs: HashSet<_> = catalog.iter().map(|p| p.id.as_str()).collect();
        if self
            .favorite_pack_ids
            .iter()
            .any(|id| !packs.contains(id.as_str()))
        {
            return Err("A favorite sound is not installed.".into());
        }
        for preset in &self.presets {
            if !packs.contains(preset.pack_id.as_str())
                || preset
                    .overrides
                    .values()
                    .any(|v| !packs.contains(v.pack_id.as_str()))
            {
                return Err("A preset refers to a sound pack that is not installed.".into());
            }
        }
        Ok(())
    }

    pub fn validate_shape(&self) -> Result<(), String> {
        if self.schema_version != 1 {
            return Err("This settings version is not supported.".into());
        }
        if self.presets.is_empty() || self.presets.len() > 100 || self.app_rules.len() > 200 {
            return Err("Use 1 to 100 presets and at most 200 app rules.".into());
        }
        let mut favorites = HashSet::new();
        if self.favorite_pack_ids.len() > 512
            || self
                .favorite_pack_ids
                .iter()
                .any(|id| id.is_empty() || id.len() > 160 || !favorites.insert(id))
        {
            return Err("Favorite sounds must have unique, valid identifiers.".into());
        }
        let mut ids = HashSet::new();
        for preset in &self.presets {
            if preset.id.is_empty() || preset.id.len() > 80 || !ids.insert(preset.id.as_str()) {
                return Err("Preset identifiers must be unique.".into());
            }
            if preset.name.trim().is_empty()
                || preset.name.len() > 120
                || preset.pack_id.is_empty()
                || preset.pack_id.len() > 160
            {
                return Err("Choose a name and an installed sound pack for every preset.".into());
            }
            percent(preset.volume)?;
            percent(preset.release_volume)?;
            percent(preset.width)?;
            if !preset.tone.is_finite()
                || !(-100.0..=100.0).contains(&preset.tone)
                || !preset.pitch.is_finite()
                || !(-6.0..=6.0).contains(&preset.pitch)
            {
                return Err(
                    "Tone must be between -100 and 100; pitch between -6 and 6 semitones.".into(),
                );
            }
            if preset.overrides.len() > 256 {
                return Err("Too many key assignments.".into());
            }
            for (key, voice) in &preset.overrides {
                if key.is_empty()
                    || key.len() > 40
                    || key.chars().any(char::is_control)
                    || voice.pack_id.is_empty()
                    || voice.pack_id.len() > 160
                {
                    return Err("A key assignment refers to an invalid key or sound pack.".into());
                }
                percent(voice.volume)?;
            }
        }
        if !ids.contains(self.active_preset_id.as_str()) {
            return Err("The selected preset is missing.".into());
        }
        let mut apps = HashSet::new();
        for rule in &self.app_rules {
            if rule.bundle_id.is_empty()
                || rule.bundle_id.len() > 256
                || rule.bundle_id.chars().any(char::is_control)
                || rule.name.len() > 256
                || !apps.insert(&rule.bundle_id)
                || rule
                    .preset_id
                    .as_ref()
                    .is_some_and(|id| !ids.contains(id.as_str()))
            {
                return Err(
                    "App rules must identify an app once and use an existing preset.".into(),
                );
            }
        }
        Ok(())
    }

    pub fn preset(&self, app: &str) -> &Preset {
        let selected = self
            .app_rules
            .iter()
            .find(|r| r.bundle_id == app)
            .and_then(|r| r.preset_id.as_ref())
            .unwrap_or(&self.active_preset_id);
        self.presets
            .iter()
            .find(|p| &p.id == selected)
            .expect("validated preset")
    }
}

fn percent(value: f32) -> Result<(), String> {
    if value.is_finite() && (0.0..=100.0).contains(&value) {
        Ok(())
    } else {
        Err("Volume must be between 0 and 100.".into())
    }
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Runtime {
    pub input_permission: bool,
    pub secure_input: bool,
    pub microphone: u16,
    pub suspended: bool,
    pub temporary_resume: bool,
    #[serde(skip)]
    pub resume_app: Option<String>,
    pub frontmost_app: String,
    pub audio_ready: bool,
    pub audio_error: Option<String>,
    pub configuration_error: Option<String>,
    pub output_sample_rate: u32,
}

impl Runtime {
    pub fn can_resume(&self, prefs: &Preferences) -> bool {
        matches!(
            self.pause_reason(prefs),
            Some("Paused for this app" | "Microphone in use" | "Checking microphone activity")
        )
    }

    pub fn pause_reason(&self, prefs: &Preferences) -> Option<&'static str> {
        if prefs.muted {
            Some("Muted")
        } else if !self.input_permission {
            Some("Input Monitoring permission needed")
        } else if self.suspended {
            Some("Mac is resting")
        } else if self.secure_input {
            Some("Secure input is active")
        } else if self.configuration_error.is_some() {
            Some("Sound preset unavailable")
        } else if !self.audio_ready {
            Some("Audio output unavailable")
        } else if self.temporary_resume {
            None
        } else if prefs
            .app_rules
            .iter()
            .any(|r| r.bundle_id == self.frontmost_app && r.mute)
        {
            Some("Paused for this app")
        } else if prefs.pause_on_microphone && self.microphone == 1 {
            Some("Microphone in use")
        } else if prefs.pause_on_microphone && self.microphone == 2 {
            Some("Checking microphone activity")
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn version_one_preferences_preserve_the_wire_contract_and_isolate_mute_changes() {
        let fixture = include_str!("../../fixtures/preferences-v1.json");
        let prefs: Preferences = serde_json::from_str(fixture).unwrap();
        prefs.validate_shape().unwrap();
        assert_eq!(
            serde_json::to_value(&prefs).unwrap(),
            serde_json::from_str::<serde_json::Value>(fixture).unwrap()
        );
        assert!(!prefs.only_mute_changed(&prefs));
        let mut changed = prefs.clone();
        changed.muted = true;
        assert!(changed.only_mute_changed(&prefs));
        changed.presets[0]
            .overrides
            .get_mut("Char:å")
            .unwrap()
            .volume = 51.0;
        assert!(!changed.only_mute_changed(&prefs));
        changed = prefs.clone();
        changed.muted = true;
        changed.app_rules[0].mute = true;
        assert!(!changed.only_mute_changed(&prefs));
    }

    #[test]
    fn favorite_sounds_survive_restart_and_reject_duplicates() {
        let mut prefs = Preferences::default();
        prefs.favorite_pack_ids.push("cherry-mx-brown-pbt".into());
        prefs.validate_shape().unwrap();
        let saved = serde_json::to_string(&prefs).unwrap();
        let restored: Preferences = serde_json::from_str(&saved).unwrap();
        assert_eq!(restored.favorite_pack_ids, prefs.favorite_pack_ids);
        prefs.favorite_pack_ids.push("cherry-mx-brown-pbt".into());
        assert!(prefs.validate_shape().is_err());
    }

    #[test]
    fn manual_mute_and_unavailable_input_win_over_temporary_resume() {
        let mut prefs = Preferences::default();
        let runtime = Runtime {
            temporary_resume: true,
            audio_ready: true,
            ..Runtime::default()
        };
        assert_eq!(
            runtime.pause_reason(&prefs),
            Some("Input Monitoring permission needed")
        );
        prefs.muted = true;
        assert_eq!(runtime.pause_reason(&prefs), Some("Muted"));
        let runtime = Runtime {
            input_permission: true,
            microphone: 1,
            ..runtime
        };
        prefs.muted = false;
        assert_eq!(runtime.pause_reason(&prefs), None);
        assert_eq!(
            Runtime {
                temporary_resume: false,
                ..runtime
            }
            .pause_reason(&prefs),
            Some("Microphone in use")
        );
    }
}
