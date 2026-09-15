//! Replacing the installed bundle with a staged one. The swap is a transaction on one folder:
//! the old bundle is moved aside, the new one moved in, and the old one is deleted only once the
//! new one is in place. Any failure after the first move puts the old bundle back, and a crash in
//! between leaves a copy that [`recover`] restores. The folder never ends up without an app.

use std::{
    fs, io,
    path::{Path, PathBuf},
    process::Command,
};

/// Where a downloaded bundle is unpacked, next to the app so the final move is a rename.
pub fn staging_dir(app: &Path) -> PathBuf {
    sibling(app, ".update")
}

/// Where the running bundle waits during the swap.
pub fn previous(app: &Path) -> PathBuf {
    sibling(app, ".previous")
}

fn sibling(app: &Path, suffix: &str) -> PathBuf {
    let name = app
        .file_name()
        .map(|n| n.to_string_lossy())
        .unwrap_or_default();
    app.with_file_name(format!(".{name}{suffix}"))
}

/// Unpacks a verified `.app.tar.gz` into the staging folder and returns the bundle inside it.
/// The archive must hold exactly one top-level bundle named like the installed app.
pub fn unpack(archive: &[u8], app: &Path) -> Result<PathBuf, String> {
    let staging = staging_dir(app);
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
    let unpacked = (|| {
        let mut tar = tar::Archive::new(flate2::read::GzDecoder::new(archive));
        tar.set_preserve_permissions(true);
        tar.set_overwrite(false);
        tar.unpack(&staging).map_err(|e| e.to_string())?;
        let expected = app.file_name().ok_or("The app has no bundle name.")?;
        let mut entries = fs::read_dir(&staging).map_err(|e| e.to_string())?;
        match (entries.next(), entries.next()) {
            (Some(Ok(entry)), None) if entry.file_name() == expected && entry.path().is_dir() => {
                Ok(entry.path())
            }
            _ => Err("The update archive does not contain the app.".to_string()),
        }
    })();
    if unpacked.is_err() {
        let _ = fs::remove_dir_all(&staging);
    }
    unpacked
}

/// What a staged bundle must satisfy before it may replace the installed one, checked with the
/// same tools macOS uses: a valid signature and, unless the installed app is ad-hoc signed (a
/// development build), the same designated requirement, so permissions and Keychain items survive.
#[cfg(target_os = "macos")]
pub fn verify_bundle(bundle: &Path, installed: &Path, version: &str) -> Result<(), String> {
    let verified = Command::new("/usr/bin/codesign")
        .args(["--verify", "--deep", "--strict"])
        .arg(bundle)
        .output()
        .map_err(|e| e.to_string())?;
    if !verified.status.success() {
        return Err(format!(
            "The downloaded app is not correctly signed: {}",
            String::from_utf8_lossy(&verified.stderr).trim()
        ));
    }
    let current = designated_requirement(installed)?;
    if !current.starts_with("cdhash") && designated_requirement(bundle)? != current {
        return Err(
            "The downloaded app is signed with a different identity. Nothing was installed.".into(),
        );
    }
    let plist = bundle.join("Contents/Info.plist");
    let found = Command::new("/usr/bin/plutil")
        .args(["-extract", "CFBundleShortVersionString", "raw", "-o", "-"])
        .arg(&plist)
        .output()
        .map_err(|e| e.to_string())?;
    let found = String::from_utf8_lossy(&found.stdout).trim().to_string();
    if found != version {
        return Err(format!(
            "The downloaded app is version {found}, not {version}. Nothing was installed."
        ));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn designated_requirement(bundle: &Path) -> Result<String, String> {
    let output = Command::new("/usr/bin/codesign")
        .args(["--display", "--requirements", "-"])
        .arg(bundle)
        .output()
        .map_err(|e| e.to_string())?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    text.lines()
        .find_map(|line| line.strip_prefix("designated => "))
        .map(str::to_string)
        .ok_or_else(|| "The app has no designated requirement.".into())
}

#[cfg(not(target_os = "macos"))]
pub fn verify_bundle(_bundle: &Path, _installed: &Path, _version: &str) -> Result<(), String> {
    Err("App updates are supported on macOS.".into())
}

/// The moves of a swap, in order, for failure injection in tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    MoveAside,
    MoveIn,
}

/// Replaces `app` with `staged`, which must be in the same folder. `before` runs ahead of each
/// move and may fail it. On success the old bundle is gone and the staging folder removed; on any
/// failure the old bundle is back in place and the error says so.
pub fn swap(
    app: &Path,
    staged: &Path,
    before: &mut dyn FnMut(Step) -> io::Result<()>,
) -> Result<(), String> {
    let previous = previous(app);
    if previous.exists() {
        fs::remove_dir_all(&previous)
            .map_err(|e| format!("Could not clear {}: {e}", previous.display()))?;
    }
    before(Step::MoveAside)
        .and_then(|()| fs::rename(app, &previous))
        .map_err(|e| format!("Could not move the current app aside: {e}"))?;
    if let Err(error) = before(Step::MoveIn).and_then(|()| fs::rename(staged, app)) {
        return match fs::rename(&previous, app) {
            Ok(()) => Err(format!("Could not move the new app into place: {error}")),
            Err(restore) => Err(format!(
                "Could not move the new app into place ({error}), and the previous copy could not be put back ({restore}); it is at {}",
                previous.display()
            )),
        };
    }
    let _ = fs::remove_dir_all(&previous);
    let _ = fs::remove_dir_all(staging_dir(app));
    let _ = Command::new("/usr/bin/touch").arg(app).status();
    Ok(())
}

/// Cleans up after an interrupted or finished swap: an app that was moved aside but never
/// replaced comes back, a leftover previous copy or staging folder goes away.
pub fn recover(app: &Path) {
    let previous = previous(app);
    if previous.is_dir() {
        if app.exists() {
            let _ = fs::remove_dir_all(&previous);
        } else {
            let _ = fs::rename(&previous, app);
        }
    }
    let _ = fs::remove_dir_all(staging_dir(app));
}

#[cfg(test)]
mod tests {
    use super::*;

    static FOLDERS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

    struct Folder(PathBuf);
    impl Folder {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "openklack-install-{}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
                FOLDERS.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn bundle(&self, name: &str, marker: &str) -> PathBuf {
            let bundle = self.0.join(name);
            fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
            fs::write(bundle.join("Contents/MacOS/openklack-desktop"), marker).unwrap();
            bundle
        }
    }
    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn marker(bundle: &Path) -> String {
        fs::read_to_string(bundle.join("Contents/MacOS/openklack-desktop")).unwrap_or_default()
    }

    fn only_app(folder: &Path, app: &Path) {
        let names: Vec<_> = fs::read_dir(folder)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(
            names,
            vec![app.file_name().unwrap()],
            "{folder:?} holds {names:?}"
        );
    }

    fn archive(app_name: &str, marker: &str) -> Vec<u8> {
        let folder = Folder::new();
        let bundle = folder.bundle(app_name, marker);
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(
            Vec::new(),
            flate2::Compression::fast(),
        ));
        builder.append_dir_all(app_name, &bundle).unwrap();
        builder.into_inner().unwrap().finish().unwrap()
    }

    #[test]
    fn a_swap_replaces_the_app_and_leaves_nothing_else() {
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        assert_eq!(staged, staging_dir(&app).join("OpenKlack.app"));
        swap(&app, &staged, &mut |_| Ok(())).unwrap();
        assert_eq!(marker(&app), "new");
        only_app(&folder.0, &app);
    }

    #[test]
    fn a_failed_second_move_puts_the_old_app_back() {
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        let error = swap(&app, &staged, &mut |step| match step {
            Step::MoveIn => Err(io::Error::other("disk full")),
            _ => Ok(()),
        })
        .unwrap_err();
        assert!(error.contains("disk full"), "{error}");
        assert_eq!(marker(&app), "old");
        assert!(!previous(&app).exists());
        // The staged bundle is untouched, so the next attempt can use it.
        assert_eq!(marker(&staged), "new");
    }

    #[test]
    fn a_failed_first_move_changes_nothing() {
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        let error = swap(&app, &staged, &mut |step| match step {
            Step::MoveAside => Err(io::Error::other("busy")),
            _ => Ok(()),
        })
        .unwrap_err();
        assert!(error.contains("busy"), "{error}");
        assert_eq!(marker(&app), "old");
        assert!(!previous(&app).exists());
    }

    #[test]
    fn an_interrupted_swap_is_recovered_at_the_next_launch() {
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        // The process died right after the first move.
        fs::rename(&app, previous(&app)).unwrap();
        assert!(!app.exists());
        recover(&app);
        assert_eq!(marker(&app), "old");
        only_app(&folder.0, &app);
        assert!(!staged.exists());

        // The process died right after the second move, before cleaning up.
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        fs::rename(&app, previous(&app)).unwrap();
        fs::rename(&staged, &app).unwrap();
        recover(&app);
        assert_eq!(marker(&app), "new");
        only_app(&folder.0, &app);
    }

    #[test]
    fn only_an_archive_holding_exactly_the_app_is_unpacked() {
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        assert!(unpack(&archive("Other.app", "new"), &app).is_err());
        assert!(unpack(b"not an archive", &app).is_err());
        assert!(!staging_dir(&app).exists());
        assert_eq!(marker(&app), "old");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn an_unsigned_bundle_never_verifies() {
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        assert!(verify_bundle(&staged, &app, "0.1.0").is_err());
    }
}
