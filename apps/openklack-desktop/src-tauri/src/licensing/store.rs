//! The record store from LICENSING.md: the license and trial records as encrypted files the app
//! owns, never Keychain items. A Keychain item's access list is tied to the signing identity,
//! and without an Apple Developer identity that identity changes (a rebuilt certificate, a
//! development build over a release install), which makes macOS prompt for the app's own
//! records on every launch. A file never prompts.
//!
//! Three files in `~/Library/Application Support/OpenApps/<app id>/records/`: `license` (the
//! activation), `trial` (never deleted by the app) and `cleanups` (deactivations still owed,
//! kept even with no license). Each is `openapps-records-v1`, a 12-byte random nonce and
//! AES-256-GCM over the record's JSON, with `<app id>:<file name>` as additional authenticated
//! data so one file's bytes cannot be renamed into another's. The key is HKDF-SHA256 of the
//! Mac's hardware UUID (or `no-hardware-uuid`) with `openapps-records-v1:<app id>` as the
//! info; nothing about it is stored. That keeps the files from casual reading, editing and
//! copying to another Mac, not from a determined local user: the source is public.
//!
//! Read outcomes keep the storage semantics the engine relies on: a missing file is positively
//! absent, a directory or file that cannot be read is unavailable, and a file that fails the
//! magic, the authentication tag or JSON decoding is corrupt. Unavailable and corrupt are
//! storage errors: no new trial, no registry call, and the file is left in place.
//!
//! Old Keychain items from releases before 0.1.2 are never read, written or deleted; touching
//! them is what prompts.

use super::core::{Probe, Record, Stored, TrialRecord};
use super::runtime::Vault;
use aes_gcm::{
    Aes256Gcm, Key, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use serde::{Serialize, de::DeserializeOwned};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

/// The format every record file starts with.
const MAGIC: &[u8] = b"openapps-records-v1";
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const KEY_LEN: usize = 32;
/// The key material when the hardware UUID cannot be read.
const NO_HARDWARE_UUID: &str = "no-hardware-uuid";
pub const LICENSE_FILE: &str = "license";
pub const TRIAL_FILE: &str = "trial";
pub const CLEANUPS_FILE: &str = "cleanups";

/// Why a record could not be read. Both are storage errors to the engine; the distinction is
/// for the message and the tests.
#[derive(Debug, PartialEq, Eq)]
pub enum ReadError {
    /// The directory or the file exists but could not be read.
    Unavailable(String),
    /// The file was read but is not a record this Mac wrote: wrong format, wrong key, edited
    /// bytes, or JSON the app does not understand.
    Corrupt(String),
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ReadError::Unavailable(reason) => write!(f, "could not be read: {reason}"),
            ReadError::Corrupt(reason) => write!(f, "is unreadable: {reason}"),
        }
    }
}

/// The encrypted files under one records directory.
pub struct RecordStore {
    directory: PathBuf,
    app_id: String,
    key: [u8; KEY_LEN],
}

impl RecordStore {
    /// A store over `directory`, keyed by this Mac's hardware UUID. The directory is created on
    /// the first write, never on a read.
    pub fn new(directory: PathBuf, app_id: &str, hardware_uuid: Option<&str>) -> Self {
        Self {
            directory,
            app_id: app_id.to_string(),
            key: derive_key(app_id, hardware_uuid),
        }
    }

    /// The contract's location under the user's Application Support directory.
    pub fn directory_under(application_support: &Path, app_id: &str) -> PathBuf {
        application_support
            .join("OpenApps")
            .join(app_id)
            .join("records")
    }

    #[cfg(test)]
    fn directory(&self) -> &Path {
        &self.directory
    }

    fn path(&self, name: &str) -> PathBuf {
        self.directory.join(name)
    }

    fn aad(&self, name: &str) -> Vec<u8> {
        format!("{}:{name}", self.app_id).into_bytes()
    }

    /// The record in `name`, `None` when the file positively does not exist.
    pub fn read<T: DeserializeOwned>(&self, name: &str) -> Result<Option<T>, ReadError> {
        let bytes = match fs::read(self.path(name)) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(ReadError::Unavailable(error.to_string())),
        };
        let json = self.open(name, &bytes)?;
        serde_json::from_slice(&json)
            .map(Some)
            .map_err(|error| ReadError::Corrupt(error.to_string()))
    }

    fn open(&self, name: &str, bytes: &[u8]) -> Result<Vec<u8>, ReadError> {
        let Some(sealed) = bytes.strip_prefix(MAGIC) else {
            return Err(ReadError::Corrupt("not a record file".into()));
        };
        if sealed.len() < NONCE_LEN + TAG_LEN {
            return Err(ReadError::Corrupt("the record is truncated".into()));
        }
        let (nonce, ciphertext) = sealed.split_at(NONCE_LEN);
        Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&self.key))
            .decrypt(
                Nonce::from_slice(nonce),
                Payload {
                    msg: ciphertext,
                    aad: &self.aad(name),
                },
            )
            .map_err(|_| ReadError::Corrupt("the record was not written by this Mac".into()))
    }

    /// Replaces `name` atomically: the sealed bytes go to a temporary file in the same
    /// directory, are synced, and are renamed over the old file, which stays intact until then.
    pub fn write<T: Serialize>(&self, name: &str, record: &T) -> Result<(), String> {
        let json = serde_json::to_vec(record).map_err(|error| error.to_string())?;
        let bytes = self.seal(name, &json)?;
        self.create_directory()?;
        let staging = self.path(&format!(".{name}.{}.tmp", crate::library::unique_suffix()));
        let written = write_private(&staging, &bytes)
            .and_then(|()| fs::rename(&staging, self.path(name)))
            .and_then(|()| sync_directory(&self.directory));
        if let Err(error) = written {
            let _ = fs::remove_file(&staging);
            return Err(error.to_string());
        }
        Ok(())
    }

    fn seal(&self, name: &str, json: &[u8]) -> Result<Vec<u8>, String> {
        let mut nonce = [0u8; NONCE_LEN];
        getrandom::fill(&mut nonce).map_err(|error| format!("no randomness: {error}"))?;
        let ciphertext = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&self.key))
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: json,
                    aad: &self.aad(name),
                },
            )
            .map_err(|_| "the record could not be sealed".to_string())?;
        let mut bytes = Vec::with_capacity(MAGIC.len() + NONCE_LEN + ciphertext.len());
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&nonce);
        bytes.extend_from_slice(&ciphertext);
        Ok(bytes)
    }

    /// Removes `name`; a file that is already gone is fine.
    pub fn delete(&self, name: &str) -> Result<(), String> {
        match fs::remove_file(self.path(name)) {
            Ok(()) => sync_directory(&self.directory).map_err(|error| error.to_string()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.to_string()),
        }
    }

    /// The records directory and its parents, only this user can enter.
    fn create_directory(&self) -> Result<(), String> {
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder
            .create(&self.directory)
            .map_err(|error| error.to_string())
    }
}

/// AES-256-GCM key: HKDF-SHA256 of the hardware UUID, bound to this app by the info string.
fn derive_key(app_id: &str, hardware_uuid: Option<&str>) -> [u8; KEY_LEN] {
    let material = hardware_uuid.unwrap_or(NO_HARDWARE_UUID);
    let mut key = [0u8; KEY_LEN];
    hkdf::Hkdf::<sha2::Sha256>::new(None, material.as_bytes())
        .expand(format!("openapps-records-v1:{app_id}").as_bytes(), &mut key)
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    key
}

/// A new file only this user can read, fully written and synced.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Makes a rename or removal in `directory` durable.
fn sync_directory(directory: &Path) -> std::io::Result<()> {
    fs::File::open(directory)?.sync_all()
}

impl Vault for RecordStore {
    /// The license record and the owed cleanups. Either file unreadable is a storage error: the
    /// engine never treats it as "no license".
    fn load(&self) -> Result<Stored, String> {
        let license: Option<Record> = self
            .read(LICENSE_FILE)
            .map_err(|error| format!("The saved license {error}"))?;
        let pending_cleanups: Vec<Probe> = self
            .read(CLEANUPS_FILE)
            .map_err(|error| format!("The saved license cleanups {error}"))?
            .unwrap_or_default();
        Ok(Stored {
            license,
            pending_cleanups,
        })
    }

    /// The cleanups first, so a deactivation this Mac owes is never lost to a crash between
    /// the two files; then the license, deleted when the Mac has been removed.
    fn save(&self, stored: &Stored) -> Result<(), String> {
        let cleanups = if stored.pending_cleanups.is_empty() {
            self.delete(CLEANUPS_FILE)
        } else {
            self.write(CLEANUPS_FILE, &stored.pending_cleanups)
        };
        cleanups.map_err(|error| format!("The license cleanups could not be saved: {error}"))?;
        match &stored.license {
            Some(record) => self.write(LICENSE_FILE, record),
            None => self.delete(LICENSE_FILE),
        }
        .map_err(|error| format!("The license could not be saved: {error}"))
    }

    fn load_trial(&self) -> Result<Option<TrialRecord>, String> {
        self.read(TRIAL_FILE)
            .map_err(|error| format!("The saved free trial {error}"))
    }

    fn save_trial(&self, trial: &TrialRecord) -> Result<(), String> {
        self.write(TRIAL_FILE, trial)
            .map_err(|error| format!("The free trial could not be saved: {error}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    const APP: &str = "openklack";
    const UUID: &str = "5B7E2C1A-0F3D-4E8A-9C21-7D6F5A4B3C2D";

    fn store(root: &Path, uuid: Option<&str>) -> RecordStore {
        RecordStore::new(root.join("records"), APP, uuid)
    }

    fn record() -> Record {
        Record {
            license_key: "KEY-1".into(),
            instance_id: "inst-1".into(),
            product_id: "pdt_placeholder_openklack".into(),
            kind: None,
            activated_at: 1_700_000_000,
            last_success_at: 1_700_000_000,
            last_success_local: 1_700_000_000,
            last_observed_at: 1_700_000_000,
            revoked: false,
            event_seq: 1,
        }
    }

    fn trial() -> TrialRecord {
        TrialRecord {
            started_at: 1_700_000_000,
            last_seen_at: 1_700_003_600,
            registered: true,
            device_id: None,
        }
    }

    fn stored() -> Stored {
        Stored {
            license: Some(record()),
            pending_cleanups: vec![Probe {
                license_key: "KEY-0".into(),
                instance_id: "inst-0".into(),
            }],
        }
    }

    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    /// Permission bits mean nothing to root; a test that relies on them is skipped there.
    fn permissions_enforced(root: &Path) -> bool {
        let probe = root.join("probe");
        fs::create_dir(&probe).unwrap();
        fs::write(probe.join("f"), b"x").unwrap();
        fs::set_permissions(&probe, fs::Permissions::from_mode(0o000)).unwrap();
        let enforced = fs::read(probe.join("f")).is_err();
        fs::set_permissions(&probe, fs::Permissions::from_mode(0o700)).unwrap();
        enforced
    }

    #[test]
    fn both_records_round_trip_and_reopen_with_the_same_uuid() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        assert_eq!(vault.load().unwrap(), Stored::default());
        assert_eq!(vault.load_trial().unwrap(), None);
        vault.save(&stored()).unwrap();
        vault.save_trial(&trial()).unwrap();
        assert_eq!(vault.load().unwrap(), stored());
        assert_eq!(vault.load_trial().unwrap(), Some(trial()));
        // A restart derives the same key and finds the same records.
        let reopened = store(dir.path(), Some(UUID));
        assert_eq!(reopened.load().unwrap(), stored());
        assert_eq!(reopened.load_trial().unwrap(), Some(trial()));
    }

    #[test]
    fn the_files_start_with_the_magic_and_hide_the_record() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        vault.save_trial(&trial()).unwrap();
        let bytes = fs::read(vault.directory().join(TRIAL_FILE)).unwrap();
        assert!(bytes.starts_with(MAGIC));
        assert_eq!(
            bytes.len(),
            MAGIC.len() + NONCE_LEN + serde_json::to_vec(&trial()).unwrap().len() + TAG_LEN
        );
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains("started_at"), "{text}");
        // Every write picks a fresh nonce.
        vault.save_trial(&trial()).unwrap();
        assert_ne!(fs::read(vault.directory().join(TRIAL_FILE)).unwrap(), bytes);
    }

    #[test]
    fn another_mac_cannot_open_the_files() {
        let dir = tempfile::tempdir().unwrap();
        store(dir.path(), Some(UUID)).save(&stored()).unwrap();
        store(dir.path(), Some(UUID)).save_trial(&trial()).unwrap();
        let other = store(dir.path(), Some("11111111-2222-3333-4444-555555555555"));
        let error = other.load().unwrap_err();
        assert!(error.contains("The saved license is unreadable"), "{error}");
        let error = other.load_trial().unwrap_err();
        assert!(
            error.contains("The saved free trial is unreadable"),
            "{error}"
        );
        // No hardware UUID at all is a different key too.
        assert!(store(dir.path(), None).load_trial().is_err());
    }

    #[test]
    fn a_tampered_byte_is_corrupt_and_left_in_place() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        vault.save_trial(&trial()).unwrap();
        let path = vault.directory().join(TRIAL_FILE);
        let mut bytes = fs::read(&path).unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 0x01;
        fs::write(&path, &bytes).unwrap();
        assert_eq!(
            vault.read::<TrialRecord>(TRIAL_FILE),
            Err(ReadError::Corrupt(
                "the record was not written by this Mac".into()
            ))
        );
        assert_eq!(fs::read(&path).unwrap(), bytes, "never replaced");
        // Wrong magic and a short file are corrupt as well, never absent.
        fs::write(&path, b"{\"started_at\":1}").unwrap();
        assert!(matches!(
            vault.read::<TrialRecord>(TRIAL_FILE),
            Err(ReadError::Corrupt(_))
        ));
        fs::write(&path, &bytes[..MAGIC.len() + 5]).unwrap();
        assert!(matches!(
            vault.read::<TrialRecord>(TRIAL_FILE),
            Err(ReadError::Corrupt(_))
        ));
    }

    #[test]
    fn a_file_moved_under_another_name_is_corrupt() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        vault.save_trial(&trial()).unwrap();
        fs::rename(
            vault.directory().join(TRIAL_FILE),
            vault.directory().join(LICENSE_FILE),
        )
        .unwrap();
        assert!(matches!(
            vault.read::<Record>(LICENSE_FILE),
            Err(ReadError::Corrupt(_))
        ));
    }

    #[test]
    fn json_the_app_does_not_understand_is_corrupt() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        vault
            .write(TRIAL_FILE, &serde_json::json!({ "started_at": "soon" }))
            .unwrap();
        assert!(matches!(
            vault.read::<TrialRecord>(TRIAL_FILE),
            Err(ReadError::Corrupt(_))
        ));
        assert!(vault.load_trial().is_err());
    }

    #[test]
    fn a_missing_file_or_directory_is_positively_absent() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        assert!(!vault.directory().exists());
        assert_eq!(vault.read::<TrialRecord>(TRIAL_FILE), Ok(None));
        assert_eq!(vault.load_trial(), Ok(None));
        assert_eq!(vault.load(), Ok(Stored::default()));
        assert!(!vault.directory().exists(), "a read creates nothing");
    }

    #[test]
    fn an_unreadable_directory_is_unavailable_not_absent() {
        let dir = tempfile::tempdir().unwrap();
        if !permissions_enforced(dir.path()) {
            eprintln!("skipped: running as root");
            return;
        }
        let vault = store(dir.path(), Some(UUID));
        vault.save_trial(&trial()).unwrap();
        fs::set_permissions(vault.directory(), fs::Permissions::from_mode(0o000)).unwrap();
        let outcome = vault.read::<TrialRecord>(TRIAL_FILE);
        let license = vault.load();
        let trial_error = vault.load_trial();
        fs::set_permissions(vault.directory(), fs::Permissions::from_mode(0o700)).unwrap();
        assert!(
            matches!(outcome, Err(ReadError::Unavailable(_))),
            "{outcome:?}"
        );
        assert!(license.unwrap_err().contains("could not be read"));
        assert!(trial_error.unwrap_err().contains("could not be read"));
        // Nothing was replaced meanwhile.
        assert_eq!(vault.load_trial().unwrap(), Some(trial()));
    }

    #[test]
    fn an_unreadable_file_is_unavailable() {
        let dir = tempfile::tempdir().unwrap();
        if !permissions_enforced(dir.path()) {
            eprintln!("skipped: running as root");
            return;
        }
        let vault = store(dir.path(), Some(UUID));
        vault.save_trial(&trial()).unwrap();
        let path = vault.directory().join(TRIAL_FILE);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o000)).unwrap();
        assert!(matches!(
            vault.read::<TrialRecord>(TRIAL_FILE),
            Err(ReadError::Unavailable(_))
        ));
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    }

    #[test]
    fn a_failed_write_leaves_the_old_file_and_no_leftovers() {
        let dir = tempfile::tempdir().unwrap();
        if !permissions_enforced(dir.path()) {
            eprintln!("skipped: running as root");
            return;
        }
        let vault = store(dir.path(), Some(UUID));
        vault.save_trial(&trial()).unwrap();
        let path = vault.directory().join(TRIAL_FILE);
        let before = fs::read(&path).unwrap();
        // A directory nobody can write into: the temporary file cannot even be created.
        fs::set_permissions(vault.directory(), fs::Permissions::from_mode(0o500)).unwrap();
        let outcome = vault.save_trial(&TrialRecord {
            last_seen_at: 1_700_010_000,
            ..trial()
        });
        fs::set_permissions(vault.directory(), fs::Permissions::from_mode(0o700)).unwrap();
        assert!(outcome.unwrap_err().contains("could not be saved"));
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(vault.load_trial().unwrap(), Some(trial()));
        let names: Vec<String> = fs::read_dir(vault.directory())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec![TRIAL_FILE.to_string()]);
    }

    #[test]
    fn removing_the_mac_deletes_the_license_and_never_the_trial() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        vault.save(&stored()).unwrap();
        vault.save_trial(&trial()).unwrap();
        let trial_bytes = fs::read(vault.directory().join(TRIAL_FILE)).unwrap();
        // Removed, with the deactivation still owed.
        vault
            .save(&Stored {
                license: None,
                pending_cleanups: vec![Probe {
                    license_key: "KEY-1".into(),
                    instance_id: "inst-1".into(),
                }],
            })
            .unwrap();
        assert!(!vault.directory().join(LICENSE_FILE).exists());
        assert!(vault.directory().join(CLEANUPS_FILE).exists());
        assert_eq!(
            fs::read(vault.directory().join(TRIAL_FILE)).unwrap(),
            trial_bytes
        );
        assert_eq!(vault.load().unwrap().pending_cleanups.len(), 1);
        assert_eq!(vault.load().unwrap().license, None);
        // The cleanup delivered: nothing of the license is left, the trial still is.
        vault.save(&Stored::default()).unwrap();
        assert!(!vault.directory().join(CLEANUPS_FILE).exists());
        assert_eq!(vault.load().unwrap(), Stored::default());
        assert_eq!(vault.load_trial().unwrap(), Some(trial()));
        // Removing twice is fine.
        vault.save(&Stored::default()).unwrap();
    }

    #[test]
    fn the_directory_and_files_are_private() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        vault.save(&stored()).unwrap();
        vault.save_trial(&trial()).unwrap();
        assert_eq!(mode(vault.directory()), 0o700);
        for name in [LICENSE_FILE, TRIAL_FILE, CLEANUPS_FILE] {
            assert_eq!(mode(&vault.directory().join(name)), 0o600, "{name}");
        }
        // Rewriting keeps the modes even under a permissive umask.
        vault.save_trial(&trial()).unwrap();
        assert_eq!(mode(&vault.directory().join(TRIAL_FILE)), 0o600);
    }

    #[test]
    fn the_key_is_bound_to_the_app_and_the_uuid() {
        assert_eq!(derive_key(APP, Some(UUID)), derive_key(APP, Some(UUID)));
        assert_ne!(derive_key(APP, Some(UUID)), derive_key("other", Some(UUID)));
        assert_ne!(derive_key(APP, Some(UUID)), derive_key(APP, None));
        assert_eq!(
            derive_key(APP, None),
            derive_key(APP, Some(NO_HARDWARE_UUID))
        );
    }

    #[test]
    fn the_directory_follows_the_contract() {
        assert_eq!(
            RecordStore::directory_under(Path::new("/Users/x/Library/Application Support"), APP),
            PathBuf::from("/Users/x/Library/Application Support/OpenApps/openklack/records")
        );
    }
}
