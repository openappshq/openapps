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
//! Every path below the Application Support directory is walked one component at a time
//! through directory descriptors, never following a symlink: a link, or anything but a regular
//! file, where a record or one of the store's directories should be is *unavailable*, not
//! absent, and nothing is written through it.
//!
//! Read outcomes keep the storage semantics the engine relies on: a missing entry is positively
//! absent, a directory or file that cannot be read is unavailable, and a file that fails the
//! magic, the authentication tag or JSON decoding is corrupt. Unavailable and corrupt are
//! storage errors: no new trial, no registry call, and the file is left in place.
//!
//! A write is a temporary file in the records directory, `fsync`, a rename over the old file,
//! then `fsync` of the directory. Everything up to the rename can fail with the old record
//! intact (`SaveError::Failed`). After the rename only the directory sync is left; when it
//! fails, the new record is in place but not known to be durable, which is reported as
//! `SaveError::Indeterminate` so the caller keeps the new record and repeats the write.
//!
//! Old Keychain items from releases before 0.1.2 are never read, written or deleted; touching
//! them is what prompts.

use super::core::{Probe, Record, Stored, TrialRecord};
use super::runtime::{SaveError, Vault};
use aes_gcm::{
    Aes256Gcm, Key, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use serde::{Serialize, de::DeserializeOwned};
use std::{
    ffi::CString,
    fs,
    io::{self, Read, Write},
    os::fd::{AsRawFd, FromRawFd},
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
/// The store's directories under Application Support, outermost first.
const VENDOR_DIRECTORY: &str = "OpenApps";
const RECORDS_DIRECTORY: &str = "records";

/// Why a record could not be read. Both are storage errors to the engine; the distinction is
/// for the message and the tests.
#[derive(Debug, PartialEq, Eq)]
pub enum ReadError {
    /// The directory or the file exists but could not be read, or is not what it should be
    /// (a symlink, something other than a regular file or a directory).
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

/// How a directory's changes are made durable; tests replace it to fail after the rename.
type DirectorySync = Box<dyn Fn(&fs::File) -> io::Result<()> + Send + Sync>;

/// The encrypted files under one records directory.
pub struct RecordStore {
    /// The user's Application Support directory, the one path the store follows links in.
    application_support: PathBuf,
    app_id: String,
    key: [u8; KEY_LEN],
    directory_sync: DirectorySync,
}

impl RecordStore {
    /// A store under `application_support/OpenApps/<app id>/records`, keyed by this Mac's
    /// hardware UUID. The directories are created on the first write, never on a read.
    pub fn new(application_support: PathBuf, app_id: &str, hardware_uuid: Option<&str>) -> Self {
        Self {
            application_support,
            app_id: app_id.to_string(),
            key: derive_key(app_id, hardware_uuid),
            directory_sync: Box::new(fs::File::sync_all),
        }
    }

    #[cfg(test)]
    fn with_directory_sync(mut self, sync: DirectorySync) -> Self {
        self.directory_sync = sync;
        self
    }

    /// The records directory's path; every access goes through descriptors instead.
    #[cfg(test)]
    fn directory(&self) -> PathBuf {
        self.application_support
            .join(VENDOR_DIRECTORY)
            .join(&self.app_id)
            .join(RECORDS_DIRECTORY)
    }

    fn aad(&self, name: &str) -> Vec<u8> {
        format!("{}:{name}", self.app_id).into_bytes()
    }

    /// The records directory, `None` while none of the store's directories exist yet. With
    /// `create`, missing ones are made (`0700`); an existing entry that is not a real
    /// directory is an error either way.
    fn records(&self, create: bool) -> io::Result<Option<Dir>> {
        let mut dir = match Dir::open_root(&self.application_support) {
            Ok(dir) => dir,
            Err(error) if error.kind() == io::ErrorKind::NotFound && !create => return Ok(None),
            Err(error) => return Err(error),
        };
        for name in [VENDOR_DIRECTORY, self.app_id.as_str(), RECORDS_DIRECTORY] {
            dir = match dir.child(name, create)? {
                Some(child) => child,
                None => return Ok(None),
            };
        }
        Ok(Some(dir))
    }

    /// The record in `name`, `None` when the entry positively does not exist.
    pub fn read<T: DeserializeOwned>(&self, name: &str) -> Result<Option<T>, ReadError> {
        let unavailable = |error: io::Error| ReadError::Unavailable(error.to_string());
        let Some(dir) = self.records(false).map_err(unavailable)? else {
            return Ok(None);
        };
        let Some(mut file) = dir.open_record(name).map_err(unavailable)? else {
            return Ok(None);
        };
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).map_err(unavailable)?;
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

    /// Replaces `name`: the sealed bytes go to a temporary file in the records directory, are
    /// synced, and are renamed over the old file, which stays intact until then. An entry at
    /// `name` that is not a regular file is never replaced.
    pub fn write<T: Serialize>(&self, name: &str, record: &T) -> Result<(), SaveError> {
        let failed = |error: io::Error| SaveError::Failed(error.to_string());
        let json =
            serde_json::to_vec(record).map_err(|error| SaveError::Failed(error.to_string()))?;
        let bytes = self.seal(name, &json)?;
        let dir = self
            .records(true)
            .map_err(failed)?
            .expect("created on demand");
        dir.expect_regular_or_absent(name).map_err(failed)?;
        let staging = format!(".{name}.{}.tmp", crate::library::unique_suffix());
        let written = dir
            .create_private(&staging)
            .and_then(|mut file| file.write_all(&bytes).and_then(|()| file.sync_all()))
            .and_then(|()| dir.rename(&staging, name));
        if let Err(error) = written {
            let _ = dir.unlink(&staging);
            return Err(failed(error));
        }
        // The new record is in place; only its durability is in question from here on.
        (self.directory_sync)(&dir.0).map_err(|error| SaveError::Indeterminate(error.to_string()))
    }

    fn seal(&self, name: &str, json: &[u8]) -> Result<Vec<u8>, SaveError> {
        let mut nonce = [0u8; NONCE_LEN];
        getrandom::fill(&mut nonce)
            .map_err(|error| SaveError::Failed(format!("no randomness: {error}")))?;
        let ciphertext = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&self.key))
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: json,
                    aad: &self.aad(name),
                },
            )
            .map_err(|_| SaveError::Failed("the record could not be sealed".to_string()))?;
        let mut bytes = Vec::with_capacity(MAGIC.len() + NONCE_LEN + ciphertext.len());
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&nonce);
        bytes.extend_from_slice(&ciphertext);
        Ok(bytes)
    }

    /// Removes `name`; an entry that is not a regular file is left alone. After the unlink
    /// only the directory sync can fail, which leaves the removal in place but unconfirmed.
    /// An entry that is already gone is synced all the same: the caller retries a delete
    /// exactly because an earlier unlink was not confirmed, and `Ok` must mean the absence is
    /// durable, not merely visible. Only a store whose directories never existed has nothing
    /// to confirm.
    pub fn delete(&self, name: &str) -> Result<(), SaveError> {
        let failed = |error: io::Error| SaveError::Failed(error.to_string());
        let Some(dir) = self.records(false).map_err(failed)? else {
            return Ok(());
        };
        dir.expect_regular_or_absent(name).map_err(failed)?;
        match dir.unlink(name) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(failed(error)),
        }
        (self.directory_sync)(&dir.0).map_err(|error| SaveError::Indeterminate(error.to_string()))
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

/// An open directory. Every operation is relative to its descriptor and never follows a
/// symlink, so a link swapped in after the directory was opened changes nothing.
struct Dir(fs::File);

fn c_name(name: &str) -> io::Result<CString> {
    CString::new(name).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "name with NUL"))
}

fn last_error() -> io::Error {
    io::Error::last_os_error()
}

impl Dir {
    /// The Application Support directory itself: the one path that may be a link.
    fn open_root(path: &Path) -> io::Result<Dir> {
        use std::os::unix::fs::OpenOptionsExt;
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC)
            .open(path)?;
        Ok(Dir(file))
    }

    /// The subdirectory `name`, never through a link: `None` when there is no such entry, an
    /// error when the entry is a link or not a directory. With `create`, a missing one is made
    /// with mode `0700` (and opened the same strict way afterwards).
    fn child(&self, name: &str, create: bool) -> io::Result<Option<Dir>> {
        match self.open_at(name, libc::O_RDONLY | libc::O_DIRECTORY, 0) {
            Ok(file) => return Ok(Some(Dir(file))),
            Err(error) if error.kind() == io::ErrorKind::NotFound && create => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        }
        let name_c = c_name(name)?;
        // SAFETY: a valid descriptor and a NUL-terminated name.
        if unsafe { libc::mkdirat(self.0.as_raw_fd(), name_c.as_ptr(), 0o700) } != 0 {
            let error = last_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error);
            }
        }
        self.open_at(name, libc::O_RDONLY | libc::O_DIRECTORY, 0)
            .map(|file| Some(Dir(file)))
    }

    /// `openat` with `O_NOFOLLOW | O_CLOEXEC` added.
    fn open_at(&self, name: &str, flags: libc::c_int, mode: libc::c_uint) -> io::Result<fs::File> {
        let name_c = c_name(name)?;
        let flags = flags | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: a valid descriptor and a NUL-terminated name; the returned descriptor is
        // owned by the `File` from here on.
        let fd = unsafe { libc::openat(self.0.as_raw_fd(), name_c.as_ptr(), flags, mode) };
        if fd < 0 {
            return Err(last_error());
        }
        Ok(unsafe { fs::File::from_raw_fd(fd) })
    }

    /// The record `name` for reading: `None` when there is no such entry, an error when it is a
    /// link or anything but a regular file.
    fn open_record(&self, name: &str) -> io::Result<Option<fs::File>> {
        // O_NONBLOCK so an entry that is a FIFO fails the check below instead of blocking.
        let file = match self.open_at(name, libc::O_RDONLY | libc::O_NONBLOCK, 0) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        if !file.metadata()?.is_file() {
            return Err(io::Error::other(format!("{name} is not a regular file")));
        }
        Ok(Some(file))
    }

    /// Fails unless the entry `name` is absent or a regular file.
    fn expect_regular_or_absent(&self, name: &str) -> io::Result<()> {
        let name_c = c_name(name)?;
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        // SAFETY: a valid descriptor, a NUL-terminated name and a properly sized buffer that
        // is only read after the call succeeded.
        let status = unsafe {
            libc::fstatat(
                self.0.as_raw_fd(),
                name_c.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        if status != 0 {
            let error = last_error();
            return if error.kind() == io::ErrorKind::NotFound {
                Ok(())
            } else {
                Err(error)
            };
        }
        let stat = unsafe { stat.assume_init() };
        if stat.st_mode & libc::S_IFMT == libc::S_IFREG {
            Ok(())
        } else {
            Err(io::Error::other(format!("{name} is not a regular file")))
        }
    }

    /// A new file `name` only this user can read.
    fn create_private(&self, name: &str) -> io::Result<fs::File> {
        self.open_at(name, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL, 0o600)
    }

    fn rename(&self, from: &str, to: &str) -> io::Result<()> {
        let (from_c, to_c) = (c_name(from)?, c_name(to)?);
        let fd = self.0.as_raw_fd();
        // SAFETY: valid descriptors and NUL-terminated names.
        if unsafe { libc::renameat(fd, from_c.as_ptr(), fd, to_c.as_ptr()) } != 0 {
            return Err(last_error());
        }
        Ok(())
    }

    fn unlink(&self, name: &str) -> io::Result<()> {
        let name_c = c_name(name)?;
        // SAFETY: a valid descriptor and a NUL-terminated name.
        if unsafe { libc::unlinkat(self.0.as_raw_fd(), name_c.as_ptr(), 0) } != 0 {
            return Err(last_error());
        }
        Ok(())
    }
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

    /// The cleanups first, then the license (deleted when the Mac has been removed). A crash
    /// between the two leaves the old license beside the new cleanup list.
    ///
    /// `Failed` from here guarantees only that the license file is untouched: the cleanups
    /// file may already hold the new list (its own write failed after the rename, or it
    /// succeeded and the license step failed). That is safe because the caller keeps the
    /// same list in memory and rewrites it on the retry. Only the license file's own
    /// unconfirmed write or removal is reported as `Indeterminate`.
    fn save(&self, stored: &Stored) -> Result<(), SaveError> {
        let cleanups = if stored.pending_cleanups.is_empty() {
            self.delete(CLEANUPS_FILE)
        } else {
            self.write(CLEANUPS_FILE, &stored.pending_cleanups)
        };
        if let Err(error) = cleanups {
            return Err(SaveError::Failed(format!(
                "The license cleanups could not be saved: {}",
                error.reason()
            )));
        }
        match &stored.license {
            Some(record) => self.write(LICENSE_FILE, record),
            None => self.delete(LICENSE_FILE),
        }
        .map_err(|error| error.described("The license"))
    }

    fn load_trial(&self) -> Result<Option<TrialRecord>, String> {
        self.read(TRIAL_FILE)
            .map_err(|error| format!("The saved free trial {error}"))
    }

    fn save_trial(&self, trial: &TrialRecord) -> Result<(), SaveError> {
        self.write(TRIAL_FILE, trial)
            .map_err(|error| error.described("The free trial"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        os::unix::fs::{PermissionsExt, symlink},
        sync::{
            Arc,
            atomic::{AtomicBool, AtomicUsize, Ordering},
        },
    };

    const APP: &str = "openklack";
    const UUID: &str = "5B7E2C1A-0F3D-4E8A-9C21-7D6F5A4B3C2D";

    fn store(root: &Path, uuid: Option<&str>) -> RecordStore {
        RecordStore::new(root.to_path_buf(), APP, uuid)
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
        assert!(
            matches!(&outcome, Err(SaveError::Failed(reason)) if reason.contains("could not be saved")),
            "{outcome:?}"
        );
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
        assert_eq!(mode(&vault.directory()), 0o700);
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
        let vault = RecordStore::new(
            PathBuf::from("/Users/x/Library/Application Support"),
            APP,
            Some(UUID),
        );
        assert_eq!(
            vault.directory(),
            PathBuf::from("/Users/x/Library/Application Support/OpenApps/openklack/records")
        );
    }

    #[test]
    fn a_dangling_link_where_a_record_should_be_is_unavailable_not_absent() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        vault.save(&stored()).unwrap();
        let path = vault.directory().join(TRIAL_FILE);
        symlink("nowhere", &path).unwrap();
        assert!(matches!(
            vault.read::<TrialRecord>(TRIAL_FILE),
            Err(ReadError::Unavailable(_))
        ));
        let error = vault.load_trial().unwrap_err();
        assert!(error.contains("could not be read"), "{error}");
        // No write goes through the link, not even a provisional trial.
        assert!(matches!(
            vault.save_trial(&trial()),
            Err(SaveError::Failed(_))
        ));
        assert_eq!(fs::read_link(&path).unwrap(), PathBuf::from("nowhere"));
        assert!(!dir.path().join("nowhere").exists());
        assert_eq!(
            vault.load().unwrap(),
            stored(),
            "the other records still read"
        );
    }

    #[test]
    fn a_link_to_a_valid_record_is_unavailable() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        vault.save_trial(&trial()).unwrap();
        let path = vault.directory().join(TRIAL_FILE);
        let aside = dir.path().join("trial-elsewhere");
        fs::rename(&path, &aside).unwrap();
        symlink(&aside, &path).unwrap();
        assert!(matches!(
            vault.read::<TrialRecord>(TRIAL_FILE),
            Err(ReadError::Unavailable(_))
        ));
        assert!(matches!(
            vault.save_trial(&trial()),
            Err(SaveError::Failed(_))
        ));
        assert!(matches!(
            vault.delete(TRIAL_FILE),
            Err(SaveError::Failed(_))
        ));
        assert_eq!(fs::read_link(&path).unwrap(), aside);
        // The target still opens directly, untouched.
        fs::rename(&aside, &path).unwrap();
        assert_eq!(vault.load_trial().unwrap(), Some(trial()));
    }

    #[test]
    fn a_dangling_link_where_the_records_directory_should_be_is_unavailable() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        let parent = dir.path().join(VENDOR_DIRECTORY).join(APP);
        fs::create_dir_all(&parent).unwrap();
        symlink("nowhere", parent.join(RECORDS_DIRECTORY)).unwrap();
        assert!(matches!(
            vault.read::<TrialRecord>(TRIAL_FILE),
            Err(ReadError::Unavailable(_))
        ));
        assert!(vault.load().is_err());
        assert!(vault.load_trial().is_err());
        assert!(matches!(
            vault.save_trial(&trial()),
            Err(SaveError::Failed(_))
        ));
        assert_eq!(
            fs::read_link(parent.join(RECORDS_DIRECTORY)).unwrap(),
            PathBuf::from("nowhere")
        );
        assert!(
            !parent.join("nowhere").exists(),
            "nothing was created through the link"
        );
    }

    #[test]
    fn a_linked_ancestor_is_unavailable_even_when_it_resolves() {
        let dir = tempfile::tempdir().unwrap();
        let elsewhere = dir.path().join("elsewhere");
        fs::create_dir(&elsewhere).unwrap();
        symlink(&elsewhere, dir.path().join(VENDOR_DIRECTORY)).unwrap();
        let vault = store(dir.path(), Some(UUID));
        assert!(matches!(
            vault.read::<TrialRecord>(TRIAL_FILE),
            Err(ReadError::Unavailable(_))
        ));
        assert!(matches!(
            vault.save_trial(&trial()),
            Err(SaveError::Failed(_))
        ));
        assert!(fs::read_dir(&elsewhere).unwrap().next().is_none());
    }

    #[test]
    fn a_directory_replaced_by_a_file_is_unavailable() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        fs::create_dir_all(dir.path().join(VENDOR_DIRECTORY).join(APP)).unwrap();
        fs::write(vault.directory(), b"not a directory").unwrap();
        assert!(matches!(
            vault.read::<TrialRecord>(TRIAL_FILE),
            Err(ReadError::Unavailable(_))
        ));
        assert!(matches!(
            vault.save_trial(&trial()),
            Err(SaveError::Failed(_))
        ));
        assert_eq!(fs::read(vault.directory()).unwrap(), b"not a directory");
    }

    #[test]
    fn a_failed_directory_sync_after_the_rename_is_indeterminate_and_the_record_is_in_place() {
        let dir = tempfile::tempdir().unwrap();
        let vault = store(dir.path(), Some(UUID));
        vault.save_trial(&trial()).unwrap();
        let unconfirmed = store(dir.path(), Some(UUID))
            .with_directory_sync(Box::new(|_| Err(io::Error::other("disk gone"))));
        let newer = TrialRecord {
            last_seen_at: 1_700_010_000,
            ..trial()
        };
        let outcome = unconfirmed.save_trial(&newer);
        assert!(
            matches!(&outcome, Err(SaveError::Indeterminate(reason)) if reason.contains("could not be confirmed")),
            "{outcome:?}"
        );
        // A restart finds the new record, and no temporary file is left behind.
        assert_eq!(
            store(dir.path(), Some(UUID)).load_trial().unwrap(),
            Some(newer)
        );
        let names: Vec<String> = fs::read_dir(vault.directory())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec![TRIAL_FILE.to_string()]);
        // The license's own unconfirmed write is indeterminate too (the cleanups step, a
        // delete of an absent file, is let through); an unconfirmed cleanups write is an
        // ordinary failure, since the license file has not been touched yet.
        let (sync, flaky) = FlakySync::new();
        let unconfirmed = store(dir.path(), Some(UUID)).with_directory_sync(sync);
        flaky.pass.store(1, Ordering::SeqCst);
        let outcome = unconfirmed.save(&Stored {
            license: Some(record()),
            pending_cleanups: vec![],
        });
        assert!(
            matches!(outcome, Err(SaveError::Indeterminate(_))),
            "{outcome:?}"
        );
        assert_eq!(flaky.calls(), 2);
        assert_eq!(vault.load().unwrap().license, Some(record()));
        let outcome = unconfirmed.save(&stored());
        assert!(
            matches!(&outcome, Err(SaveError::Failed(reason)) if reason.contains("cleanups")),
            "{outcome:?}"
        );
        assert_eq!(flaky.calls(), 3, "the license step was never reached");
        assert_eq!(
            vault.load().unwrap().pending_cleanups,
            stored().pending_cleanups
        );
        assert_eq!(vault.load().unwrap().license, Some(record()));
    }

    /// A directory sync that fails while `failing` is set, except for the next `pass` calls,
    /// and counts every call.
    struct FlakySync {
        failing: Arc<AtomicBool>,
        pass: Arc<AtomicUsize>,
        calls: Arc<AtomicUsize>,
    }

    impl FlakySync {
        fn new() -> (DirectorySync, FlakySync) {
            let flaky = FlakySync {
                failing: Arc::new(AtomicBool::new(true)),
                pass: Arc::new(AtomicUsize::new(0)),
                calls: Arc::new(AtomicUsize::new(0)),
            };
            let (failing, pass, calls) = (
                flaky.failing.clone(),
                flaky.pass.clone(),
                flaky.calls.clone(),
            );
            let sync: DirectorySync = Box::new(move |file: &fs::File| {
                calls.fetch_add(1, Ordering::SeqCst);
                let let_through = pass
                    .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |left| {
                        left.checked_sub(1)
                    })
                    .is_ok();
                if failing.load(Ordering::SeqCst) && !let_through {
                    Err(io::Error::other("disk gone"))
                } else {
                    file.sync_all()
                }
            });
            (sync, flaky)
        }
        fn calls(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }
    }

    #[test]
    fn a_failed_directory_sync_after_the_unlink_stays_indeterminate_until_a_sync_confirms_it() {
        let dir = tempfile::tempdir().unwrap();
        store(dir.path(), Some(UUID)).save(&stored()).unwrap();
        let (sync, flaky) = FlakySync::new();
        let vault = store(dir.path(), Some(UUID)).with_directory_sync(sync);
        let outcome = vault.delete(LICENSE_FILE);
        assert!(
            matches!(outcome, Err(SaveError::Indeterminate(_))),
            "{outcome:?}"
        );
        assert!(!vault.directory().join(LICENSE_FILE).exists());
        assert_eq!(flaky.calls(), 1);
        // The entry is gone from view, but the retry still has to confirm it.
        let outcome = vault.delete(LICENSE_FILE);
        assert!(
            matches!(outcome, Err(SaveError::Indeterminate(_))),
            "{outcome:?}"
        );
        assert_eq!(flaky.calls(), 2, "synced again");
        // The whole save never confirms either: the cleanups step (a delete of an already
        // absent file) fails to confirm first, and with it let through, the license step
        // is the unconfirmed one.
        let outcome = vault.save(&Stored::default());
        assert!(
            matches!(&outcome, Err(SaveError::Failed(reason)) if reason.contains("cleanups")),
            "{outcome:?}"
        );
        assert_eq!(flaky.calls(), 3);
        flaky.pass.store(1, Ordering::SeqCst);
        let outcome = vault.save(&Stored::default());
        assert!(
            matches!(outcome, Err(SaveError::Indeterminate(_))),
            "{outcome:?}"
        );
        assert_eq!(flaky.calls(), 5);
        // Confirmed at last.
        flaky.failing.store(false, Ordering::SeqCst);
        assert_eq!(vault.delete(LICENSE_FILE), Ok(()));
        assert_eq!(vault.save(&Stored::default()), Ok(()));
        assert_eq!(flaky.calls(), 8);
        assert_eq!(vault.load().unwrap().license, None);
        // A store whose directories never existed has nothing to confirm.
        let empty = tempfile::tempdir().unwrap();
        let (sync, flaky) = FlakySync::new();
        let vault = store(empty.path(), Some(UUID)).with_directory_sync(sync);
        assert_eq!(vault.delete(LICENSE_FILE), Ok(()));
        assert_eq!(vault.save(&Stored::default()), Ok(()));
        assert_eq!(flaky.calls(), 0);
        assert!(!empty.path().join(VENDOR_DIRECTORY).exists());
    }
}
