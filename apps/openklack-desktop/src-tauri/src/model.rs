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
    /// The setup guide was finished or skipped; official builds show it once, on first launch.
    #[serde(default, skip_serializing_if = "is_false")]
    pub onboarding_completed: bool,
    /// The setup guide's current step while it is unfinished, so a relaunch (macOS asks for one
    /// after Input Monitoring is granted) resumes where the user was. The guide clamps it.
    #[serde(default, skip_serializing_if = "is_zero_u8")]
    pub onboarding_step: u8,
    /// "Open at login" has been turned on by default once, on the first launch of an official
    /// build. After that the user's own choice, in Settings or in System Settings, stands.
    #[serde(default, skip_serializing_if = "is_false")]
    pub login_item_defaulted: bool,
}

fn is_zero(value: &f32) -> bool {
    *value == 0.0
}

fn is_false(value: &bool) -> bool {
    !*value
}

fn is_zero_u8(value: &u8) -> bool {
    *value == 0
}

/// What the launch does about "Open at login" being on by default. Only official builds
/// (the `licensing` feature) decide it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(feature = "licensing"), allow(dead_code))]
pub enum LoginItemDefault {
    /// A fresh install of an official build: register the login item, then remember it.
    TurnOn,
    /// An upgrade (there were preferences, a trial or a license before): remember that the
    /// default was considered without touching the login item, so an earlier "off" stays off.
    Remember,
    /// Already decided, or a build from source: nothing to do.
    Leave,
}

/// Decides once per install. Source builds never register a login item; a user who turns it
/// off afterwards, in Settings or in System Settings, is never overridden.
pub fn login_item_default(
    official: bool,
    fresh_install: bool,
    prefs: &Preferences,
) -> LoginItemDefault {
    if !official || prefs.login_item_defaulted {
        LoginItemDefault::Leave
    } else if fresh_install {
        LoginItemDefault::TurnOn
    } else {
        LoginItemDefault::Remember
    }
}

/// The Mac's login item for the app (the autostart plugin in the app, a fake in tests).
pub trait LoginItem {
    fn is_enabled(&self) -> Result<bool, String>;
    fn set_enabled(&self, enabled: bool) -> Result<(), String>;
}

/// The user's explicit choice in Settings. Runs inside the preferences update, so it is
/// serialized with `apply_login_item_default`: whichever lands first, the user's choice stands,
/// because the choice marks the default as decided before the default can look.
pub fn choose_login_item(
    prefs: &mut Preferences,
    enabled: bool,
    item: &impl LoginItem,
) -> Result<(), String> {
    item.set_enabled(enabled)?;
    prefs.login_item_defaulted = true;
    Ok(())
}

/// The default, inside the same preferences update as the user's choice. Registers only on a
/// fresh install and remembers the decision only once it holds, so a failed registration is
/// tried again on the next launch. Returns whether the preferences changed.
#[cfg_attr(not(feature = "licensing"), allow(dead_code))]
pub fn apply_login_item_default(
    prefs: &mut Preferences,
    official: bool,
    fresh_install: bool,
    item: &impl LoginItem,
) -> bool {
    match login_item_default(official, fresh_install, prefs) {
        LoginItemDefault::Leave => return false,
        LoginItemDefault::TurnOn => {
            let registered = item.is_enabled().unwrap_or(false) || item.set_enabled(true).is_ok();
            if !registered {
                return false;
            }
        }
        LoginItemDefault::Remember => {}
    }
    prefs.login_item_defaulted = true;
    true
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
            onboarding_completed: false,
            onboarding_step: 0,
            login_item_defaulted: false,
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

/// Where the Mac's default output plays. The pause for the microphone exists so the people on
/// a call don't hear the sounds, which only happens through the built-in speakers.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum OutputRoute {
    /// The built-in speakers; assumed until the native bridge reports, so a call is never
    /// surprised by a clack.
    #[default]
    Speakers,
    /// Headphones, AirPods, Bluetooth, USB, HDMI, DisplayPort, AirPlay, virtual devices, or no
    /// output at all: nobody else hears the sounds.
    Other,
}

/// The floating drag-to-grant helper (`macos.m`): the app icon to drag into System Settings'
/// Input Monitoring list, for when OpenKlack is not listed there. The panel is native and
/// reports itself shown or hidden; this is what Rust and the settings window know of it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionHelper {
    pub visible: bool,
}

impl PermissionHelper {
    /// The bridge reported the panel shown or hidden (kind 107). Never visible once the
    /// permission is granted: the bridge refuses a show then and closes the panel on the next
    /// poll, so a shown report that crosses the grant is already stale.
    pub fn reported(&mut self, visible: bool, input_permission: bool) {
        self.visible = visible && !input_permission;
    }

    /// The permission arrived: the panel hides itself, there is nothing left to drag for.
    pub fn granted(&mut self) {
        self.visible = false;
    }
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Runtime {
    pub input_permission: bool,
    pub permission_helper: PermissionHelper,
    pub secure_input: bool,
    pub microphone: u16,
    pub output_route: OutputRoute,
    pub suspended: bool,
    pub temporary_resume: bool,
    #[serde(skip)]
    pub resume_app: Option<String>,
    pub frontmost_app: String,
    pub audio_ready: bool,
    pub audio_error: Option<String>,
    pub configuration_error: Option<String>,
    pub output_sample_rate: u32,
    /// Official builds without a valid license stop keyboard sounds and nothing else.
    pub license_blocked: bool,
    /// Why licensing blocks playback, such as the trial having ended; shown as the pause reason.
    #[serde(skip)]
    pub license_reason: &'static str,
    /// The revision of the gate decision in effect; older decisions are ignored.
    #[serde(skip)]
    pub license_gate_revision: u64,
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
        } else if self.license_blocked {
            Some(if self.license_reason.is_empty() {
                "License needed"
            } else {
                self.license_reason
            })
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
        } else if self.microphone_pauses(prefs) && self.microphone == 1 {
            Some("Microphone in use")
        } else if self.microphone_pauses(prefs) && self.microphone == 2 {
            Some("Checking microphone activity")
        } else {
            None
        }
    }

    /// The microphone only pauses playback when the sounds would reach the call: through the
    /// built-in speakers. Headphones and every other output keep playing.
    fn microphone_pauses(&self, prefs: &Preferences) -> bool {
        prefs.pause_on_microphone && self.output_route == OutputRoute::Speakers
    }

    /// The pause a temporary resume is overriding, for the banner. `None` when the resume is
    /// not what keeps playback going: it is off, a stronger reason pauses anyway, or nothing is
    /// left to override.
    pub fn resumed_reason(&self, prefs: &Preferences) -> Option<&'static str> {
        if !self.temporary_resume || self.pause_reason(prefs).is_some() {
            return None;
        }
        Runtime {
            temporary_resume: false,
            ..self.clone()
        }
        .pause_reason(prefs)
    }

    /// Ends a temporary resume: the pause it overrode applies again.
    pub fn end_temporary_resume(&mut self) {
        self.temporary_resume = false;
        self.resume_app = None;
    }

    /// Whether the drag-to-grant helper has anything to offer: the permission is still missing.
    pub fn wants_permission_helper(&self) -> bool {
        !self.input_permission
    }

    /// Applies a state message from the native bridge (the kinds are listed in `macos.m`).
    /// A temporary resume for the microphone ends once there is nothing to override: the
    /// microphone goes idle or unwatched, or the output leaves the speakers. One for an app
    /// ends when another app comes to the front. The drag-to-grant helper is gone once the
    /// permission is granted.
    pub fn apply_native(&mut self, kind: i32, value: u16, text: String) {
        match kind {
            100 => {
                self.input_permission = value != 0;
                if self.input_permission {
                    self.permission_helper.granted();
                }
            }
            107 => self
                .permission_helper
                .reported(value != 0, self.input_permission),
            101 => {
                if self.resume_app.is_none() && matches!(value, 0 | 3) {
                    self.temporary_resume = false;
                }
                self.microphone = value;
            }
            102 => self.suspended = value != 0,
            104 => {
                if self.resume_app.as_ref().is_some_and(|app| app != &text) {
                    self.end_temporary_resume();
                }
                self.frontmost_app = text;
            }
            105 => self.secure_input = value != 0,
            106 => {
                let route = if value == 1 {
                    OutputRoute::Speakers
                } else {
                    OutputRoute::Other
                };
                if self.resume_app.is_none() && route != OutputRoute::Speakers {
                    self.temporary_resume = false;
                }
                self.output_route = route;
            }
            _ => {}
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
    fn the_setup_guide_is_completed_once_and_survives_restart() {
        let fresh = Preferences::default();
        assert!(
            !fresh.onboarding_completed,
            "a fresh install shows the guide"
        );
        // Untouched settings keep the 0.1.0 wire shape.
        let saved = serde_json::to_value(&fresh).unwrap();
        assert!(saved.get("onboardingCompleted").is_none());
        assert!(saved.get("onboardingStep").is_none());
        assert!(saved.get("loginItemDefaulted").is_none());
        let mut done = fresh.clone();
        done.onboarding_completed = true;
        let saved = serde_json::to_string(&done).unwrap();
        let restored: Preferences = serde_json::from_str(&saved).unwrap();
        assert!(restored.onboarding_completed);
        assert!(!restored.only_mute_changed(&fresh));
    }

    #[test]
    fn the_setup_guide_step_survives_the_input_monitoring_relaunch() {
        let fresh = Preferences::default();
        assert_eq!(
            fresh.onboarding_step, 0,
            "a fresh install starts at Welcome"
        );
        let mut midway = fresh.clone();
        midway.onboarding_step = 1;
        let saved = serde_json::to_string(&midway).unwrap();
        assert!(saved.contains("\"onboardingStep\":1"));
        let restored: Preferences = serde_json::from_str(&saved).unwrap();
        assert_eq!(restored.onboarding_step, 1);
        assert!(!restored.onboarding_completed);
        assert!(!restored.only_mute_changed(&fresh));
        // Settings written before the step existed still load, at Welcome.
        let older: Preferences =
            serde_json::from_str(include_str!("../../fixtures/preferences-v1.json")).unwrap();
        assert_eq!(older.onboarding_step, 0);
    }

    #[test]
    fn open_at_login_defaults_on_for_a_fresh_official_install_only() {
        let mut prefs = Preferences::default();
        assert!(!prefs.login_item_defaulted);
        assert_eq!(
            login_item_default(false, true, &prefs),
            LoginItemDefault::Leave,
            "source builds never register"
        );
        assert_eq!(
            login_item_default(true, true, &prefs),
            LoginItemDefault::TurnOn,
            "a fresh install of an official build turns it on"
        );
        assert_eq!(
            login_item_default(true, false, &prefs),
            LoginItemDefault::Remember,
            "an upgrade remembers the decision without touching the login item"
        );
        prefs.login_item_defaulted = true;
        let restored: Preferences =
            serde_json::from_str(&serde_json::to_string(&prefs).unwrap()).unwrap();
        assert!(restored.login_item_defaulted);
        assert_eq!(
            login_item_default(true, true, &restored),
            LoginItemDefault::Leave,
            "a later launch never overrides the user's choice"
        );
    }

    /// A login item that records what the app asked of it and can refuse to register.
    #[derive(Default)]
    struct FakeLoginItem {
        enabled: std::cell::Cell<bool>,
        refuse: std::cell::Cell<bool>,
        calls: std::cell::RefCell<Vec<bool>>,
    }

    impl LoginItem for FakeLoginItem {
        fn is_enabled(&self) -> Result<bool, String> {
            Ok(self.enabled.get())
        }
        fn set_enabled(&self, enabled: bool) -> Result<(), String> {
            self.calls.borrow_mut().push(enabled);
            if self.refuse.get() {
                return Err("refused".into());
            }
            self.enabled.set(enabled);
            Ok(())
        }
    }

    /// The Settings toggle and the default are serialized by the preferences lock; in every
    /// order, an explicit choice made while the records were still being read stands.
    #[test]
    fn a_choice_made_before_the_records_resolve_beats_the_default() {
        // User turns it off first, the fresh-install default lands afterwards.
        let item = FakeLoginItem::default();
        let mut prefs = Preferences::default();
        choose_login_item(&mut prefs, false, &item).unwrap();
        assert!(prefs.login_item_defaulted);
        assert!(!apply_login_item_default(&mut prefs, true, true, &item));
        assert!(
            !item.enabled.get(),
            "the default never re-enables a chosen off"
        );
        assert_eq!(*item.calls.borrow(), vec![false]);

        // The default lands first, the user turns it off afterwards.
        let item = FakeLoginItem::default();
        let mut prefs = Preferences::default();
        assert!(apply_login_item_default(&mut prefs, true, true, &item));
        assert!(item.enabled.get());
        choose_login_item(&mut prefs, false, &item).unwrap();
        assert!(!item.enabled.get());
        assert!(!apply_login_item_default(&mut prefs, true, true, &item));
        assert_eq!(*item.calls.borrow(), vec![true, false]);

        // An upgrade remembers without touching the item, whatever the user had chosen.
        let item = FakeLoginItem::default();
        let mut prefs = Preferences::default();
        assert!(apply_login_item_default(&mut prefs, true, false, &item));
        assert!(prefs.login_item_defaulted);
        assert!(item.calls.borrow().is_empty());

        // A refused registration is not remembered, so the next launch tries again; a refused
        // choice is not remembered either.
        let item = FakeLoginItem::default();
        item.refuse.set(true);
        let mut prefs = Preferences::default();
        assert!(!apply_login_item_default(&mut prefs, true, true, &item));
        assert!(!prefs.login_item_defaulted);
        assert!(choose_login_item(&mut prefs, true, &item).is_err());
        assert!(!prefs.login_item_defaulted);
    }

    #[test]
    fn a_missing_license_pauses_playback_without_offering_a_resume() {
        let mut prefs = Preferences::default();
        let runtime = Runtime {
            input_permission: true,
            audio_ready: true,
            license_blocked: true,
            temporary_resume: true,
            ..Runtime::default()
        };
        assert_eq!(runtime.pause_reason(&prefs), Some("License needed"));
        assert!(!runtime.can_resume(&prefs));
        prefs.muted = true;
        assert_eq!(runtime.pause_reason(&prefs), Some("Muted"));
        let unlocked = Runtime {
            license_blocked: false,
            ..runtime
        };
        prefs.muted = false;
        assert_eq!(unlocked.pause_reason(&prefs), None);
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

    /// Every combination of the setting, the microphone state, the output route and a
    /// temporary resume. The microphone pauses playback only through the built-in speakers.
    #[test]
    fn the_microphone_pauses_playback_only_through_the_speakers() {
        let mut prefs = Preferences::default();
        for setting in [true, false] {
            prefs.pause_on_microphone = setting;
            for route in [OutputRoute::Speakers, OutputRoute::Other] {
                for microphone in 0..=3 {
                    for temporary_resume in [false, true] {
                        let runtime = Runtime {
                            input_permission: true,
                            audio_ready: true,
                            microphone,
                            output_route: route,
                            temporary_resume,
                            ..Runtime::default()
                        };
                        let expected = match (setting, route, microphone, temporary_resume) {
                            (true, OutputRoute::Speakers, 1, false) => Some("Microphone in use"),
                            (true, OutputRoute::Speakers, 2, false) => {
                                Some("Checking microphone activity")
                            }
                            _ => None,
                        };
                        assert_eq!(
                            runtime.pause_reason(&prefs),
                            expected,
                            "setting {setting}, {route:?}, microphone {microphone}, resumed {temporary_resume}"
                        );
                        assert_eq!(runtime.can_resume(&prefs), expected.is_some());
                        assert_eq!(
                            runtime.resumed_reason(&prefs),
                            Runtime {
                                temporary_resume: false,
                                ..runtime.clone()
                            }
                            .pause_reason(&prefs)
                            .filter(|_| temporary_resume),
                            "the banner names what a resume overrides"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn the_output_route_moves_the_microphone_pause_with_it() {
        let prefs = Preferences::default();
        let mut runtime = Runtime {
            input_permission: true,
            audio_ready: true,
            microphone: 1,
            ..Runtime::default()
        };
        assert_eq!(
            runtime.output_route,
            OutputRoute::Speakers,
            "the speakers are assumed until the bridge reports"
        );
        assert_eq!(runtime.pause_reason(&prefs), Some("Microphone in use"));
        // Headphones go in: the pause lifts.
        runtime.apply_native(106, 0, String::new());
        assert_eq!(runtime.output_route, OutputRoute::Other);
        assert_eq!(runtime.pause_reason(&prefs), None);
        // Back to the speakers while the microphone is still in use: paused again.
        runtime.apply_native(106, 1, String::new());
        assert_eq!(runtime.pause_reason(&prefs), Some("Microphone in use"));
        // A temporary resume for the microphone ends when the output leaves the speakers, so
        // returning to them pauses again instead of staying overridden.
        runtime.temporary_resume = true;
        assert_eq!(runtime.pause_reason(&prefs), None);
        assert_eq!(runtime.resumed_reason(&prefs), Some("Microphone in use"));
        runtime.apply_native(106, 0, String::new());
        assert!(!runtime.temporary_resume);
        assert_eq!(runtime.resumed_reason(&prefs), None);
        runtime.apply_native(106, 1, String::new());
        assert_eq!(runtime.pause_reason(&prefs), Some("Microphone in use"));
        // A resume that is for an app survives the route change, as it survives the microphone
        // going idle.
        runtime.temporary_resume = true;
        runtime.resume_app = Some("com.example.app".into());
        runtime.apply_native(106, 0, String::new());
        assert!(runtime.temporary_resume);
        runtime.apply_native(101, 0, String::new());
        assert!(runtime.temporary_resume);
        runtime.apply_native(104, 0, "com.example.other".into());
        assert!(!runtime.temporary_resume);
        assert_eq!(runtime.resume_app, None);
    }

    #[test]
    fn the_resume_banner_names_what_it_overrides_and_pause_again_ends_it() {
        let mut prefs = Preferences::default();
        prefs.app_rules.push(AppRule {
            bundle_id: "com.example.app".into(),
            name: "Example".into(),
            preset_id: None,
            mute: true,
        });
        let mut runtime = Runtime {
            input_permission: true,
            audio_ready: true,
            frontmost_app: "com.example.app".into(),
            microphone: 1,
            ..Runtime::default()
        };
        assert_eq!(runtime.resumed_reason(&prefs), None);
        runtime.temporary_resume = true;
        runtime.resume_app = Some("com.example.app".into());
        assert_eq!(runtime.resumed_reason(&prefs), Some("Paused for this app"));
        // A stronger pause hides the resume: nothing is playing anyway.
        prefs.muted = true;
        assert_eq!(runtime.resumed_reason(&prefs), None);
        prefs.muted = false;
        // The rule goes away: the resume now overrides the microphone pause instead.
        prefs.app_rules.clear();
        assert_eq!(runtime.pause_reason(&prefs), None);
        assert_eq!(runtime.resumed_reason(&prefs), Some("Microphone in use"));
        // Nothing left to override: the resume is idle and the banner has nothing to say.
        runtime.microphone = 0;
        assert!(runtime.temporary_resume);
        assert_eq!(runtime.resumed_reason(&prefs), None);
        runtime.microphone = 1;
        runtime.end_temporary_resume();
        assert!(!runtime.temporary_resume && runtime.resume_app.is_none());
        assert_eq!(runtime.pause_reason(&prefs), Some("Microphone in use"));
    }

    #[test]
    fn the_drag_to_grant_helper_follows_the_panel_and_leaves_with_the_permission() {
        let mut runtime = Runtime::default();
        assert!(
            !runtime.permission_helper.visible,
            "hidden until the bridge shows it"
        );
        assert!(
            runtime.wants_permission_helper(),
            "worth showing while the permission is missing"
        );
        // The panel reports itself shown, then closed by the user.
        runtime.apply_native(107, 1, String::new());
        assert!(runtime.permission_helper.visible);
        runtime.apply_native(107, 0, String::new());
        assert!(!runtime.permission_helper.visible);
        // Shown again; the permission still missing changes nothing about it.
        runtime.apply_native(107, 1, String::new());
        runtime.apply_native(100, 0, String::new());
        assert!(runtime.permission_helper.visible);
        assert!(runtime.wants_permission_helper());
        // The permission arrives: the helper is gone and has nothing more to offer.
        runtime.apply_native(100, 1, String::new());
        assert!(runtime.input_permission);
        assert!(!runtime.permission_helper.visible);
        assert!(!runtime.wants_permission_helper());
        // The bridge's own report of that hide is consistent. A shown report that crosses the
        // grant (a show queued before it) is stale and never makes the helper visible.
        runtime.apply_native(107, 0, String::new());
        runtime.apply_native(107, 1, String::new());
        assert!(!runtime.permission_helper.visible);
        // A later revocation does not bring the panel back on its own.
        runtime.apply_native(100, 0, String::new());
        assert!(!runtime.permission_helper.visible);
        assert!(runtime.wants_permission_helper());
        assert_eq!(
            serde_json::to_value(runtime.permission_helper).unwrap(),
            serde_json::json!({"visible": false})
        );
    }
}
