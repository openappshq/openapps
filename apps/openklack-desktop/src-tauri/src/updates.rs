//! App updates. Official builds compile the `updater` feature: a daily check of the signed feed at
//! openapps.space, a background download and an install on the next quit or restart. Builds from
//! source keep the same commands, but they never check, download or install anything.

use serde::{Deserialize, Serialize};

#[cfg(feature = "updater")]
mod install;
#[cfg(feature = "updater")]
mod policy;
#[cfg(feature = "updater")]
pub mod service;
#[cfg(feature = "updater")]
pub use service::{init, install_on_exit, ready, restart};
#[cfg(not(feature = "updater"))]
pub use unavailable::{init, install_on_exit, ready, restart};
// Only official builds (the `licensing` feature reads the records) decide the default.
#[cfg(all(feature = "updater", feature = "licensing"))]
pub use service::apply_auto_check_default;
#[cfg(all(not(feature = "updater"), feature = "licensing"))]
pub use unavailable::apply_auto_check_default;

/// What the user chose in Settings. Automatic checks are turned on once, on the first launch of
/// a fresh install, and only tell the user about a new version; automatic installs are off
/// until the user turns them on. Before the default resolves both are off, so the app never
/// contacts the update feed on its own until then.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub check_automatically: bool,
    pub install_automatically: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Release {
    pub version: String,
    pub notes: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub revision: u64,
    /// This build includes the updater at all.
    pub supported: bool,
    /// The updater has a pinned update key and a feed.
    pub configured: bool,
    /// The app runs from somewhere it can't replace itself (a disk image, App Translocation).
    pub location_blocked: bool,
    /// A previous copy of the app kept next to it after an update that failed and could not be
    /// undone; the user can put it back by hand.
    pub backup: Option<String>,
    pub current_version: String,
    pub settings: Settings,
    pub phase: &'static str,
    pub available: Option<Release>,
    pub received: u64,
    pub total: Option<u64>,
    pub error: Option<String>,
    pub last_checked_at: Option<i64>,
}

#[cfg(not(feature = "updater"))]
pub mod unavailable {
    use super::{Settings, Status};

    const SOURCE_BUILD: &str = "Builds from source don’t include app updates.";

    pub fn init(_app: &tauri::AppHandle) {}

    /// Nothing to default: a build without the updater has no update settings.
    #[cfg_attr(not(feature = "licensing"), allow(dead_code))]
    pub fn apply_auto_check_default(_app: &tauri::AppHandle, _fresh_install: bool) {}

    pub fn install_on_exit(_app: &tauri::AppHandle) {}

    pub fn ready(_app: &tauri::AppHandle) -> bool {
        false
    }

    pub fn restart(_app: &tauri::AppHandle) {}

    fn status(app: &tauri::AppHandle) -> Status {
        Status {
            revision: 0,
            supported: false,
            configured: false,
            location_blocked: false,
            backup: None,
            current_version: app.package_info().version.to_string(),
            settings: Settings::default(),
            phase: "idle",
            available: None,
            received: 0,
            total: None,
            error: None,
            last_checked_at: None,
        }
    }

    #[tauri::command]
    pub fn updater_status(app: tauri::AppHandle) -> Status {
        status(&app)
    }

    #[tauri::command]
    pub fn check_for_updates() -> Result<Status, String> {
        Err(SOURCE_BUILD.into())
    }

    #[tauri::command]
    pub fn download_update() -> Result<Status, String> {
        Err(SOURCE_BUILD.into())
    }

    #[tauri::command]
    pub fn set_update_settings(_settings: Settings) -> Result<Status, String> {
        Err(SOURCE_BUILD.into())
    }

    #[tauri::command]
    pub fn restart_to_update() -> Result<(), String> {
        Err(SOURCE_BUILD.into())
    }
}
