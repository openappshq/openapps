//! Replacing the installed bundle with a staged one. The staged bundle is unpacked into a private
//! folder next to the app, verified there, and exchanged with the app in one atomic rename
//! (`renamex_np` with `RENAME_SWAP`): at no instant is the folder without an app. The exchanged
//! old bundle is deleted only after the app at its final path verifies again; if it doesn't, the
//! exchange is undone.

use std::{
    fs, io,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

/// How long a `codesign` check may take before it counts as failed. Long enough for a slow disk,
/// short enough that quitting never hangs on it. The exchange itself has no deadline.
pub const VERIFY_TIMEOUT: Duration = Duration::from_secs(60);

/// Where a downloaded bundle is unpacked, next to the app so the exchange is a rename.
pub fn staging_dir(app: &Path) -> PathBuf {
    let name = app
        .file_name()
        .map(|n| n.to_string_lossy())
        .unwrap_or_default();
    app.with_file_name(format!(".{name}.update"))
}

/// A folder only this user can enter, created fresh: never a leftover, never a symlink.
fn private_dir(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    let _ = fs::remove_dir_all(path);
    if fs::symlink_metadata(path).is_ok() {
        fs::remove_file(path).map_err(|e| e.to_string())?;
    }
    fs::DirBuilder::new()
        .mode(0o700)
        .create(path)
        .map_err(|e| format!("Could not create {}: {e}", path.display()))?;
    let created = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !created.is_dir()
        || created.file_type().is_symlink()
        || created.uid() != unsafe { libc::getuid() }
        || created.mode() & 0o077 != 0
    {
        let _ = fs::remove_dir_all(path);
        return Err(format!("{} is not a private folder.", path.display()));
    }
    Ok(())
}

/// Unpacks a verified `.app.tar.gz` into the staging folder and returns the bundle inside it.
/// The archive must hold exactly one top-level directory (not a link) named like the app.
pub fn unpack(archive: &[u8], app: &Path) -> Result<PathBuf, String> {
    let staging = staging_dir(app);
    private_dir(&staging)?;
    let unpacked = (|| {
        let mut tar = tar::Archive::new(flate2::read::GzDecoder::new(archive));
        tar.set_preserve_permissions(true);
        tar.set_overwrite(false);
        tar.unpack(&staging).map_err(|e| e.to_string())?;
        let expected = app.file_name().ok_or("The app has no bundle name.")?;
        let mut entries = fs::read_dir(&staging).map_err(|e| e.to_string())?;
        match (entries.next(), entries.next()) {
            (Some(Ok(entry)), None)
                if entry.file_name() == expected
                    && entry.file_type().is_ok_and(|kind| kind.is_dir()) =>
            {
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

/// Runs a command with a deadline. A command still running at the deadline is killed and counts
/// as failed, so a stuck check can never hang the caller.
fn run(mut command: Command, timeout: Duration) -> Result<std::process::Output, String> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().map_err(|e| e.to_string()),
            Ok(None) if started.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Checking the app's signature took too long.".into());
            }
            Err(error) => return Err(error.to_string()),
        }
    }
}

fn codesign(args: &[&str], bundle: &Path) -> Result<std::process::Output, String> {
    let mut command = Command::new("/usr/bin/codesign");
    command.args(args).arg(bundle);
    run(command, VERIFY_TIMEOUT)
}

/// The designated requirement macOS evaluates for a bundle's permissions and Keychain access.
#[cfg(target_os = "macos")]
pub fn designated_requirement(bundle: &Path) -> Result<String, String> {
    let output = codesign(&["--display", "--requirements", "-"], bundle)?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    // An implicit requirement (ad hoc, or none declared) is printed as a `# ` comment.
    text.lines()
        .map(|line| line.strip_prefix("# ").unwrap_or(line))
        .find_map(|line| line.strip_prefix("designated => "))
        .map(str::to_string)
        .ok_or_else(|| "The app has no designated requirement.".into())
}

/// What a bundle must satisfy to be installed over `installed`, checked the way macOS checks it:
/// its signature is intact, it *satisfies* the installed app's designated requirement (evaluated
/// with `codesign -R`, never compared as text, so a copied requirement string from an ad-hoc
/// signature fails), and it carries the expected version. A debug build installed with an ad-hoc
/// signature has no stable identity to keep and skips the requirement; release builds never do.
#[cfg(target_os = "macos")]
pub fn verify_bundle(bundle: &Path, installed: &Path, version: &str) -> Result<(), String> {
    let verified = codesign(&["--verify", "--deep", "--strict"], bundle)?;
    if !verified.status.success() {
        return Err(format!(
            "The downloaded app is not correctly signed: {}",
            String::from_utf8_lossy(&verified.stderr).trim()
        ));
    }
    let mut plutil = Command::new("/usr/bin/plutil");
    plutil
        .args(["-extract", "CFBundleShortVersionString", "raw", "-o", "-"])
        .arg(bundle.join("Contents/Info.plist"));
    let found = run(plutil, VERIFY_TIMEOUT)?;
    let found = String::from_utf8_lossy(&found.stdout).trim().to_string();
    if found != version {
        return Err(format!(
            "The downloaded app is version {found}, not {version}. Nothing was installed."
        ));
    }
    let requirement = designated_requirement(installed)?;
    let ad_hoc_development = cfg!(debug_assertions) && requirement.starts_with("cdhash");
    if !ad_hoc_development {
        let satisfied = codesign(
            &[
                "--verify",
                "--deep",
                "--strict",
                &format!("-R={requirement}"),
            ],
            bundle,
        )?;
        if !satisfied.status.success() {
            return Err(
                "The downloaded app is signed with a different identity. Nothing was installed."
                    .into(),
            );
        }
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
pub fn verify_bundle(_bundle: &Path, _installed: &Path, _version: &str) -> Result<(), String> {
    Err("App updates are supported on macOS.".into())
}

/// Exchanges the two paths in one atomic operation on the same volume. Afterwards `a` holds what
/// was at `b` and the other way round; on failure neither changed.
#[cfg(target_os = "macos")]
fn exchange(a: &Path, b: &Path) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let a = std::ffi::CString::new(a.as_os_str().as_bytes()).map_err(io::Error::other)?;
    let b = std::ffi::CString::new(b.as_os_str().as_bytes()).map_err(io::Error::other)?;
    if unsafe { libc::renamex_np(a.as_ptr(), b.as_ptr(), libc::RENAME_SWAP) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "macos"))]
fn exchange(_a: &Path, _b: &Path) -> io::Result<()> {
    Err(io::Error::other("atomic exchange is supported on macOS"))
}

/// The steps of an install, in order, for failure injection in tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// The atomic exchange of the two bundles.
    Exchange,
    /// Verification of the app at its final path, before the old one is deleted.
    Confirm,
}

/// Replaces `app` with `staged`, which must be in the staging folder next to it. `confirm` checks
/// the app at its final path after the exchange; if it fails, the exchange is undone and the
/// staged bundle removed. `before` runs ahead of each step and may fail it (tests). The folder
/// holds a complete app at every instant.
pub fn swap(
    app: &Path,
    staged: &Path,
    confirm: &dyn Fn(&Path) -> Result<(), String>,
    before: &mut dyn FnMut(Step) -> io::Result<()>,
) -> Result<(), String> {
    before(Step::Exchange)
        .and_then(|()| exchange(staged, app))
        .map_err(|e| format!("Could not exchange the app with the new one: {e}"))?;
    // From here the new app is installed and the old one waits at the staged path.
    let confirmed = before(Step::Confirm)
        .map_err(|e| e.to_string())
        .and_then(|()| confirm(app));
    if let Err(error) = confirmed {
        return match exchange(staged, app) {
            Ok(()) => {
                let _ = fs::remove_dir_all(staging_dir(app));
                Err(format!("The new app failed its final check: {error}"))
            }
            Err(undo) => Err(format!(
                "The new app failed its final check ({error}) and the previous one could not be put back ({undo}); it is at {}",
                staged.display()
            )),
        };
    }
    let _ = fs::remove_dir_all(staging_dir(app));
    let _ = Command::new("/usr/bin/touch").arg(app).status();
    Ok(())
}

/// Removes what an earlier run left next to the app: a staging folder, holding either a bundle
/// that was never installed or the old one after an exchange whose cleanup was interrupted.
pub fn recover(app: &Path) {
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

    fn accept(_: &Path) -> Result<(), String> {
        Ok(())
    }

    #[test]
    fn an_install_exchanges_the_bundles_and_leaves_only_the_new_app() {
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        assert_eq!(staged, staging_dir(&app).join("OpenKlack.app"));
        let mut seen = Vec::new();
        swap(&app, &staged, &accept, &mut |step| {
            seen.push(step);
            // At confirmation time the new app is already at its final path and the old one
            // still exists at the staged path: nothing has been deleted yet.
            if step == Step::Confirm {
                assert_eq!(marker(&app), "new");
                assert_eq!(marker(&staged), "old");
            }
            Ok(())
        })
        .unwrap();
        assert_eq!(seen, vec![Step::Exchange, Step::Confirm]);
        assert_eq!(marker(&app), "new");
        only_app(&folder.0, &app);
    }

    #[test]
    fn a_failed_exchange_changes_nothing() {
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        let error = swap(&app, &staged, &accept, &mut |step| match step {
            Step::Exchange => Err(io::Error::other("busy")),
            _ => Ok(()),
        })
        .unwrap_err();
        assert!(error.contains("busy"), "{error}");
        assert_eq!(marker(&app), "old");
        assert_eq!(marker(&staged), "new");
        // A staged path that isn't there fails the same way, with the app untouched.
        let error = swap(&app, &folder.0.join("missing"), &accept, &mut |_| Ok(())).unwrap_err();
        assert!(error.contains("exchange"), "{error}");
        assert_eq!(marker(&app), "old");
    }

    #[test]
    fn a_new_app_that_fails_its_final_check_is_exchanged_back() {
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        let reject = |path: &Path| {
            assert_eq!(marker(path), "new");
            Err("tampered".to_string())
        };
        let error = swap(&app, &staged, &reject, &mut |_| Ok(())).unwrap_err();
        assert!(error.contains("tampered"), "{error}");
        assert_eq!(marker(&app), "old");
        only_app(&folder.0, &app);
    }

    #[test]
    fn an_install_interrupted_after_the_exchange_is_cleaned_up_at_the_next_launch() {
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        // The process died right after the exchange: the new app is installed, the old bundle
        // is still in the staging folder. Whatever happens, the app path is never empty.
        exchange(&staged, &app).unwrap();
        assert_eq!(marker(&app), "new");
        assert_eq!(marker(&staged), "old");
        recover(&app);
        assert_eq!(marker(&app), "new");
        only_app(&folder.0, &app);

        // The process died after unpacking, before any exchange.
        let staged = unpack(&archive("OpenKlack.app", "newer"), &app).unwrap();
        assert!(staged.exists());
        recover(&app);
        assert_eq!(marker(&app), "new");
        only_app(&folder.0, &app);
    }

    #[test]
    fn the_staging_folder_is_private_and_holds_exactly_the_app() {
        use std::os::unix::fs::PermissionsExt;
        let folder = Folder::new();
        let app = folder.bundle("OpenKlack.app", "old");
        let staged = unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        let staging = staging_dir(&app);
        assert_eq!(
            fs::metadata(&staging).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(marker(&staged), "new");
        // A leftover, even a symlink, is replaced by a fresh private folder.
        fs::remove_dir_all(&staging).unwrap();
        std::os::unix::fs::symlink(&folder.0, &staging).unwrap();
        unpack(&archive("OpenKlack.app", "new"), &app).unwrap();
        assert!(
            !fs::symlink_metadata(&staging)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        // Wrong or unreadable archives leave nothing behind.
        assert!(unpack(&archive("Other.app", "new"), &app).is_err());
        assert!(unpack(b"not an archive", &app).is_err());
        assert!(!staging.exists());
        assert_eq!(marker(&app), "old");
    }

    #[test]
    fn slow_checks_are_cut_off() {
        let mut sleep = Command::new("/bin/sleep");
        sleep.arg("30");
        let started = Instant::now();
        assert!(run(sleep, Duration::from_millis(200)).is_err());
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    /// Bundles signed ad hoc with `codesign -s -`; no certificate or keychain involved.
    #[cfg(target_os = "macos")]
    fn signed_bundle(
        folder: &Folder,
        name: &str,
        version: &str,
        requirement: Option<&str>,
    ) -> PathBuf {
        let bundle = folder.0.join(name);
        fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
        fs::copy(
            "/usr/bin/true",
            bundle.join("Contents/MacOS/openklack-desktop"),
        )
        .unwrap();
        fs::write(
            bundle.join("Contents/Info.plist"),
            format!(
                r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.openklack.desktop</string><key>CFBundleExecutable</key><string>openklack-desktop</string><key>CFBundleShortVersionString</key><string>{version}</string></dict></plist>"#
            ),
        )
        .unwrap();
        let mut command = Command::new("/usr/bin/codesign");
        command.args(["--force", "--sign", "-"]);
        if let Some(requirement) = requirement {
            command.arg(format!("-r=designated => {requirement}"));
        }
        assert!(command.arg(&bundle).status().unwrap().success());
        bundle
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_copied_requirement_string_does_not_pass_as_the_signer() {
        let folder = Folder::new();
        // The "installed" app declares a certificate it doesn't have (an ad-hoc signature with
        // an explicit requirement), exactly as a forger would copy an official one.
        let claimed = r#"identifier "com.openklack.desktop" and certificate leaf = H"1111111111111111111111111111111111111111""#;
        let installed = signed_bundle(&folder, "OpenKlack.app", "0.1.0", Some(claimed));
        assert_eq!(designated_requirement(&installed).unwrap(), claimed);
        let forged = signed_bundle(&folder, "Forged.app", "0.2.0", Some(claimed));
        // Text matches, signature is intact, version matches — and it must still be refused,
        // because it does not satisfy the requirement.
        assert_eq!(designated_requirement(&forged).unwrap(), claimed);
        assert!(
            codesign(&["--verify", "--deep", "--strict"], &forged)
                .unwrap()
                .status
                .success()
        );
        let error = verify_bundle(&forged, &installed, "0.2.0").unwrap_err();
        assert!(error.contains("different identity"), "{error}");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn signature_version_and_identity_are_all_required() {
        let folder = Folder::new();
        let installed = signed_bundle(&folder, "OpenKlack.app", "0.1.0", None);
        assert!(
            designated_requirement(&installed)
                .unwrap()
                .starts_with("cdhash")
        );
        let unsigned = folder.bundle("Unsigned.app", "new");
        assert!(
            verify_bundle(&unsigned, &installed, "0.2.0")
                .unwrap_err()
                .contains("not correctly signed")
        );
        let next = signed_bundle(&folder, "Next.app", "0.2.0", None);
        assert!(
            verify_bundle(&next, &installed, "0.3.0")
                .unwrap_err()
                .contains("version 0.2.0")
        );
        // Two ad-hoc signatures have different identities: only a debug build, which has no
        // identity to keep, accepts that; a release build never does.
        let result = verify_bundle(&next, &installed, "0.2.0");
        if cfg!(debug_assertions) {
            result.unwrap();
        } else {
            assert!(result.unwrap_err().contains("different identity"));
        }
    }
}
