//! The licensed build's plumbing around `core`: the license and trial Keychain records, the Dodo
//! and trial registry HTTP clients, the scheduler, and the commands and events the settings
//! window uses.
//!
//! Rules: lock first, persist after, and unlock only after the record is saved.
//! `Service::mutate` orders every license Keychain write and `Service::trial_mutate` every trial
//! write, so a slower writer can never put an older record back. `Service::engine` is only ever
//! held for a pure step, never across the network or the Keychain, so reads for the window and
//! the deep link never wait on I/O. Every gate decision carries a revision issued under the
//! engine lock, and the audio side applies only newer ones; a restrictive decision is published
//! before any I/O, a permissive one after the save it depends on. While the records are unknown,
//! playback stays gated.

use super::core::{
    APP_ID, Activation, DAY, Dodo, DodoError, Engine, GRACE_WARNING_AFTER, LicenseError, Moment,
    Probe, Products, Refusal, Registry, RegistryAnswer, RegistryError, State, Stored, TrialRecord,
    TrialSlot, Validation, device_hash,
};
use crate::engine::Controller;
use serde::Serialize;
use std::{
    sync::{
        Arc, Condvar, Mutex, MutexGuard,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, SystemTime},
};
use tauri::{Emitter, Manager};

/// The revocation journal's file name in the app's data directory.
const JOURNAL_FILE: &str = "license-journal.json";
/// A failed Keychain read, or a trial that could not be saved, is retried with backoff from a
/// minute up to an hour.
const LOAD_RETRY_MIN: i64 = 60;
const LOAD_RETRY_MAX: i64 = 3600;

pub const KEYCHAIN_SERVICE: &str = "space.openapps.openklack.license";
const KEYCHAIN_ACCOUNT: &str = "license";
pub const TRIAL_KEYCHAIN_SERVICE: &str = "space.openapps.openklack.trial";
const TRIAL_KEYCHAIN_ACCOUNT: &str = "trial";
const HOST: &str = env!("OPENKLACK_DODO_HOST");
const ENVIRONMENT: &str = env!("OPENKLACK_LICENSE_ENV");
const PAID_PRODUCT_ID: &str = env!("OPENKLACK_DODO_PAID_PRODUCT_ID");
const BUY_URL: &str = env!("OPENKLACK_BUY_URL");
const SUPPORT_URL: &str = env!("OPENKLACK_SUPPORT_URL");
/// The trial registry's origin; requests go to `/api/trial` under it.
const REGISTRY_URL: &str = env!("OPENKLACK_TRIAL_REGISTRY_URL");
/// The scheduler re-evaluates at least this often so clock changes and long sleeps are noticed.
const MAX_SLEEP: Duration = Duration::from_secs(3600);
/// While a deadline is pending or the clock is behind, the clock is looked at this often.
const DEADLINE_RECHECK: Duration = Duration::from_secs(60);
/// While checks fail, the network is probed this often so a check runs as soon as it is back.
const REACHABILITY_POLL: Duration = Duration::from_secs(300);
/// Owed deactivations are retried this often.
const CLEANUP_RETRY: Duration = Duration::from_secs(300);
/// A rising `last_seen_at` is saved at most this often; the trial's end and quitting save it too.
const TRIAL_SAVE_INTERVAL: i64 = 3600;
/// Quitting waits at most this long for the trial record to be saved.
const QUIT_SAVE_WAIT: Duration = Duration::from_secs(2);

/// Comma-separated IDs let a future bundle product join the paid list without code changes.
pub fn products() -> Products {
    Products {
        paid: PAID_PRODUCT_ID
            .split(',')
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
            .collect(),
    }
}

fn system_now() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}

/// Seconds on a monotonic clock that keeps counting while the Mac sleeps.
#[cfg(target_os = "macos")]
fn monotonic_now() -> i64 {
    #[repr(C)]
    struct Timebase {
        numer: u32,
        denom: u32,
    }
    unsafe extern "C" {
        fn mach_continuous_time() -> u64;
        fn mach_timebase_info(info: *mut Timebase) -> i32;
    }
    let mut timebase = Timebase { numer: 1, denom: 1 };
    // SAFETY: both are plain libSystem calls; the struct matches `mach_timebase_info_data_t`.
    let ticks = unsafe {
        mach_timebase_info(&mut timebase);
        mach_continuous_time()
    };
    let nanos = ticks as u128 * timebase.numer as u128 / timebase.denom.max(1) as u128;
    (nanos / 1_000_000_000) as i64
}

#[cfg(not(target_os = "macos"))]
fn monotonic_now() -> i64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START
        .get_or_init(std::time::Instant::now)
        .elapsed()
        .as_secs() as i64
}

/// `Retry-After` as seconds: a delay, or an HTTP date relative to the server's clock.
fn retry_after_seconds(value: &str, server_time: Option<i64>) -> Option<i64> {
    let value = value.trim();
    if let Ok(seconds) = value.parse::<i64>() {
        return Some(seconds.clamp(1, DAY));
    }
    let at = chrono::DateTime::parse_from_rfc2822(value)
        .ok()?
        .timestamp();
    Some((at - server_time.unwrap_or_else(system_now)).clamp(1, DAY))
}

/// Debug builds only: `OPENKLACK_DEBUG_TRIAL_MINUTES` shortens the trial for manual end-to-end
/// runs. Release builds always use the full length.
#[cfg(debug_assertions)]
fn debug_trial_terms() -> Option<super::core::TrialTerms> {
    let minutes = std::env::var("OPENKLACK_DEBUG_TRIAL_MINUTES")
        .ok()?
        .trim()
        .parse::<i64>()
        .ok()
        .filter(|minutes| *minutes > 0)?;
    Some(super::core::TrialTerms::shortened(
        minutes.saturating_mul(60),
    ))
}

/// A random version 4 UUID: the stand-in device id when the hardware UUID can't be read.
fn random_uuid() -> Result<String, String> {
    use std::io::Read;
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut source| source.read_exact(&mut bytes))
        .map_err(|e| e.to_string())?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

/// Where the records live. The real ones are two Keychain items; tests use memory.
pub trait Vault: Send + Sync {
    fn load(&self) -> Result<Stored, String>;
    fn save(&self, stored: &Stored) -> Result<(), String>;
    /// `Ok(None)` only when the Keychain positively reports that the item does not exist.
    fn load_trial(&self) -> Result<Option<TrialRecord>, String>;
    fn save_trial(&self, trial: &TrialRecord) -> Result<(), String>;
}

/// The license and trial Keychain items. Never plain preferences.
pub struct Keychain;

/// An item's bytes, or `None` when the Keychain reports it does not exist.
#[cfg(target_os = "macos")]
fn read_keychain_item(service: &str, account: &str) -> Result<Option<Vec<u8>>, String> {
    match security_framework::passwords::get_generic_password(service, account) {
        Ok(bytes) => Ok(Some(bytes)),
        // errSecItemNotFound: nothing saved yet.
        Err(error) if error.code() == -25300 => Ok(None),
        Err(error) => Err(format!("The Keychain could not be read: {error}")),
    }
}

#[cfg(target_os = "macos")]
impl Vault for Keychain {
    fn load(&self) -> Result<Stored, String> {
        match read_keychain_item(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)? {
            Some(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| format!("The saved license could not be read: {e}")),
            None => Ok(Stored::default()),
        }
    }

    fn save(&self, stored: &Stored) -> Result<(), String> {
        let bytes = serde_json::to_vec(stored).map_err(|e| e.to_string())?;
        security_framework::passwords::set_generic_password(
            KEYCHAIN_SERVICE,
            KEYCHAIN_ACCOUNT,
            &bytes,
        )
        .map_err(|error| format!("The license could not be saved to the Keychain: {error}"))
    }

    fn load_trial(&self) -> Result<Option<TrialRecord>, String> {
        match read_keychain_item(TRIAL_KEYCHAIN_SERVICE, TRIAL_KEYCHAIN_ACCOUNT)? {
            Some(bytes) => serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|e| format!("The saved free trial could not be read: {e}")),
            None => Ok(None),
        }
    }

    fn save_trial(&self, trial: &TrialRecord) -> Result<(), String> {
        let bytes = serde_json::to_vec(trial).map_err(|e| e.to_string())?;
        security_framework::passwords::set_generic_password(
            TRIAL_KEYCHAIN_SERVICE,
            TRIAL_KEYCHAIN_ACCOUNT,
            &bytes,
        )
        .map_err(|error| format!("The free trial could not be saved to the Keychain: {error}"))
    }
}

#[cfg(not(target_os = "macos"))]
impl Vault for Keychain {
    fn load(&self) -> Result<Stored, String> {
        Ok(Stored::default())
    }

    fn save(&self, _: &Stored) -> Result<(), String> {
        Err("Licensing is supported on macOS.".into())
    }

    fn load_trial(&self) -> Result<Option<TrialRecord>, String> {
        Ok(None)
    }

    fn save_trial(&self, _: &TrialRecord) -> Result<(), String> {
        Err("Licensing is supported on macOS.".into())
    }
}

/// A small non-secret note, outside the Keychain, that an activation was revoked or removed:
/// keyed by a SHA-256 hash of the activation ID and holding only the record's event sequence
/// after that change, never a clock. Written before the Keychain save and kept as a tombstone
/// until that save lands, so a lost access survives a restart even when the Keychain never
/// caught up. Never contains the license key.
pub trait Journal: Send + Sync {
    /// The sequence noted for the activation, if an entry exists. `Err` means the journal could
    /// not be read: the caller fails closed.
    fn entry(&self, instance_hash: &str) -> Result<Option<u64>, String>;
    /// Notes `seq` for the activation unless a newer note is already there.
    fn revoke(&self, instance_hash: &str, seq: u64) -> Result<(), String>;
    /// Removes the note only if it is not newer than `up_to_seq`, so a clear that was delayed
    /// can never erase a revocation recorded after it.
    fn clear(&self, instance_hash: &str, up_to_seq: u64) -> Result<(), String>;
}

pub fn instance_hash(instance_id: &str) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(instance_id.as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

type JournalEntries = std::collections::BTreeMap<String, u64>;

/// The journal as a JSON object `{ "<hash>": <event_seq> }` in the app's data directory.
/// A missing file is an empty journal; an unreadable or corrupt one is an error, and is moved
/// aside for inspection rather than overwritten once an authoritative answer replaces it.
pub struct FileJournal {
    path: std::path::PathBuf,
    lock: Mutex<()>,
}

impl FileJournal {
    pub fn new(path: std::path::PathBuf) -> Self {
        Self {
            path,
            lock: Mutex::new(()),
        }
    }

    fn read(&self) -> Result<JournalEntries, String> {
        match std::fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| format!("The revocation journal is unreadable: {e}")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(JournalEntries::new()),
            Err(error) => Err(format!("The revocation journal could not be read: {error}")),
        }
    }

    /// The entries to build a write on, and the corrupt bytes to keep aside if the file could
    /// not be read: an authoritative answer rebuilds the journal from what Dodo just said.
    fn read_for_write(&self) -> Result<(JournalEntries, Option<Vec<u8>>), String> {
        match self.read() {
            Ok(entries) => Ok((entries, None)),
            Err(error) => match std::fs::read(&self.path) {
                Ok(corrupt) => Ok((JournalEntries::new(), Some(corrupt))),
                Err(_) => Err(error),
            },
        }
    }

    /// Replaces the journal atomically. A corrupt file is copied aside first and only replaced
    /// by the finished new journal, so there is never a moment without one.
    fn write(&self, entries: &JournalEntries, corrupt: Option<Vec<u8>>) -> Result<(), String> {
        if let Some(directory) = self.path.parent() {
            std::fs::create_dir_all(directory).map_err(|e| e.to_string())?;
        }
        if let Some(corrupt) = corrupt {
            let aside = self
                .path
                .with_extension(format!("corrupt-{}.json", crate::library::unique_suffix()));
            std::fs::write(&aside, corrupt)
                .map_err(|e| format!("The corrupt revocation journal could not be kept: {e}"))?;
        }
        let bytes = serde_json::to_vec(entries).map_err(|e| e.to_string())?;
        crate::library::write_atomic(&self.path, &bytes)
    }
}

impl Journal for FileJournal {
    fn entry(&self, instance_hash: &str) -> Result<Option<u64>, String> {
        let _guard = self.lock.lock().unwrap();
        Ok(self.read()?.get(instance_hash).copied())
    }

    fn revoke(&self, instance_hash: &str, seq: u64) -> Result<(), String> {
        let _guard = self.lock.lock().unwrap();
        let (mut entries, corrupt) = self.read_for_write()?;
        if entries
            .get(instance_hash)
            .is_some_and(|current| *current >= seq)
            && corrupt.is_none()
        {
            return Ok(());
        }
        entries.insert(instance_hash.to_string(), seq);
        self.write(&entries, corrupt)
    }

    fn clear(&self, instance_hash: &str, up_to_seq: u64) -> Result<(), String> {
        let _guard = self.lock.lock().unwrap();
        let (mut entries, corrupt) = self.read_for_write()?;
        let removable = entries
            .get(instance_hash)
            .is_some_and(|current| *current <= up_to_seq);
        if removable {
            entries.remove(instance_hash);
        } else if corrupt.is_none() {
            return Ok(());
        }
        self.write(&entries, corrupt)
    }
}

fn install_crypto_provider() {
    if rustls::crypto::CryptoProvider::get_default().is_none() {
        let _ = rustls::crypto::ring::default_provider().install_default();
    }
}

fn response_header(response: &reqwest::Response, name: &str) -> Option<String> {
    response
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
}

fn http_date(value: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc2822(value)
        .ok()
        .map(|date| date.timestamp())
}

/// A whole HTTP answer: status, the `Date` header, `Retry-After` in seconds, and the body.
struct HttpAnswer {
    status: u16,
    server_time: Option<i64>,
    retry_after: Option<i64>,
    body: Vec<u8>,
}

/// POSTs JSON and reads the whole answer; `Err` means no answer arrived. The request is built
/// and awaited inside the async runtime: the client's timeout needs its reactor, and the
/// licensing threads have none of their own.
fn post_json(
    client: &reqwest::Client,
    url: String,
    body: serde_json::Value,
) -> Result<HttpAnswer, String> {
    tauri::async_runtime::block_on(async move {
        let response = client.post(url).json(&body).send().await.map_err(|error| {
            if error.is_timeout() {
                "timed out".to_string()
            } else {
                "no connection".to_string()
            }
        })?;
        let status = response.status().as_u16();
        let server_time = response_header(&response, "date").and_then(|date| http_date(&date));
        let retry_after = response_header(&response, "retry-after")
            .and_then(|value| retry_after_seconds(&value, server_time));
        let body = response.bytes().await.map_err(|error| error.to_string())?;
        Ok(HttpAnswer {
            status,
            server_time,
            retry_after,
            body: body.to_vec(),
        })
    })
}

/// Dodo's public endpoints over HTTPS. Requests carry only the key and the activation ID.
pub struct HttpDodo {
    client: reqwest::Client,
}

impl HttpDodo {
    fn new() -> Result<Self, String> {
        install_crypto_provider();
        let client = reqwest::Client::builder()
            .https_only(true)
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self { client })
    }

    fn post(
        &self,
        path: &str,
        body: serde_json::Value,
    ) -> Result<(u16, Option<i64>, Option<i64>, serde_json::Value), DodoError> {
        let answer = post_json(&self.client, format!("{HOST}/licenses/{path}"), body)
            .map_err(DodoError::Offline)?;
        let json = serde_json::from_slice(&answer.body).unwrap_or(serde_json::Value::Null);
        Ok((answer.status, answer.server_time, answer.retry_after, json))
    }

    fn error(status: u16, retry_after: Option<i64>) -> DodoError {
        match status {
            429 => DodoError::RateLimited {
                retry_after: retry_after.unwrap_or(60),
            },
            500..=599 => DodoError::ServerError(status),
            _ => DodoError::Unexpected(format!("unexpected response {status}")),
        }
    }
}

impl Dodo for HttpDodo {
    fn activate(&self, license_key: &str, name: &str) -> Result<Activation, DodoError> {
        let (status, server_time, retry_after, json) = self.post(
            "activate",
            serde_json::json!({ "license_key": license_key, "name": name }),
        )?;
        match status {
            200 | 201 => {
                let text = |value: &serde_json::Value| {
                    value.as_str().map(str::to_owned).filter(|s| !s.is_empty())
                };
                let id = text(&json["id"]);
                let product_id = text(&json["product"]["product_id"]);
                let created_at = text(&json["created_at"]).and_then(|value| {
                    chrono::DateTime::parse_from_rfc3339(&value)
                        .ok()
                        .map(|date| date.timestamp())
                });
                match (id, product_id) {
                    (Some(id), Some(product_id)) => Ok(Activation {
                        id,
                        product_id,
                        product_name: text(&json["product"]["name"])
                            .unwrap_or_else(|| "another product".into()),
                        created_at: created_at.or(server_time).unwrap_or_else(system_now),
                        server_time,
                    }),
                    _ => Err(DodoError::Unexpected("activation without an id".into())),
                }
            }
            404 => Err(DodoError::KeyNotFound),
            403 => Err(DodoError::KeyDisabled),
            422 => Err(DodoError::LimitReached),
            other => Err(Self::error(other, retry_after)),
        }
    }

    fn validate(&self, license_key: &str, instance_id: &str) -> Result<Validation, DodoError> {
        let (status, server_time, retry_after, json) = self.post(
            "validate",
            serde_json::json!({ "license_key": license_key, "license_key_instance_id": instance_id }),
        )?;
        match (status, json["valid"].as_bool()) {
            (200, Some(valid)) => Ok(Validation { valid, server_time }),
            (200, None) => Err(DodoError::Unexpected("validation without valid".into())),
            (other, _) => Err(Self::error(other, retry_after)),
        }
    }

    fn deactivate(&self, license_key: &str, instance_id: &str) -> Result<(), DodoError> {
        let (status, _, retry_after, _) = self.post(
            "deactivate",
            serde_json::json!({ "license_key": license_key, "license_key_instance_id": instance_id }),
        )?;
        match status {
            200..=299 => Ok(()),
            404 => Err(DodoError::KeyNotFound),
            403 => Err(DodoError::KeyDisabled),
            other => Err(Self::error(other, retry_after)),
        }
    }
}

/// The trial registry, over HTTPS (plain HTTP only for a local development registry, which the
/// build configuration allows only in test builds). Requests carry only the app id, the device
/// hash and the environment.
pub struct HttpRegistry {
    client: reqwest::Client,
}

impl HttpRegistry {
    fn new() -> Result<Self, String> {
        install_crypto_provider();
        let client = reqwest::Client::builder()
            .https_only(REGISTRY_URL.starts_with("https://"))
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self { client })
    }
}

/// `200 {"started_at": "<ISO 8601>", "now": "<ISO 8601>"}`.
fn parse_registry_answer(body: &[u8]) -> Option<RegistryAnswer> {
    let json: serde_json::Value = serde_json::from_slice(body).ok()?;
    let time = |name: &str| {
        json[name]
            .as_str()
            .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
            .map(|date| date.timestamp())
    };
    Some(RegistryAnswer {
        started_at: time("started_at")?,
        now: time("now")?,
    })
}

impl Registry for HttpRegistry {
    fn register(&self, device: &str) -> Result<RegistryAnswer, RegistryError> {
        let HttpAnswer {
            status,
            retry_after,
            body,
            ..
        } = post_json(
            &self.client,
            format!("{REGISTRY_URL}/api/trial"),
            serde_json::json!({ "app": APP_ID, "device": device, "env": ENVIRONMENT }),
        )
        .map_err(RegistryError::Offline)?;
        match status {
            200 => parse_registry_answer(&body)
                .ok_or_else(|| RegistryError::Unexpected("an answer without its times".into())),
            429 => Err(RegistryError::RateLimited {
                retry_after: retry_after.unwrap_or(60),
            }),
            other => Err(RegistryError::Unexpected(format!(
                "unexpected response {other}"
            ))),
        }
    }
}

/// The app around the service: the settings window, the audio engine, the network and the Mac.
pub trait Host: Send + Sync {
    fn publish(&self, view: &View);
    /// Gate keyboard sound playback, with the reason the menu bar shows while it is blocked.
    /// Decisions carry a revision issued under the engine lock; the host must apply a decision
    /// only if its revision is newer than the last one applied, atomically with applying it.
    /// Everything else in the app keeps working.
    fn set_blocked(&self, revision: u64, blocked: bool, reason: &'static str);
    /// A cheap connectivity probe of Dodo, used only after network-level failures.
    fn reachable(&self) -> bool;
    /// The same probe for the trial registry.
    fn registry_reachable(&self) -> bool;
    /// The Mac's hardware UUID, which never leaves the Mac; `None` if it can't be read.
    fn hardware_uuid(&self) -> Option<String>;
}

pub struct TauriHost {
    app: tauri::AppHandle,
}

/// A TCP handshake with a service's host: no request is made, and a failure costs seconds.
fn tcp_reachable(origin: &str) -> bool {
    let Ok(url) = url::Url::parse(origin) else {
        return false;
    };
    let (Some(host), Some(port)) = (url.host_str(), url.port_or_known_default()) else {
        return false;
    };
    std::net::ToSocketAddrs::to_socket_addrs(&(host, port))
        .ok()
        .and_then(|mut addresses| addresses.next())
        .is_some_and(|address| {
            std::net::TcpStream::connect_timeout(&address, Duration::from_secs(3)).is_ok()
        })
}

#[cfg(target_os = "macos")]
fn platform_uuid() -> Option<String> {
    unsafe extern "C" {
        fn ok_platform_uuid(buffer: *mut std::ffi::c_char, length: i32) -> i32;
    }
    let mut buffer = [0 as std::ffi::c_char; 128];
    if unsafe { ok_platform_uuid(buffer.as_mut_ptr(), buffer.len() as i32) } == 0 {
        return None;
    }
    let uuid = unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) }
        .to_str()
        .ok()?
        .trim();
    (!uuid.is_empty()).then(|| uuid.to_string())
}

#[cfg(not(target_os = "macos"))]
fn platform_uuid() -> Option<String> {
    None
}

impl Host for TauriHost {
    fn publish(&self, view: &View) {
        let _ = self.app.emit("license", view);
    }

    fn set_blocked(&self, revision: u64, blocked: bool, reason: &'static str) {
        if let Some(controller) = self.app.try_state::<Arc<Controller>>() {
            controller.set_license_blocked(revision, blocked, reason);
        }
    }

    fn reachable(&self) -> bool {
        tcp_reachable(HOST)
    }

    fn registry_reachable(&self) -> bool {
        tcp_reachable(REGISTRY_URL)
    }

    fn hardware_uuid(&self) -> Option<String> {
        platform_uuid()
    }
}

/// What the settings window shows. Mirrors the state table in LICENSING.md, and the same gate
/// that decides playback.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    pub revision: u64,
    /// False until the license record has been read; the window shows a loading state.
    pub ready: bool,
    pub environment: &'static str,
    /// What playback is actually allowed: when the records in memory would grant access that
    /// isn't saved yet, the saved records' state.
    #[serde(flatten)]
    pub state: State,
    /// Whether keyboard sounds play right now.
    pub core_feature: bool,
    /// The clock was set back: a paid license needs a check.
    pub clock_changed: bool,
    /// License data on disk could not be read; a check with Dodo rebuilds it.
    pub journal_unreadable: bool,
    /// The trial record could not be read, or a new trial could not be saved: no trial runs.
    pub trial_storage_error: bool,
    pub grace_warning: bool,
    pub checking: bool,
    pub last_success_at: Option<i64>,
    pub last_error: Option<String>,
    pub pending_key: Option<String>,
    pub buy_url: &'static str,
    pub support_url: &'static str,
}

#[derive(Default)]
struct Meta {
    revision: u64,
    ready: bool,
    checking: bool,
    last_error: Option<String>,
    pending_key: Option<String>,
    last_reachability_poll: Option<i64>,
    /// A recovery check may run once after the network was seen down.
    recovery_armed: bool,
    /// A Keychain write failed; the record is written again every tick until it succeeds.
    storage_dirty: bool,
    last_cleanup_at: Option<i64>,
    /// The Keychain could not be read: not "no license". Retried with backoff.
    load_failures: u32,
    next_load_at: Option<i64>,
    /// Journal writes that failed, one per activation (a newer op supersedes an older one);
    /// retried every tick while the memory state stays locked.
    journal_retry: std::collections::BTreeMap<String, JournalOp>,
    /// Tombstones to clear once the current record has been saved, with the sequence they hold.
    clear_after_save: Vec<(String, u64)>,
    /// The journal could not be read: the saved record is held, playback stays off, and the
    /// next authoritative answer rebuilds the journal.
    journal_unreadable: bool,
    /// The trial record could not be read, or a provisional one could not be saved: not "no
    /// trial yet". Retried with backoff.
    trial_failures: u32,
    next_trial_attempt_at: Option<i64>,
    /// A trial write failed; the record is written again every tick until it succeeds.
    trial_dirty: bool,
    /// Ask the registry on the next tick whatever the backoff: after wake or Try again.
    register_now: bool,
    last_registry_poll: Option<i64>,
    /// A registration may run once after the registry was seen unreachable.
    registry_recovery_armed: bool,
}

impl Meta {
    /// Storage errors stay visible until storage works again.
    fn storage_trouble(&self) -> bool {
        self.storage_dirty || self.journal_unreadable || self.trial_failures > 0 || self.trial_dirty
    }

    /// The trial record could not be read or a new trial not saved: retry with backoff.
    fn trial_failed(&mut self, now: i64, error: String) {
        self.trial_failures += 1;
        let backoff = LOAD_RETRY_MIN
            .saturating_mul(1 << self.trial_failures.saturating_sub(1).min(20))
            .min(LOAD_RETRY_MAX);
        self.next_trial_attempt_at = Some(now + backoff);
        if !self.journal_unreadable {
            self.last_error = Some(error);
        }
    }

    fn trial_recovered(&mut self) {
        let failed = std::mem::take(&mut self.trial_failures) > 0;
        self.next_trial_attempt_at = None;
        if failed && !self.storage_trouble() {
            self.last_error = None;
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum JournalOp {
    Revoke(u64),
    Clear(u64),
}

impl JournalOp {
    fn seq(self) -> u64 {
        match self {
            JournalOp::Revoke(seq) | JournalOp::Clear(seq) => seq,
        }
    }
}

pub type Clock = Box<dyn Fn() -> i64 + Send + Sync>;

pub struct Service<D: Dodo + Send + Sync, R: Registry + Send + Sync, V: Vault, H: Host, J: Journal>
{
    /// Held for pure steps only: never across the network or the Keychain.
    engine: Mutex<Engine>,
    meta: Mutex<Meta>,
    /// Orders every license Keychain write, and the activation and removal sequences around
    /// theirs.
    mutate: Mutex<()>,
    /// Orders every trial Keychain write. Never held across the network; when both are needed,
    /// taken after `mutate`.
    trial_mutate: Mutex<()>,
    /// One validation in flight at a time, from the scheduler or the window.
    check: Mutex<()>,
    /// One registry request in flight at a time.
    registering: Mutex<()>,
    /// Issued under the engine lock with each gate decision; the host applies only newer ones.
    gate_revision: AtomicU64,
    /// The license record as last saved or loaded. Playback unlocks only if the saved records
    /// grant access too, so an unsaved extension never unlocks by itself while a durable grant
    /// keeps working.
    durable: Mutex<Option<Stored>>,
    /// The trial record as last saved or read.
    durable_trial: Mutex<TrialSlot>,
    /// Bumped by every change to the records in memory or on disk; a load result older than the
    /// latest change is discarded.
    generation: AtomicU64,
    /// One Keychain read at a time, automatic or manual.
    load: Mutex<()>,
    wake: (Mutex<bool>, Condvar),
    /// The deadline enforcer's own wake-up, so a stalled write never delays a restriction.
    deadline_wake: (Mutex<bool>, Condvar),
    dodo: D,
    registry: R,
    vault: V,
    host: H,
    journal: J,
    /// The wall clock, in Unix seconds.
    clock: Clock,
    /// A monotonic clock in seconds that keeps counting through sleep.
    monotonic: Clock,
}

pub type Live = Service<HttpDodo, HttpRegistry, Keychain, TauriHost, FileJournal>;

impl Live {
    /// Registers the service, gates playback until the records are known, and starts the thread
    /// that reads the Keychain. Launch is never delayed.
    pub fn start(app: &tauri::AppHandle) -> Result<(), String> {
        let journal = FileJournal::new(
            app.path()
                .app_data_dir()
                .map_err(|e| e.to_string())?
                .join(JOURNAL_FILE),
        );
        let service = Arc::new(Service::new(
            HttpDodo::new()?,
            HttpRegistry::new()?,
            Keychain,
            TauriHost { app: app.clone() },
            journal,
            Box::new(system_now),
            Box::new(monotonic_now),
        ));
        #[cfg(debug_assertions)]
        if let Some(terms) = debug_trial_terms() {
            service.engine.lock().unwrap().terms = terms;
        }
        app.manage(service.clone());
        service.apply();
        let scheduler = service.clone();
        std::thread::Builder::new()
            .name("openklack-license".into())
            .spawn(move || scheduler.run())
            .map_err(|e| e.to_string())?;
        std::thread::Builder::new()
            .name("openklack-license-deadlines".into())
            .spawn(move || service.run_deadlines())
            .map_err(|e| e.to_string())?;
        Ok(())
    }
}

impl<D, R, V, H, J> Service<D, R, V, H, J>
where
    D: Dodo + Send + Sync + 'static,
    R: Registry + Send + Sync + 'static,
    V: Vault + 'static,
    H: Host + 'static,
    J: Journal + 'static,
{
    /// Saves the trial record on quit from a helper thread and waits at most `timeout` for it,
    /// so a stuck Keychain never holds up quitting. Returns whether the save finished in time.
    pub fn flush_within(self: Arc<Self>, timeout: Duration) -> bool {
        let (done, finished) = mpsc::channel();
        let spawned = std::thread::Builder::new()
            .name("openklack-license-quit".into())
            .spawn(move || {
                self.flush();
                let _ = done.send(());
            });
        spawned.is_ok() && finished.recv_timeout(timeout).is_ok()
    }
}

impl<D: Dodo + Send + Sync, R: Registry + Send + Sync, V: Vault, H: Host, J: Journal>
    Service<D, R, V, H, J>
{
    pub fn new(
        dodo: D,
        registry: R,
        vault: V,
        host: H,
        journal: J,
        clock: Clock,
        monotonic: Clock,
    ) -> Self {
        let mut engine = Engine::new(Stored::default(), products());
        engine.trial = TrialSlot::Unread;
        Self {
            engine: Mutex::new(engine),
            meta: Mutex::new(Meta::default()),
            mutate: Mutex::new(()),
            trial_mutate: Mutex::new(()),
            check: Mutex::new(()),
            registering: Mutex::new(()),
            gate_revision: AtomicU64::new(0),
            durable: Mutex::new(None),
            durable_trial: Mutex::new(TrialSlot::Unread),
            generation: AtomicU64::new(0),
            load: Mutex::new(()),
            wake: (Mutex::new(false), Condvar::new()),
            deadline_wake: (Mutex::new(false), Condvar::new()),
            dodo,
            registry,
            vault,
            host,
            journal,
            clock,
            monotonic,
        }
    }

    /// The deadline enforcer: only ever reads the engine and the saved records, and publishes
    /// restrictions the moment a trial ends, grace runs out or the clock is found to have
    /// changed. It never touches the ordering locks, the Keychain, the network or cleanup, so a
    /// stalled write cannot delay it.
    pub fn run_deadlines(&self) {
        loop {
            self.enforce();
            let now = self.now();
            let next = {
                let engine = self.engine.lock().unwrap();
                // The saved trial record gates too: an unsaved registration still stops at the
                // saved record's offline limit.
                let durable = match (engine.license(), &*self.durable_trial.lock().unwrap()) {
                    (None, TrialSlot::Present(saved)) => engine.trial_transition_at(saved, now),
                    _ => None,
                };
                [engine.next_transition_at(now), durable]
                    .into_iter()
                    .flatten()
                    .min()
            };
            // A pending deadline is rechecked every minute, so a wall clock moved during the
            // wait is noticed on time.
            let wait = next
                .map(|at| Duration::from_secs((at - now.wall).max(0) as u64).min(DEADLINE_RECHECK))
                .unwrap_or(MAX_SLEEP)
                .clamp(Duration::from_secs(1), MAX_SLEEP);
            let (flag, condvar) = &self.deadline_wake;
            let mut woken = flag.lock().unwrap();
            if !*woken {
                woken = condvar.wait_timeout(woken, wait).unwrap().0;
            }
            *woken = false;
        }
    }

    /// One pass of the deadline enforcer.
    pub fn enforce(&self) {
        self.gate(false);
    }

    /// Notes a lost access in the journal. A failure keeps the memory state locked, shows a
    /// storage error and is retried every tick.
    fn journal_revoke(&self, hash: String, seq: u64) {
        let result = self.journal.revoke(&hash, seq);
        self.journal_done(hash, JournalOp::Revoke(seq), result, "saved");
    }

    fn journal_clear(&self, hash: String, up_to_seq: u64) {
        let result = self.journal.clear(&hash, up_to_seq);
        self.journal_done(hash, JournalOp::Clear(up_to_seq), result, "updated");
    }

    fn journal_done(&self, hash: String, op: JournalOp, result: Result<(), String>, verb: &str) {
        match result {
            Ok(()) => {
                let mut meta = self.meta.lock().unwrap();
                meta.journal_unreadable = false;
                // A queued op this one supersedes is no longer needed.
                if meta
                    .journal_retry
                    .get(&hash)
                    .is_some_and(|queued| queued.seq() <= op.seq())
                {
                    meta.journal_retry.remove(&hash);
                }
            }
            Err(error) => {
                self.publish(|meta| {
                    Self::queue_journal_op(meta, hash, op);
                    meta.last_error =
                        Some(format!("The revocation note could not be {verb}: {error}"));
                });
            }
        }
    }

    /// Queues an op for retry unless a newer one for the same activation is already queued.
    fn queue_journal_op(meta: &mut Meta, hash: String, op: JournalOp) {
        let newer_queued = meta
            .journal_retry
            .get(&hash)
            .is_some_and(|queued| queued.seq() > op.seq());
        if !newer_queued {
            meta.journal_retry.insert(hash, op);
        }
    }

    fn retry_journal(&self) {
        let pending = std::mem::take(&mut self.meta.lock().unwrap().journal_retry);
        if pending.is_empty() {
            return;
        }
        let mut failed = std::collections::BTreeMap::new();
        for (hash, op) in pending {
            let result = match op {
                JournalOp::Revoke(seq) => self.journal.revoke(&hash, seq),
                JournalOp::Clear(up_to) => self.journal.clear(&hash, up_to),
            };
            match result {
                Ok(()) => self.meta.lock().unwrap().journal_unreadable = false,
                Err(_) => {
                    failed.insert(hash, op);
                }
            }
        }
        let done = failed.is_empty();
        {
            let mut meta = self.meta.lock().unwrap();
            // Ops queued meanwhile win over the ones that failed again.
            for (hash, op) in failed {
                Self::queue_journal_op(&mut meta, hash, op);
            }
        }
        if done {
            self.publish(|meta| {
                if !meta.storage_trouble() {
                    meta.last_error = None;
                }
            });
        }
    }

    pub fn poke_deadlines(&self) {
        let (flag, condvar) = &self.deadline_wake;
        *flag.lock().unwrap() = true;
        condvar.notify_all();
    }

    fn now(&self) -> Moment {
        Moment {
            wall: (self.clock)(),
            mono: (self.monotonic)(),
        }
    }

    /// Reads the records, runs the launch check and registration, then keeps the schedule.
    fn run(&self) {
        self.load();
        loop {
            self.tick();
            self.sleep();
        }
    }

    /// Reads the Keychain and the journal. Unreadable storage is a storage error, never "no
    /// license" or "no trial yet": the Mac stays gated, the error is shown, and the read is
    /// retried with backoff. Loads are single-flight, and a result is discarded if the records
    /// changed meanwhile. With no license and no trial record, the trial starts here.
    pub fn load(&self) {
        let Ok(loading) = self.load.try_lock() else {
            return;
        };
        let started = self.generation.load(Ordering::SeqCst);
        let now = self.now();
        // A journal entry newer than the durable record forces Revoked; an older one is stale.
        // An unreadable journal keeps the record as a recovery candidate: playback stays off
        // until Dodo answers for it and the journal is rebuilt.
        let loaded = self.vault.load().map(|stored| {
            let (journal_seq, stale, journal_error) = match &stored.license {
                Some(record) => match self.journal.entry(&instance_hash(&record.instance_id)) {
                    Ok(Some(seq)) if seq > record.event_seq => (Some(seq), false, None),
                    Ok(Some(_)) => (None, true, None),
                    Ok(None) => (None, false, None),
                    Err(error) => (None, false, Some(error)),
                },
                None => (None, false, None),
            };
            (stored, journal_seq, stale, journal_error)
        });
        let (stored, journal_seq, stale, journal_error) = match loaded {
            Ok(loaded) => loaded,
            Err(error) => {
                self.publish(|meta| {
                    meta.load_failures += 1;
                    let backoff = LOAD_RETRY_MIN
                        .saturating_mul(1 << meta.load_failures.saturating_sub(1).min(20))
                        .min(LOAD_RETRY_MAX);
                    meta.next_load_at = Some(now.wall + backoff);
                    meta.last_error = Some(error);
                });
                return;
            }
        };
        // An unreadable trial record does not hold up a license: it only keeps a trial from
        // running, and is read again with backoff.
        let trial = self.vault.load_trial();
        let stale_entry = stale
            .then(|| {
                stored
                    .license
                    .as_ref()
                    .map(|record| (instance_hash(&record.instance_id), record.event_seq))
            })
            .flatten();
        {
            let ordered = self.mutate.lock().unwrap();
            let trial_ordered = self.trial_mutate.lock().unwrap();
            if self.generation.load(Ordering::SeqCst) != started {
                // Something changed the records while this read was in flight: it is old news.
                return;
            }
            let slot = match &trial {
                Ok(Some(record)) => TrialSlot::Present(record.clone()),
                Ok(None) => TrialSlot::Absent,
                Err(_) => TrialSlot::Unread,
            };
            let mut engine = self.engine.lock().unwrap();
            engine.stored = stored.clone();
            engine.trial = slot.clone();
            if let Some(seq) = journal_seq
                && let Some(record) = engine.stored.license.as_mut()
            {
                // The record catches up with the event the journal remembers.
                record.revoked = true;
                record.event_seq = seq;
            }
            // Launch: elapsed time follows the monotonic clock from here, unless the clock is
            // behind the trial.
            engine.anchor_trial(now);
            engine.check_clock(now);
            drop(engine);
            *self.durable.lock().unwrap() = Some(stored);
            *self.durable_trial.lock().unwrap() = slot;
            self.generation.fetch_add(1, Ordering::SeqCst);
            let mut meta = self.meta.lock().unwrap();
            meta.ready = true;
            meta.load_failures = 0;
            meta.next_load_at = None;
            meta.journal_unreadable = journal_error.is_some();
            meta.last_error = journal_error;
            meta.storage_dirty = journal_seq.is_some();
            match trial {
                Ok(_) => meta.trial_recovered(),
                Err(error) => meta.trial_failed(now.wall, error),
            }
            drop(meta);
            drop(trial_ordered);
            drop(ordered);
        }
        if let Some((hash, seq)) = stale_entry {
            self.journal_clear(hash, seq);
        }
        self.ensure_trial(true);
        self.publish(|_| {});
        self.apply();
        // Reading is done: a manual retry must not wait for the requests below.
        drop(loading);
        // The contract's launch check and registration: in the background, whatever the last
        // success time or backoff.
        let _ = self.check_once(true);
        self.register_once(true);
    }

    /// Starts the trial when there is no license and the trial record is positively absent. The
    /// provisional record is saved first and only then takes effect; a failed save is a storage
    /// error retried with backoff, and no unsaved trial ever runs.
    fn ensure_trial(&self, forced: bool) {
        let ordered = self.mutate.lock().unwrap();
        self.ensure_trial_ordered(&ordered, forced);
    }

    /// `ensure_trial` for a caller that already holds the license ordering lock, which keeps an
    /// activation from landing between the "no license" check and the trial's save.
    fn ensure_trial_ordered(&self, _license_ordered: &MutexGuard<'_, ()>, forced: bool) {
        let _ordered = self.trial_mutate.lock().unwrap();
        let now = self.now();
        {
            let meta = self.meta.lock().unwrap();
            if !meta.ready
                || (!forced && meta.next_trial_attempt_at.is_some_and(|at| at > now.wall))
            {
                return;
            }
        }
        let provisional = self.engine.lock().unwrap().provisional_trial(now);
        let Some(mut trial) = provisional else {
            return;
        };
        if self.host.hardware_uuid().is_none() {
            // Saved with the record, so every later request hashes the same stand-in.
            trial.device_id = random_uuid().ok();
        }
        self.generation.fetch_add(1, Ordering::SeqCst);
        match self.vault.save_trial(&trial) {
            Ok(()) => {
                // Only holders of the trial ordering lock change the trial slot, so it is still
                // absent.
                self.engine
                    .lock()
                    .unwrap()
                    .commit_trial(trial.clone(), self.now());
                *self.durable_trial.lock().unwrap() = TrialSlot::Present(trial);
                self.generation.fetch_add(1, Ordering::SeqCst);
                self.publish(Meta::trial_recovered);
            }
            Err(error) => {
                self.publish(|meta| {
                    meta.trial_failed(
                        now.wall,
                        format!("Your free trial could not be started. {error}"),
                    )
                });
            }
        }
    }

    /// Reads the trial record again after a failed read.
    fn reload_trial(&self) {
        let Ok(_loading) = self.load.try_lock() else {
            return;
        };
        let now = self.now();
        let trial = self.vault.load_trial();
        let _ordered = self.trial_mutate.lock().unwrap();
        // Nothing writes the trial record while it is unread, so this read is current unless
        // another read already landed.
        if self.engine.lock().unwrap().trial != TrialSlot::Unread {
            return;
        }
        match trial {
            Ok(record) => {
                let slot = record.map_or(TrialSlot::Absent, TrialSlot::Present);
                {
                    let mut engine = self.engine.lock().unwrap();
                    engine.trial = slot.clone();
                    engine.anchor_trial(now);
                    engine.check_clock(now);
                }
                *self.durable_trial.lock().unwrap() = slot;
                self.generation.fetch_add(1, Ordering::SeqCst);
                self.publish(Meta::trial_recovered);
            }
            Err(error) => {
                self.publish(|meta| meta.trial_failed(now.wall, error));
            }
        }
    }

    /// Settings → License → Try again: re-reads an unreadable trial record, starts a trial that
    /// could not be saved, and writes a trial record whose save failed, without waiting for the
    /// backoff.
    fn retry_trial(&self) {
        if self.engine.lock().unwrap().trial == TrialSlot::Unread {
            self.reload_trial();
        }
        self.ensure_trial(true);
        if self.trial_save_due() {
            let ordered = self.trial_mutate.lock().unwrap();
            self.persist_trial(&ordered);
        }
    }

    /// Writes the trial record. Requires the trial ordering lock, so writes land in the order the
    /// changes were made and a slower writer can never restore an older record. A failure is
    /// retried every tick and never blocks the core feature or the trial deadline.
    fn persist_trial(&self, _ordered: &MutexGuard<'_, ()>) -> bool {
        let (slot, frozen) = {
            let engine = self.engine.lock().unwrap();
            (engine.trial.clone(), engine.trial_frozen(self.now()))
        };
        if frozen {
            // Nothing about the trial is saved while the clock is behind.
            return false;
        }
        let TrialSlot::Present(trial) = slot else {
            return true;
        };
        self.generation.fetch_add(1, Ordering::SeqCst);
        match self.vault.save_trial(&trial) {
            Ok(()) => {
                *self.durable_trial.lock().unwrap() = TrialSlot::Present(trial);
                let was_dirty = std::mem::take(&mut self.meta.lock().unwrap().trial_dirty);
                if was_dirty {
                    self.publish(|meta| {
                        if !meta.storage_trouble() {
                            meta.last_error = None;
                        }
                    });
                }
                true
            }
            Err(error) => {
                self.publish(|meta| {
                    meta.trial_dirty = true;
                    meta.last_error = Some(format!("Your free trial could not be saved. {error}"));
                });
                false
            }
        }
    }

    /// Whether the trial record in memory should be written now: a failed write, a change other
    /// than `last_seen_at`, the trial's end, or `last_seen_at` an hour past the saved one.
    fn trial_save_due(&self) -> bool {
        let dirty = self.meta.lock().unwrap().trial_dirty;
        let engine = self.engine.lock().unwrap();
        if engine.trial_frozen(self.now()) {
            return false;
        }
        if dirty {
            return true;
        }
        let TrialSlot::Present(trial) = &engine.trial else {
            return false;
        };
        let durable = self.durable_trial.lock().unwrap();
        let TrialSlot::Present(saved) = &*durable else {
            return true;
        };
        let ended = |record: &TrialRecord| {
            Engine::trial_state(record, &engine.terms, record.last_seen_at) == State::TrialEnded
        };
        trial.started_at != saved.started_at
            || trial.registered != saved.registered
            || trial.device_id != saved.device_id
            || trial.last_seen_at - saved.last_seen_at >= TRIAL_SAVE_INTERVAL
            || (ended(trial) && !ended(saved))
    }

    /// On quit: raises `last_seen_at` once more and saves the trial record if it changed. Called
    /// through `flush_within`, which bounds the whole save.
    pub fn flush(&self) {
        let now = self.now();
        self.engine.lock().unwrap().observe(now);
        let ordered = self.trial_mutate.lock().unwrap();
        let changed = {
            let engine = self.engine.lock().unwrap();
            matches!(&engine.trial, TrialSlot::Present(_))
                && engine.trial != *self.durable_trial.lock().unwrap()
        };
        if changed {
            self.persist_trial(&ordered);
        }
    }

    /// The device hash sent to the registry: from the hardware UUID, or from a random stand-in
    /// that is saved in the trial record before any request uses it.
    fn device(&self) -> Option<String> {
        if let Some(uuid) = self.host.hardware_uuid() {
            return Some(device_hash(APP_ID, &uuid));
        }
        let ordered = self.trial_mutate.lock().unwrap();
        let saved = |slot: &TrialSlot| match slot {
            TrialSlot::Present(trial) => trial.device_id.clone(),
            _ => None,
        };
        let durable = saved(&self.durable_trial.lock().unwrap());
        if let Some(id) = durable {
            return Some(device_hash(APP_ID, &id));
        }
        let id = random_uuid().ok()?;
        {
            let mut engine = self.engine.lock().unwrap();
            let TrialSlot::Present(trial) = &mut engine.trial else {
                return None;
            };
            trial.device_id.get_or_insert(id);
        }
        if !self.persist_trial(&ordered) {
            return None;
        }
        let durable = saved(&self.durable_trial.lock().unwrap());
        durable.map(|id| device_hash(APP_ID, &id))
    }

    /// Asks the trial registry once, if an unregistered trial wants it. The request holds no
    /// lock. The answer's earlier start restricts at once; `registered` unlocks only once saved.
    pub fn register_once(&self, forced: bool) {
        let Ok(_running) = self.registering.try_lock() else {
            return;
        };
        let now = self.now();
        if !self.engine.lock().unwrap().begin_registration(now, forced) {
            return;
        }
        let Some(device) = self.device() else {
            // No device id could be saved: back off and try again.
            let failed = Err(RegistryError::Unexpected("no device id".into()));
            let _ = self.engine.lock().unwrap().finish_registration(failed, now);
            return;
        };
        let answer = self.registry.register(&device);
        let (changed, network_down) = {
            let mut engine = self.engine.lock().unwrap();
            let changed = engine.finish_registration(answer, self.now());
            (
                matches!(changed, Ok(true)),
                engine.registration.network_down,
            )
        };
        self.generation.fetch_add(1, Ordering::SeqCst);
        self.gate(false);
        if network_down {
            self.meta.lock().unwrap().registry_recovery_armed = true;
        }
        if changed {
            let ordered = self.trial_mutate.lock().unwrap();
            self.persist_trial(&ordered);
        }
        self.apply();
    }

    /// One pass of the scheduler. Deadlines are enforced first and without waiting on any
    /// write; then retries of unreadable storage, observations, due or recovered checks and
    /// registrations, stale slots, and the permissive re-evaluation.
    pub fn tick(&self) {
        self.gate(false);
        let now = self.now();
        let reload = {
            let meta = self.meta.lock().unwrap();
            !meta.ready && meta.next_load_at.is_none_or(|at| at <= now.wall)
        };
        if reload {
            self.load();
        }
        if !self.meta.lock().unwrap().ready {
            return;
        }
        let retry_trial = self
            .meta
            .lock()
            .unwrap()
            .next_trial_attempt_at
            .is_none_or(|at| at <= now.wall);
        if retry_trial {
            if self.engine.lock().unwrap().trial == TrialSlot::Unread {
                self.reload_trial();
            }
            self.ensure_trial(false);
        }
        // The high-water marks: a rolled-back clock is not trusted and gives no trial time back.
        let observed = self.engine.lock().unwrap().observe(now);
        if observed.license {
            self.generation.fetch_add(1, Ordering::SeqCst);
            let ordered = self.mutate.lock().unwrap();
            self.persist(&ordered);
        }
        if self.trial_save_due() {
            let ordered = self.trial_mutate.lock().unwrap();
            self.persist_trial(&ordered);
        }
        let (due, network_down) = {
            let engine = self.engine.lock().unwrap();
            (engine.check_due(now), engine.schedule.network_down)
        };
        if due {
            let _ = self.check_once(false);
        } else if network_down && self.network_recovered(now.wall, false) {
            let _ = self.check_once(true);
        }
        let register_now = std::mem::take(&mut self.meta.lock().unwrap().register_now);
        let (registration_due, registry_down) = {
            let engine = self.engine.lock().unwrap();
            (
                engine
                    .next_registration_at(now)
                    .is_some_and(|due| due <= now.wall),
                engine.registration.network_down,
            )
        };
        if registration_due || register_now {
            self.register_once(register_now);
        } else if registry_down && self.network_recovered(now.wall, true) {
            self.register_once(true);
        }
        self.release_cleanups(now.wall);
        if self.meta.lock().unwrap().storage_dirty {
            let ordered = self.mutate.lock().unwrap();
            self.persist(&ordered);
        }
        self.retry_journal();
        self.apply();
    }

    /// After a network-level failure, a cheap probe every few minutes notices the network
    /// coming back and allows one attempt ahead of the backoff. It re-arms only after the probe
    /// has seen the network down, so a reachable host that keeps failing stays on the backoff.
    /// `registry` selects the trial registry's probe instead of Dodo's.
    fn network_recovered(&self, now: i64, registry: bool) -> bool {
        let due = {
            let mut meta = self.meta.lock().unwrap();
            let last = if registry {
                &mut meta.last_registry_poll
            } else {
                &mut meta.last_reachability_poll
            };
            let due = last.is_none_or(|last| now - last >= REACHABILITY_POLL.as_secs() as i64);
            if due {
                *last = Some(now);
            }
            due
        };
        if !due {
            return false;
        }
        let reachable = if registry {
            self.host.registry_reachable()
        } else {
            self.host.reachable()
        };
        let mut meta = self.meta.lock().unwrap();
        let armed = if registry {
            &mut meta.registry_recovery_armed
        } else {
            &mut meta.recovery_armed
        };
        if !reachable {
            *armed = true;
            return false;
        }
        std::mem::take(armed)
    }

    fn sleep(&self) {
        let wait = self.next_wait();
        let (flag, condvar) = &self.wake;
        let mut woken = flag.lock().unwrap();
        if !*woken {
            woken = condvar.wait_timeout(woken, wait).unwrap().0;
        }
        *woken = false;
    }

    /// How long the scheduler may sleep before something is due.
    fn next_wait(&self) -> Duration {
        let now = self.now();
        let (next_check, next_transition, next_registration, probing, clock_behind) = {
            let engine = self.engine.lock().unwrap();
            (
                engine.next_check_at(now),
                engine.next_transition_at(now),
                engine.next_registration_at(now),
                engine.schedule.network_down
                    || engine.registration.network_down
                    || !engine.stored.pending_cleanups.is_empty(),
                engine.clock_behind,
            )
        };
        let mut wait = [next_check, next_transition, next_registration]
            .into_iter()
            .flatten()
            .map(|due| Duration::from_secs((due - now.wall).max(0) as u64))
            .min()
            .unwrap_or(MAX_SLEEP);
        if clock_behind {
            // Sound comes back soon after the clock is corrected.
            wait = wait.min(DEADLINE_RECHECK);
        }
        {
            let meta = self.meta.lock().unwrap();
            if probing || meta.storage_dirty || meta.trial_dirty || !meta.journal_retry.is_empty() {
                wait = wait.min(REACHABILITY_POLL.min(CLEANUP_RETRY));
            }
            if let Some(at) = meta.next_load_at.filter(|_| !meta.ready) {
                wait = wait.min(Duration::from_secs((at - now.wall).max(0) as u64));
            }
            if let Some(at) = meta.next_trial_attempt_at {
                wait = wait.min(Duration::from_secs((at - now.wall).max(0) as u64));
            }
        }
        wait.clamp(Duration::from_secs(1), MAX_SLEEP)
    }

    /// Wakes the scheduler: after activation, on wake from sleep, or when asked to check now.
    pub fn poke(&self) {
        let (flag, condvar) = &self.wake;
        *flag.lock().unwrap() = true;
        condvar.notify_all();
    }

    /// The Mac woke from sleep: `last_seen_at` rises by the time slept, a clock found behind the
    /// trial holds it, deadlines are re-evaluated, and an unregistered trial asks the registry
    /// again whatever the backoff.
    pub fn woke(&self) {
        {
            let now = self.now();
            let mut engine = self.engine.lock().unwrap();
            engine.observe(now);
            engine.check_clock(now);
        }
        // The restriction is published before any I/O.
        self.gate(false);
        self.meta.lock().unwrap().register_now = true;
        self.poke_deadlines();
        self.poke();
    }

    /// Runs one validation. The network call holds no lock; the answer is applied to the
    /// activation it was asked about, a restriction is published before the save, and the
    /// permissive re-evaluation waits for it.
    pub fn check_once(&self, forced: bool) -> Result<State, LicenseError> {
        let Ok(_running) = self.check.try_lock() else {
            return Ok(self.state());
        };
        let now = self.now();
        let begun = self.engine.lock().unwrap().begin_check(now, forced);
        let probe = match begun {
            Ok(Some(probe)) => probe,
            Ok(None) => return Ok(self.state()),
            Err(error) => return Err(error),
        };
        self.publish(|meta| meta.checking = true);
        let answer = self.dodo.validate(&probe.license_key, &probe.instance_id);
        let (result, network_down, answered) = {
            let mut engine = self.engine.lock().unwrap();
            let result = engine.finish_check(&probe, answer, self.now());
            let answered = engine
                .stored
                .license
                .as_ref()
                .filter(|record| record.instance_id == probe.instance_id)
                .map(|record| (record.revoked, record.event_seq));
            (result, engine.schedule.network_down, answered)
        };
        self.generation.fetch_add(1, Ordering::SeqCst);
        self.gate(false);
        let hash = instance_hash(&probe.instance_id);
        match answered {
            // Journalled before the Keychain save, so a restart cannot lose the revocation.
            Some((true, seq)) if result.is_ok() => self.journal_revoke(hash, seq),
            Some((false, seq)) if result.is_ok() => self.journal_clear(hash, seq),
            _ => {}
        }
        if network_down {
            self.meta.lock().unwrap().recovery_armed = true;
        }
        {
            let ordered = self.mutate.lock().unwrap();
            self.persist(&ordered);
        }
        self.publish(|meta| {
            meta.checking = false;
            let storage_trouble = meta.storage_trouble();
            match &result {
                Err(error) if !storage_trouble => meta.last_error = Some(error.message()),
                Ok(_) if !storage_trouble => meta.last_error = None,
                _ => {}
            }
        });
        self.apply();
        result
    }

    /// Delivers owed deactivations every few minutes, stopping at the first rate limit.
    fn release_cleanups(&self, now: i64) {
        {
            let mut meta = self.meta.lock().unwrap();
            if meta
                .last_cleanup_at
                .is_some_and(|last| now - last < CLEANUP_RETRY.as_secs() as i64)
            {
                return;
            }
            meta.last_cleanup_at = Some(now);
        }
        let ordered = self.mutate.lock().unwrap();
        let pending = self.engine.lock().unwrap().take_cleanups(self.now());
        if pending.is_empty() {
            return;
        }
        let mut pending = pending.into_iter();
        for probe in pending.by_ref() {
            if self.engine.lock().unwrap().is_held(self.now()) {
                self.engine.lock().unwrap().remember_cleanup(probe);
                break;
            }
            self.release(&ordered, probe);
        }
        let mut engine = self.engine.lock().unwrap();
        for probe in pending {
            engine.remember_cleanup(probe);
        }
        drop(engine);
        self.persist(&ordered);
    }

    /// Deactivates an activation this Mac no longer uses, remembering it if Dodo does not answer.
    fn release(&self, _ordered: &MutexGuard<'_, ()>, probe: Probe) {
        let answer = self.dodo.deactivate(&probe.license_key, &probe.instance_id);
        self.engine
            .lock()
            .unwrap()
            .apply_release(probe, answer, self.now());
    }

    /// Writes the current license record. Requires the ordering lock, so writes land in the
    /// order the changes were made and a slower writer can never restore an older record.
    fn persist(&self, _ordered: &MutexGuard<'_, ()>) {
        let stored = self.engine.lock().unwrap().stored.clone();
        self.generation.fetch_add(1, Ordering::SeqCst);
        match self.vault.save(&stored) {
            Ok(()) => {
                *self.durable.lock().unwrap() = Some(stored.clone());
                // The lost access is durable now, so its journal note has done its job.
                let clear = {
                    let mut meta = self.meta.lock().unwrap();
                    let mut clear = std::mem::take(&mut meta.clear_after_save);
                    if let Some(record) = stored.license.as_ref().filter(|record| record.revoked) {
                        clear.push((instance_hash(&record.instance_id), record.event_seq));
                    }
                    // A note that never got written is not needed any more either.
                    for (hash, seq) in &clear {
                        if meta
                            .journal_retry
                            .get(hash)
                            .is_some_and(|op| matches!(op, JournalOp::Revoke(s) if s <= seq))
                        {
                            meta.journal_retry.remove(hash);
                        }
                    }
                    clear
                };
                for (hash, seq) in clear {
                    self.journal_clear(hash, seq);
                }
                let was_dirty = std::mem::take(&mut self.meta.lock().unwrap().storage_dirty);
                if was_dirty {
                    self.publish(|meta| {
                        if !meta.storage_trouble() {
                            meta.last_error = None;
                        }
                    });
                }
            }
            Err(error) => {
                self.publish(|meta| {
                    meta.storage_dirty = true;
                    meta.last_error = Some(error);
                });
            }
        }
    }

    fn state(&self) -> State {
        self.engine.lock().unwrap().state(self.now())
    }

    /// The gate from records in memory and on disk, under the engine lock: the state to show and
    /// whether playback is allowed. A restriction in memory counts at once, an extension only
    /// once it is saved; when the saved records allow less, their state is what shows.
    fn effective(
        engine: &Engine,
        ready: bool,
        journal_unreadable: bool,
        durable: State,
        at: Moment,
    ) -> (State, bool) {
        let memory = engine.state(at);
        let shown = if memory.core_feature() && !durable.core_feature() {
            durable
        } else {
            memory
        };
        let playable =
            ready && !journal_unreadable && memory.core_feature() && durable.core_feature();
        (shown, playable)
    }

    /// The saved records' state, measured with the engine's clock.
    fn durable_state(&self, engine: &Engine, at: Moment) -> State {
        let stored = self.durable.lock().unwrap();
        let trial = self.durable_trial.lock().unwrap();
        match stored.as_ref() {
            Some(stored) => engine.durable_state(stored, &trial, at),
            None => State::Unlicensed,
        }
    }

    /// Decides the gate under the engine lock and stamps it with the next revision.
    fn decide(&self) -> (u64, bool, &'static str) {
        let engine = self.engine.lock().unwrap();
        let now = self.now();
        let (ready, journal_unreadable) = {
            let meta = self.meta.lock().unwrap();
            (meta.ready, meta.journal_unreadable)
        };
        let durable = self.durable_state(&engine, now);
        let (shown, playable) = Self::effective(&engine, ready, journal_unreadable, durable, now);
        let reason = match shown {
            State::TrialEnded => "Free trial ended",
            State::TrialOffline => "Connect to continue your free trial",
            State::ClockBehind => "Mac clock is behind",
            _ => "License needed",
        };
        let revision = self.gate_revision.fetch_add(1, Ordering::SeqCst) + 1;
        (revision, !playable, reason)
    }

    /// Publishes the gate: a restriction always, a permission only when the caller says the
    /// record it depends on is saved.
    fn gate(&self, allow_unlock: bool) {
        let (revision, blocked, reason) = self.decide();
        if blocked || allow_unlock {
            self.host.set_blocked(revision, blocked, reason);
        }
    }

    /// Re-evaluates the gate in both directions and tells the window.
    pub fn apply(&self) {
        self.gate(true);
        self.publish(|_| {});
    }

    pub fn view(&self) -> View {
        let now = self.now();
        let engine = self.engine.lock().unwrap();
        let meta = self.meta.lock().unwrap();
        let durable = self.durable_state(&engine, now);
        let (state, playable) =
            Self::effective(&engine, meta.ready, meta.journal_unreadable, durable, now);
        View {
            revision: meta.revision,
            ready: meta.ready,
            environment: ENVIRONMENT,
            state,
            core_feature: playable,
            clock_changed: engine.clock_changed(now),
            journal_unreadable: meta.journal_unreadable,
            trial_storage_error: meta.trial_failures > 0,
            grace_warning: matches!(state, State::Grace { .. })
                && engine
                    .offline_for(now)
                    .is_some_and(|age| age >= GRACE_WARNING_AFTER),
            checking: meta.checking,
            last_success_at: engine.license().map(|r| r.last_success_at),
            last_error: meta.last_error.clone(),
            pending_key: meta.pending_key.clone(),
            buy_url: BUY_URL,
            support_url: SUPPORT_URL,
        }
    }

    fn publish(&self, change: impl FnOnce(&mut Meta)) -> View {
        {
            let mut meta = self.meta.lock().unwrap();
            change(&mut meta);
            meta.revision += 1;
        }
        let view = self.view();
        self.host.publish(&view);
        view
    }

    /// Activates a key. The record is saved before it takes effect; if it cannot be saved, the
    /// new slot is given back and the previous activation stays.
    pub fn activate(&self, key: &str) -> Result<View, String> {
        let outcome = {
            let ordered = self.mutate.lock().unwrap();
            self.activate_ordered(&ordered, key)
        };
        let outcome = outcome.map_err(|error| error.message());
        self.publish(|meta| {
            if !meta.storage_trouble() {
                meta.last_error = None;
            }
            if outcome.is_ok() {
                meta.pending_key = None;
            }
        });
        self.apply();
        self.poke();
        outcome.map(|_| self.view())
    }

    fn activate_ordered(
        &self,
        ordered: &MutexGuard<'_, ()>,
        key: &str,
    ) -> Result<State, LicenseError> {
        let now = self.now();
        self.engine.lock().unwrap().activation_allowed(key, now)?;
        let activation = match self.dodo.activate(key.trim(), super::core::ACTIVATION_NAME) {
            Ok(activation) => activation,
            Err(DodoError::RateLimited { retry_after }) => {
                self.engine
                    .lock()
                    .unwrap()
                    .note_rate_limit(now, retry_after);
                return Err(LicenseError::RateLimited { retry_after });
            }
            Err(error) => return Err(error.into()),
        };
        let accepted = self
            .engine
            .lock()
            .unwrap()
            .accept_activation(key, activation, now);
        let activated = match accepted {
            Ok(activated) => activated,
            Err(Refusal { probe, error }) => {
                // Give the slot back and keep nothing.
                self.release(ordered, probe);
                self.persist(ordered);
                return Err(error);
            }
        };
        if let Err(error) = self.vault.save(&activated.next) {
            // Not in effect: give the new slot back so the customer keeps all three Macs.
            self.release(ordered, activated.probe);
            self.persist(ordered);
            self.publish(|meta| meta.last_error = Some(error.clone()));
            return Err(LicenseError::NotSaved(error));
        }
        let (state, replaced) = {
            let mut engine = self.engine.lock().unwrap();
            let next = activated.next.clone();
            let replaced = engine.commit_activation(activated, now);
            // The record just saved is the one now in effect.
            *self.durable.lock().unwrap() = Some(next);
            self.generation.fetch_add(1, Ordering::SeqCst);
            (engine.state(now), replaced)
        };
        self.gate(false);
        if let Some(replaced) = replaced {
            // The new record is already saved, so any note about the old activation is stale.
            self.journal_clear(instance_hash(&replaced.instance_id), u64::MAX);
            self.release(ordered, replaced);
            self.persist(ordered);
        }
        Ok(state)
    }

    /// Settings → License → Remove this Mac. Playback stops before the cleared record is saved;
    /// the Mac then returns to its trial, whose record is never touched.
    pub fn remove(&self) -> Result<View, String> {
        let outcome = {
            let ordered = self.mutate.lock().unwrap();
            let now = self.now();
            let begun = self.engine.lock().unwrap().begin_remove(now);
            begun.and_then(|probe| {
                let answer = self.dodo.deactivate(&probe.license_key, &probe.instance_id);
                let removed_seq = self
                    .engine
                    .lock()
                    .unwrap()
                    .stored
                    .license
                    .as_ref()
                    .filter(|record| record.instance_id == probe.instance_id)
                    .map(|record| record.event_seq + 1);
                let result = self
                    .engine
                    .lock()
                    .unwrap()
                    .finish_remove(&probe, answer, now);
                self.generation.fetch_add(1, Ordering::SeqCst);
                self.gate(false);
                if let Some(seq) = removed_seq
                    && self.engine.lock().unwrap().stored.license.is_none()
                {
                    // A tombstone until the cleared record is saved: if that save fails and
                    // the app restarts offline, the old record must not come back to life.
                    let hash = instance_hash(&probe.instance_id);
                    self.journal_revoke(hash.clone(), seq);
                    self.meta.lock().unwrap().clear_after_save.push((hash, seq));
                }
                self.persist(&ordered);
                // A Mac whose trial record was wiped starts one, and the registry decides how
                // much of it is left.
                self.ensure_trial_ordered(&ordered, true);
                result
            })
        };
        let outcome = outcome.map_err(|error| error.message());
        self.publish(|meta| {
            if !meta.storage_trouble() {
                meta.last_error = None;
            }
            meta.register_now = true;
        });
        self.apply();
        self.poke();
        outcome.map(|_| self.view())
    }

    /// `openklack://activate?key=…` only pre-fills the key; the user confirms before
    /// activating. Other parameters are ignored.
    pub fn opened(&self, urls: &[url::Url]) {
        if let Some(key) = urls.iter().find_map(parse_activation_link) {
            self.publish(|meta| meta.pending_key = Some(key));
        }
    }

    pub fn dismiss_key(&self) -> View {
        self.publish(|meta| meta.pending_key = None)
    }
}

/// The key from an `openklack://activate` link.
fn parse_activation_link(url: &url::Url) -> Option<String> {
    if url.scheme() != "openklack" || url.host_str() != Some("activate") {
        return None;
    }
    url.query_pairs().find_map(|(name, value)| {
        let value = value.trim();
        (name == "key"
            && !value.is_empty()
            && value.len() <= 200
            && value.bytes().all(|b| b.is_ascii_graphic()))
        .then(|| value.to_string())
    })
}

/// Called from the audio engine when the Mac wakes.
pub fn wake(app: &tauri::AppHandle) {
    if let Some(service) = app.try_state::<Arc<Live>>() {
        service.woke();
    }
}

/// Called as the app exits: saves the trial's `last_seen_at`, waiting at most two seconds.
pub fn quit(app: &tauri::AppHandle) {
    if let Some(service) = app.try_state::<Arc<Live>>() {
        let _ = service.inner().clone().flush_within(QUIT_SAVE_WAIT);
    }
}

pub fn opened(app: &tauri::AppHandle, urls: &[url::Url]) {
    if let Some(service) = app.try_state::<Arc<Live>>() {
        service.opened(urls);
    }
    let _ = crate::show_settings(app);
}

#[tauri::command]
pub fn license_status(state: tauri::State<'_, Arc<Live>>) -> View {
    state.view()
}

#[tauri::command]
pub async fn activate_license(
    state: tauri::State<'_, Arc<Live>>,
    key: String,
) -> Result<View, String> {
    let service = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || service.activate(&key))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn remove_license(state: tauri::State<'_, Arc<Live>>) -> Result<View, String> {
    let service = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || service.remove())
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn check_license_now(state: tauri::State<'_, Arc<Live>>) -> Result<View, String> {
    let service = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let result = service.check_once(true).map_err(|error| error.message());
        service.poke();
        result.map(|_| service.view())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Try again after storage could not be read or saved, or while the trial waits for the
/// registry or a corrected clock.
#[tauri::command]
pub async fn reload_license(state: tauri::State<'_, Arc<Live>>) -> Result<View, String> {
    let service = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        if service.view().ready {
            service.retry_trial();
            let _ = service.check_once(true);
            service.register_once(true);
            service.apply();
            service.poke();
        } else {
            service.load();
        }
        service.view()
    })
    .await
    .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn dismiss_license_key(state: tauri::State<'_, Arc<Live>>) -> View {
    state.dismiss_key()
}

/// Opens the configured checkout or support link in the default browser.
#[tauri::command]
pub fn open_license_link(link: String) -> Result<(), String> {
    let url = match link.as_str() {
        "buy" => BUY_URL,
        "support" => SUPPORT_URL,
        _ => return Err("Unknown link.".into()),
    };
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(url)
            .spawn()
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = url;
        Err("Opening links is supported on macOS.".into())
    }
}

#[cfg(test)]
mod tests {
    //! The service with a scripted Dodo and trial registry, an in-memory vault and a fake app,
    //! driven by threads so the lock ordering and gate ordering themselves are under test.
    use super::super::core::{Record, TRIAL_LENGTH};
    use super::*;
    use std::{
        sync::{
            atomic::{AtomicBool, AtomicI64},
            mpsc,
        },
        thread,
    };

    const NOW: i64 = 1_800_000_000;
    const HOUR: i64 = 3600;
    const TIMEOUT: Duration = Duration::from_secs(5);
    const HARDWARE_UUID: &str = "00000000-1111-2222-3333-444444444444";

    struct FakeDodo {
        product_id: String,
        validate: Mutex<Vec<Result<Validation, DodoError>>>,
        calls: Mutex<Vec<String>>,
    }

    impl FakeDodo {
        fn paid() -> Self {
            Self {
                product_id: PAID_PRODUCT_ID.split(',').next().unwrap().into(),
                validate: Mutex::new(Vec::new()),
                calls: Mutex::new(Vec::new()),
            }
        }
        fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }
        fn answer(&self, answer: Result<Validation, DodoError>) {
            self.validate.lock().unwrap().push(answer);
        }
    }

    impl Dodo for FakeDodo {
        fn activate(&self, key: &str, name: &str) -> Result<Activation, DodoError> {
            self.calls
                .lock()
                .unwrap()
                .push(format!("activate {key} {name}"));
            Ok(Activation {
                id: format!("lki_{key}"),
                product_id: self.product_id.clone(),
                product_name: "OpenKlack".into(),
                created_at: NOW,
                server_time: Some(NOW),
            })
        }
        fn validate(&self, key: &str, instance: &str) -> Result<Validation, DodoError> {
            self.calls
                .lock()
                .unwrap()
                .push(format!("validate {key} {instance}"));
            let mut queue = self.validate.lock().unwrap();
            if queue.is_empty() {
                Ok(Validation {
                    valid: true,
                    server_time: Some(NOW),
                })
            } else {
                queue.remove(0)
            }
        }
        fn deactivate(&self, key: &str, instance: &str) -> Result<(), DodoError> {
            self.calls
                .lock()
                .unwrap()
                .push(format!("deactivate {key} {instance}"));
            Ok(())
        }
    }

    /// A one-shot pause: the next entry blocks until `open`.
    #[derive(Default)]
    struct Pause {
        armed: AtomicBool,
        entered: AtomicBool,
        gate: (Mutex<bool>, Condvar),
    }

    impl Pause {
        fn arm(&self) {
            *self.gate.0.lock().unwrap() = false;
            self.entered.store(false, Ordering::SeqCst);
            self.armed.store(true, Ordering::SeqCst);
        }
        fn enter(&self) {
            if self.armed.swap(false, Ordering::SeqCst) {
                self.entered.store(true, Ordering::SeqCst);
                let mut open = self.gate.0.lock().unwrap();
                while !*open {
                    open = self.gate.1.wait(open).unwrap();
                }
            }
        }
        fn wait_entered(&self) {
            let deadline = std::time::Instant::now() + TIMEOUT;
            while !self.entered.load(Ordering::SeqCst) {
                assert!(
                    std::time::Instant::now() < deadline,
                    "the pause was never reached"
                );
                thread::sleep(Duration::from_millis(1));
            }
        }
        fn open(&self) {
            *self.gate.0.lock().unwrap() = true;
            self.gate.1.notify_all();
        }
    }

    /// A scripted trial registry: queued answers, then `sticky`; with neither it is unreachable.
    #[derive(Default)]
    struct FakeRegistry {
        answers: Mutex<Vec<Result<RegistryAnswer, RegistryError>>>,
        sticky: Mutex<Option<RegistryAnswer>>,
        devices: Mutex<Vec<String>>,
        pause: Pause,
    }

    impl FakeRegistry {
        /// From now on the registry answers with this start, on its own clock.
        fn started(&self, started_at: i64, now: i64) {
            *self.sticky.lock().unwrap() = Some(RegistryAnswer { started_at, now });
        }
        fn answer(&self, answer: Result<RegistryAnswer, RegistryError>) {
            self.answers.lock().unwrap().push(answer);
        }
        fn calls(&self) -> usize {
            self.devices.lock().unwrap().len()
        }
    }

    impl Registry for FakeRegistry {
        fn register(&self, device: &str) -> Result<RegistryAnswer, RegistryError> {
            self.pause.enter();
            self.devices.lock().unwrap().push(device.into());
            let mut queue = self.answers.lock().unwrap();
            if !queue.is_empty() {
                return queue.remove(0);
            }
            (*self.sticky.lock().unwrap())
                .ok_or_else(|| RegistryError::Offline("unreachable".into()))
        }
    }

    /// An in-memory Keychain whose reads and writes can be paused so slow I/O can be raced.
    #[derive(Default)]
    struct FakeVault {
        stored: Mutex<Stored>,
        writes: Mutex<Vec<Stored>>,
        save_error: Mutex<Option<String>>,
        load_error: Mutex<Option<String>>,
        read_pause: Pause,
        write_pause: Pause,
        /// The trial item; `None` is positively absent.
        trial: Mutex<Option<TrialRecord>>,
        trial_writes: Mutex<Vec<TrialRecord>>,
        trial_save_error: Mutex<Option<String>>,
        trial_load_error: Mutex<Option<String>>,
        trial_write_pause: Pause,
    }

    impl FakeVault {
        /// What a restart would find: the same bytes, in a fresh handle.
        fn reopen(&self) -> FakeVault {
            let vault = FakeVault::default();
            *vault.stored.lock().unwrap() = self.stored.lock().unwrap().clone();
            *vault.trial.lock().unwrap() = self.trial.lock().unwrap().clone();
            vault
        }
        fn saved_trial(&self) -> Option<TrialRecord> {
            self.trial.lock().unwrap().clone()
        }
        fn trial_writes(&self) -> Vec<TrialRecord> {
            self.trial_writes.lock().unwrap().clone()
        }
    }

    impl Vault for FakeVault {
        fn load(&self) -> Result<Stored, String> {
            self.read_pause.enter();
            if let Some(error) = self.load_error.lock().unwrap().clone() {
                return Err(error);
            }
            Ok(self.stored.lock().unwrap().clone())
        }
        fn save(&self, stored: &Stored) -> Result<(), String> {
            self.write_pause.enter();
            if let Some(error) = self.save_error.lock().unwrap().clone() {
                return Err(error);
            }
            *self.stored.lock().unwrap() = stored.clone();
            self.writes.lock().unwrap().push(stored.clone());
            Ok(())
        }
        fn load_trial(&self) -> Result<Option<TrialRecord>, String> {
            if let Some(error) = self.trial_load_error.lock().unwrap().clone() {
                return Err(error);
            }
            Ok(self.trial.lock().unwrap().clone())
        }
        fn save_trial(&self, trial: &TrialRecord) -> Result<(), String> {
            self.trial_write_pause.enter();
            if let Some(error) = self.trial_save_error.lock().unwrap().clone() {
                return Err(error);
            }
            *self.trial.lock().unwrap() = Some(trial.clone());
            self.trial_writes.lock().unwrap().push(trial.clone());
            Ok(())
        }
    }

    /// The audio side: applies only newer gate revisions, atomically, like the controller.
    #[derive(Default)]
    struct FakeHost {
        gate: Mutex<(u64, bool)>,
        reason: Mutex<&'static str>,
        reachable: AtomicBool,
        registry_reachable: AtomicBool,
        no_hardware_uuid: AtomicBool,
        unlock_pause: Pause,
    }

    impl FakeHost {
        fn blocked(&self) -> bool {
            self.gate.lock().unwrap().1
        }
        fn reason(&self) -> &'static str {
            *self.reason.lock().unwrap()
        }
    }

    impl Host for FakeHost {
        fn publish(&self, _: &View) {}
        fn set_blocked(&self, revision: u64, blocked: bool, reason: &'static str) {
            if !blocked {
                self.unlock_pause.enter();
            }
            let mut gate = self.gate.lock().unwrap();
            if revision > gate.0 {
                *gate = (revision, blocked);
                *self.reason.lock().unwrap() = reason;
            }
        }
        fn reachable(&self) -> bool {
            self.reachable.load(Ordering::SeqCst)
        }
        fn registry_reachable(&self) -> bool {
            self.registry_reachable.load(Ordering::SeqCst)
        }
        fn hardware_uuid(&self) -> Option<String> {
            (!self.no_hardware_uuid.load(Ordering::SeqCst)).then(|| HARDWARE_UUID.into())
        }
    }

    /// The journal as a shared map, so a "restart" can reuse it alongside the vault.
    #[derive(Default)]
    struct FakeJournal(Mutex<std::collections::BTreeMap<String, u64>>);

    impl Journal for Arc<FakeJournal> {
        fn entry(&self, hash: &str) -> Result<Option<u64>, String> {
            self.0
                .lock()
                .unwrap()
                .get(hash)
                .copied()
                .map(Ok)
                .transpose()
        }
        fn revoke(&self, hash: &str, seq: u64) -> Result<(), String> {
            let mut entries = self.0.lock().unwrap();
            if entries.get(hash).is_none_or(|current| *current < seq) {
                entries.insert(hash.into(), seq);
            }
            Ok(())
        }
        fn clear(&self, hash: &str, up_to_seq: u64) -> Result<(), String> {
            let mut entries = self.0.lock().unwrap();
            if entries
                .get(hash)
                .is_some_and(|current| *current <= up_to_seq)
            {
                entries.remove(hash);
            }
            Ok(())
        }
    }

    type TestService = Service<FakeDodo, FakeRegistry, FakeVault, FakeHost, Arc<FakeJournal>>;

    fn paid_record(key: &str, last_success_ago: i64) -> Record {
        Record {
            license_key: key.into(),
            instance_id: format!("lki_{key}"),
            product_id: PAID_PRODUCT_ID.split(',').next().unwrap().into(),
            kind: None,
            activated_at: NOW - 30 * DAY,
            last_success_at: NOW - last_success_ago,
            last_success_local: NOW - last_success_ago,
            last_observed_at: NOW - last_success_ago,
            revoked: false,
            event_seq: 1,
        }
    }

    /// A trial record `elapsed` seconds in, last seen at `NOW`.
    fn trial_record(elapsed: i64, registered: bool) -> TrialRecord {
        TrialRecord {
            started_at: NOW - elapsed,
            last_seen_at: NOW,
            registered,
            device_id: None,
        }
    }

    /// A service over a vault holding `stored` and no trial record.
    fn service(stored: Stored, clock: Arc<AtomicI64>) -> Arc<TestService> {
        let vault = FakeVault::default();
        *vault.stored.lock().unwrap() = stored;
        service_with(vault, Arc::new(FakeJournal::default()), clock)
    }

    /// A service over a vault holding no license and this trial record.
    fn trial_service(trial: TrialRecord, clock: Arc<AtomicI64>) -> Arc<TestService> {
        let vault = FakeVault::default();
        *vault.trial.lock().unwrap() = Some(trial);
        service_with(vault, Arc::new(FakeJournal::default()), clock)
    }

    /// A service over existing stores: what a restart sees.
    fn service_with(
        vault: FakeVault,
        journal: Arc<FakeJournal>,
        clock: Arc<AtomicI64>,
    ) -> Arc<TestService> {
        monotonic_service(vault, journal, clock, Arc::new(AtomicI64::new(0)))
    }

    /// A service whose monotonic clock the test moves by hand.
    fn monotonic_service(
        vault: FakeVault,
        journal: Arc<FakeJournal>,
        clock: Arc<AtomicI64>,
        mono: Arc<AtomicI64>,
    ) -> Arc<TestService> {
        let service = Arc::new(Service::new(
            FakeDodo::paid(),
            FakeRegistry::default(),
            vault,
            FakeHost::default(),
            journal,
            Box::new(move || clock.load(Ordering::SeqCst)),
            Box::new(move || mono.load(Ordering::SeqCst)),
        ));
        // As `Live::start` does: gated until the records are read.
        service.apply();
        service
    }

    fn with_paid(last_success_ago: i64) -> Stored {
        Stored {
            license: Some(paid_record("KEY-PAID", last_success_ago)),
            ..Stored::default()
        }
    }

    /// Runs `task` on its own thread and fails instead of hanging if it never returns.
    fn within_timeout<T: Send + 'static>(task: impl FnOnce() -> T + Send + 'static) -> T {
        let (done, finished) = mpsc::channel();
        thread::spawn(move || {
            let _ = done.send(task());
        });
        finished
            .recv_timeout(TIMEOUT)
            .expect("the service deadlocked")
    }

    fn wait_until_blocked(service: &TestService) {
        let deadline = std::time::Instant::now() + TIMEOUT;
        while !service.host.blocked() {
            assert!(
                std::time::Instant::now() < deadline,
                "the enforcer never blocked playback"
            );
            thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn case_12_a_fresh_mac_saves_a_provisional_trial_plays_and_then_registers() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(Stored::default(), clock.clone());
        assert!(service.host.blocked());
        service.registry.started(NOW, NOW);
        service.registry.pause.arm();
        let loading = {
            let service = service.clone();
            thread::spawn(move || service.load())
        };
        service.registry.pause.wait_entered();
        // Before the registry answers: the provisional record is saved and sounds are on.
        assert_eq!(
            service.vault.trial_writes(),
            vec![TrialRecord::provisional(NOW, NOW)]
        );
        assert_eq!(service.view().state, State::Trial { days_left: 3 });
        assert!(!service.host.blocked());
        service.registry.pause.open();
        loading.join().unwrap();
        let saved = service.vault.saved_trial().unwrap();
        assert!(saved.registered);
        assert_eq!(saved.started_at, NOW);
        assert_eq!(service.view().state, State::Trial { days_left: 3 });
        assert!(!service.host.blocked());
        assert_eq!(
            *service.registry.devices.lock().unwrap(),
            vec![device_hash(APP_ID, HARDWARE_UUID)]
        );
        assert!(service.dodo.calls().is_empty(), "no license, no Dodo calls");
        assert!(
            service.vault.writes.lock().unwrap().is_empty(),
            "no license record is written"
        );
        // A registered trial never contacts the registry again, not even after a wake.
        clock.store(NOW + 2 * HOUR, Ordering::SeqCst);
        service.woke();
        service.tick();
        service.tick();
        assert_eq!(service.registry.calls(), 1);
    }

    #[test]
    fn case_13_a_registered_trial_past_three_days_launches_ended_without_network_calls() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = trial_service(trial_record(TRIAL_LENGTH + 60, true), clock.clone());
        service.load();
        assert_eq!(service.view().state, State::TrialEnded);
        assert!(!service.view().core_feature);
        assert!(service.host.blocked());
        assert_eq!(service.host.reason(), "Free trial ended");
        // Online or offline makes no difference: nothing is asked.
        service.host.reachable.store(true, Ordering::SeqCst);
        service
            .host
            .registry_reachable
            .store(true, Ordering::SeqCst);
        clock.store(NOW + HOUR, Ordering::SeqCst);
        service.woke();
        service.tick();
        assert!(service.dodo.calls().is_empty());
        assert_eq!(service.registry.calls(), 0);
        assert_eq!(service.view().state, State::TrialEnded);
    }

    #[test]
    fn case_14_a_relaunch_with_the_clock_set_back_waits_for_the_clock_and_saves_nothing() {
        let clock = Arc::new(AtomicI64::new(NOW - 5 * DAY));
        let original = trial_record(2 * DAY, true);
        let service = trial_service(original.clone(), clock.clone());
        service.load();
        let view = service.view();
        assert_eq!(view.state, State::ClockBehind);
        assert!(!view.core_feature);
        assert!(service.host.blocked());
        assert_eq!(service.host.reason(), "Mac clock is behind");
        clock.store(NOW - 5 * DAY + HOUR, Ordering::SeqCst);
        service.tick();
        service.flush();
        assert_eq!(service.view().state, State::ClockBehind);
        assert!(service.vault.trial_writes().is_empty(), "nothing is saved");
        assert_eq!(service.vault.saved_trial(), Some(original));
        assert!(
            service.next_wait() <= DEADLINE_RECHECK,
            "the clock is watched"
        );
        // Corrected: the trial continues with the time it had used.
        clock.store(NOW, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.view().state, State::Trial { days_left: 1 });
        assert!(!service.host.blocked());
        assert_eq!(service.registry.calls(), 0);
    }

    #[test]
    fn case_15_the_trial_ends_on_time_while_a_save_is_stuck() {
        // Two days, 23 hours and 59 minutes in. A `last_seen_at` write starts before the end and
        // hangs; the deadline enforcer runs on its own thread and blocks playback on time.
        let clock = Arc::new(AtomicI64::new(NOW));
        let mut trial = trial_record(TRIAL_LENGTH - 60, true);
        trial.last_seen_at = NOW - 2 * HOUR;
        let service = trial_service(trial, clock.clone());
        service.load();
        assert_eq!(service.view().state, State::Trial { days_left: 0 });
        assert!(!service.host.blocked());
        let _enforcer = {
            let service = service.clone();
            thread::spawn(move || service.run_deadlines())
        };
        clock.store(NOW + 1, Ordering::SeqCst);
        service.vault.trial_write_pause.arm();
        let worker = {
            let service = service.clone();
            thread::spawn(move || service.tick())
        };
        service.vault.trial_write_pause.wait_entered();
        clock.store(NOW + 120, Ordering::SeqCst);
        assert!(!service.view().core_feature);
        service.poke_deadlines();
        wait_until_blocked(&service);
        assert!(
            !worker.is_finished(),
            "the scheduler is still stuck in the write"
        );
        assert_eq!(service.registry.calls(), 0, "no network call either");
        assert!(service.dodo.calls().is_empty());
        service.vault.trial_write_pause.open();
        worker.join().unwrap();
        assert!(service.host.blocked());
        assert_eq!(service.view().state, State::TrialEnded);
    }

    #[test]
    fn case_16_a_trial_that_cannot_be_saved_does_not_run_and_is_retried() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(Stored::default(), clock.clone());
        *service.vault.trial_save_error.lock().unwrap() = Some("keychain locked".into());
        service.registry.started(NOW, NOW);
        service.load();
        let view = service.view();
        assert!(view.ready);
        assert_eq!(view.state, State::Unlicensed);
        assert!(view.trial_storage_error);
        assert!(!view.core_feature);
        assert!(view.last_error.unwrap().contains("keychain locked"));
        assert!(service.host.blocked());
        assert_eq!(service.vault.saved_trial(), None);
        assert_eq!(service.registry.calls(), 0, "no trial is running");
        // Retried with backoff, not every tick.
        assert_eq!(service.next_wait(), Duration::from_secs(60));
        clock.store(NOW + 10, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.view().state, State::Unlicensed);
        assert!(service.host.blocked());
        *service.vault.trial_save_error.lock().unwrap() = None;
        clock.store(NOW + 60, Ordering::SeqCst);
        service.tick();
        let view = service.view();
        assert_eq!(view.state, State::Trial { days_left: 3 });
        assert!(!view.trial_storage_error);
        assert_eq!(view.last_error, None);
        assert!(!service.host.blocked());
        assert_eq!(
            service.vault.trial_writes()[0],
            TrialRecord::provisional(NOW + 60, NOW + 60)
        );
        assert_eq!(service.registry.calls(), 1);
    }

    #[test]
    fn case_17_an_unreadable_trial_record_is_a_storage_error_and_never_replaced() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let original = trial_record(DAY, true);
        let service = trial_service(original.clone(), clock.clone());
        *service.vault.trial_load_error.lock().unwrap() = Some("keychain denied".into());
        service.load();
        let view = service.view();
        assert!(view.ready);
        assert_eq!(view.state, State::Unlicensed);
        assert!(view.trial_storage_error);
        assert!(view.last_error.unwrap().contains("keychain denied"));
        assert!(service.host.blocked());
        assert_eq!(service.registry.calls(), 0);
        clock.store(NOW + 10, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.view().state, State::Unlicensed);
        assert!(
            service.vault.trial_writes().is_empty(),
            "no new trial is created"
        );
        assert_eq!(service.vault.saved_trial(), Some(original.clone()));
        // Readable again after the backoff: the existing trial continues.
        *service.vault.trial_load_error.lock().unwrap() = None;
        clock.store(NOW + 60, Ordering::SeqCst);
        service.tick();
        let view = service.view();
        assert_eq!(view.state, State::Trial { days_left: 2 });
        assert!(!view.trial_storage_error);
        assert_eq!(view.last_error, None);
        assert!(!service.host.blocked());
        assert!(service.vault.trial_writes().is_empty());
        assert_eq!(service.registry.calls(), 0);
        // A license does not depend on the trial record.
        let licensed = self::service(with_paid(HOUR), clock);
        *licensed.vault.trial_load_error.lock().unwrap() = Some("keychain denied".into());
        licensed.load();
        assert_eq!(licensed.view().state, State::Licensed);
        assert!(licensed.view().trial_storage_error);
        assert!(!licensed.host.blocked());
        assert!(licensed.vault.trial_writes().is_empty());
    }

    #[test]
    fn case_18_a_wiped_keychain_gets_the_registry_start_back_and_the_trial_ends() {
        let service = service(Stored::default(), Arc::new(AtomicI64::new(NOW)));
        service.registry.started(NOW - 4 * DAY, NOW);
        service.load();
        assert_eq!(service.view().state, State::TrialEnded);
        assert!(service.host.blocked());
        assert_eq!(service.host.reason(), "Free trial ended");
        let writes = service.vault.trial_writes();
        assert_eq!(writes.len(), 2);
        assert_eq!(writes[0], TrialRecord::provisional(NOW, NOW));
        assert!(writes[1].registered);
        assert_eq!(writes[1].started_at, NOW - 4 * DAY);
    }

    #[test]
    fn case_19_a_wiped_keychain_one_day_in_resumes_with_two_days_left() {
        let service = service(Stored::default(), Arc::new(AtomicI64::new(NOW)));
        service.registry.started(NOW - DAY, NOW);
        service.load();
        assert_eq!(service.view().state, State::Trial { days_left: 2 });
        assert!(!service.host.blocked());
        let saved = service.vault.saved_trial().unwrap();
        assert!(saved.registered);
        assert_eq!(saved.started_at, NOW - DAY);
    }

    #[test]
    fn case_20_an_unreachable_registry_stops_the_trial_at_24_hours_until_it_answers() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(Stored::default(), clock.clone());
        service.load();
        assert_eq!(service.view().state, State::Trial { days_left: 3 });
        assert!(!service.host.blocked());
        assert_eq!(service.registry.calls(), 1);
        clock.store(NOW + 23 * HOUR, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.view().state, State::Trial { days_left: 3 });
        assert!(!service.host.blocked());
        assert_eq!(service.registry.calls(), 2);
        // The deadline enforcer switches it off at 24 hours, without waiting for the scheduler.
        clock.store(NOW + DAY, Ordering::SeqCst);
        service.enforce();
        assert!(service.host.blocked());
        assert_eq!(service.host.reason(), "Connect to continue your free trial");
        service.tick();
        assert_eq!(service.view().state, State::TrialOffline);
        assert!(service.host.blocked());
        // The registry answers: 25 hours were used, so two days (rounded up) are left.
        service.registry.started(NOW, NOW + 25 * HOUR);
        clock.store(NOW + 25 * HOUR, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.view().state, State::Trial { days_left: 2 });
        assert!(!service.host.blocked());
        assert!(service.vault.saved_trial().unwrap().registered);
    }

    #[test]
    fn case_22_removing_this_mac_after_the_trial_ended_returns_to_trial_ended() {
        let service = service(with_paid(HOUR), Arc::new(AtomicI64::new(NOW)));
        let ended = trial_record(TRIAL_LENGTH + DAY, true);
        *service.vault.trial.lock().unwrap() = Some(ended.clone());
        service.load();
        assert_eq!(service.view().state, State::Licensed);
        assert!(!service.host.blocked());
        let view = service.remove().expect("removed");
        assert_eq!(view.state, State::TrialEnded);
        assert!(service.host.blocked());
        assert_eq!(service.host.reason(), "Free trial ended");
        assert_eq!(service.vault.load().unwrap().license, None);
        assert_eq!(service.vault.saved_trial(), Some(ended));
        assert!(service.vault.trial_writes().is_empty());
        assert_eq!(service.registry.calls(), 0);
        assert!(
            service
                .dodo
                .calls()
                .contains(&"deactivate KEY-PAID lki_KEY-PAID".to_string())
        );
    }

    #[test]
    fn case_23_removing_this_mac_with_a_day_of_trial_left_resumes_the_trial() {
        let service = service(with_paid(HOUR), Arc::new(AtomicI64::new(NOW)));
        *service.vault.trial.lock().unwrap() = Some(trial_record(2 * DAY, true));
        service.load();
        let view = service.remove().expect("removed");
        assert_eq!(view.state, State::Trial { days_left: 1 });
        assert!(!service.host.blocked());
        assert_eq!(service.registry.calls(), 0);
    }

    #[test]
    fn removing_a_license_without_a_trial_record_asks_the_registry_how_much_is_left() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_paid(HOUR), clock.clone());
        service.registry.started(NOW - 10 * DAY, NOW);
        service.load();
        assert_eq!(service.view().state, State::Licensed);
        assert_eq!(
            service.vault.saved_trial(),
            None,
            "a license starts no trial"
        );
        assert_eq!(service.registry.calls(), 0);
        service.remove().expect("removed");
        clock.store(NOW + 1, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.registry.calls(), 1);
        assert_eq!(service.view().state, State::TrialEnded);
        assert!(service.host.blocked());
    }

    #[test]
    fn last_seen_is_saved_hourly_when_the_trial_ends_and_on_quit() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = trial_service(trial_record(HOUR, true), clock.clone());
        service.load();
        let saves = || service.vault.trial_writes();
        clock.store(NOW + 10 * 60, Ordering::SeqCst);
        service.tick();
        assert!(saves().is_empty());
        clock.store(NOW + HOUR, Ordering::SeqCst);
        service.tick();
        assert_eq!(saves().len(), 1);
        assert_eq!(saves()[0].last_seen_at, NOW + HOUR);
        clock.store(NOW + HOUR + 10 * 60, Ordering::SeqCst);
        service.tick();
        assert_eq!(saves().len(), 1, "at most once an hour");
        clock.store(NOW + HOUR + 20 * 60, Ordering::SeqCst);
        service.flush();
        assert_eq!(saves().len(), 2, "saved on quit");
        assert_eq!(saves()[1].last_seen_at, NOW + HOUR + 20 * 60);
        service.flush();
        assert_eq!(saves().len(), 2, "nothing new to save");
        // A failed save never stops the trial and is retried.
        *service.vault.trial_save_error.lock().unwrap() = Some("denied".into());
        clock.store(NOW + 3 * HOUR, Ordering::SeqCst);
        service.tick();
        assert!(!service.host.blocked());
        assert!(service.view().last_error.unwrap().contains("denied"));
        assert!(service.next_wait() <= REACHABILITY_POLL);
        *service.vault.trial_save_error.lock().unwrap() = None;
        clock.store(NOW + 3 * HOUR + 10, Ordering::SeqCst);
        service.tick();
        assert_eq!(saves().len(), 3);
        assert_eq!(service.view().last_error, None);
        // The end of the trial is saved at once, so a clock set back after it can't undo it.
        let ending = trial_service(trial_record(TRIAL_LENGTH - 60, true), clock.clone());
        clock.store(NOW, Ordering::SeqCst);
        ending.load();
        clock.store(NOW + 60, Ordering::SeqCst);
        ending.tick();
        assert_eq!(ending.vault.trial_writes().len(), 1);
        let restarted = service_with(
            ending.vault.reopen(),
            Arc::new(FakeJournal::default()),
            Arc::new(AtomicI64::new(NOW - DAY)),
        );
        restarted.load();
        assert_eq!(restarted.view().state, State::TrialEnded);
    }

    #[test]
    fn wake_and_network_recovery_ask_the_registry_again() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(Stored::default(), clock.clone());
        service.load();
        assert_eq!(service.registry.calls(), 1);
        // Backoff is a minute away and the probe says the registry is unreachable.
        clock.store(NOW + 10, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.registry.calls(), 1);
        // Wake asks again at once.
        clock.store(NOW + 20, Ordering::SeqCst);
        service.woke();
        service.tick();
        assert_eq!(service.registry.calls(), 2);
        // Many failures later the backoff is an hour; the registry coming back is noticed within
        // minutes.
        for _ in 0..6 {
            service.register_once(true);
        }
        assert_eq!(service.registry.calls(), 8);
        assert_eq!(
            service.engine.lock().unwrap().next_registration_at(Moment {
                wall: NOW + 20,
                mono: 0
            }),
            Some(NOW + 20 + HOUR)
        );
        clock.store(NOW + 400, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.registry.calls(), 8);
        service
            .host
            .registry_reachable
            .store(true, Ordering::SeqCst);
        service.registry.started(NOW, NOW + 700);
        clock.store(NOW + 700, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.registry.calls(), 9);
        assert!(service.vault.saved_trial().unwrap().registered);
        assert_eq!(
            service.dodo.calls(),
            Vec::<String>::new(),
            "Dodo's probe is not involved"
        );
    }

    #[test]
    fn a_registry_rate_limit_holds_the_scheduler_and_changes_nothing() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(Stored::default(), clock.clone());
        service
            .registry
            .answer(Err(RegistryError::RateLimited { retry_after: 120 }));
        service.load();
        assert_eq!(service.registry.calls(), 1);
        clock.store(NOW + 119, Ordering::SeqCst);
        service.woke();
        service.tick();
        service.register_once(true);
        assert_eq!(service.registry.calls(), 1, "held, even when forced");
        assert_eq!(service.next_wait(), Duration::from_secs(1));
        assert_eq!(service.view().state, State::Trial { days_left: 3 });
        clock.store(NOW + 120, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.registry.calls(), 2);
    }

    #[test]
    fn without_a_hardware_uuid_the_registry_gets_a_saved_random_stand_in() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(Stored::default(), clock.clone());
        service.host.no_hardware_uuid.store(true, Ordering::SeqCst);
        service.registry.started(NOW, NOW);
        service.load();
        let id = service
            .vault
            .saved_trial()
            .unwrap()
            .device_id
            .expect("a stand-in is saved");
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4", "a version 4 UUID");
        assert_eq!(
            service.vault.trial_writes()[0].device_id.as_deref(),
            Some(id.as_str()),
            "saved with the provisional record, before anything is sent"
        );
        assert_eq!(
            *service.registry.devices.lock().unwrap(),
            vec![device_hash(APP_ID, &id)]
        );
        // An existing record without one gets a stand-in saved before its first request.
        let older = trial_service(trial_record(HOUR, false), clock);
        older.host.no_hardware_uuid.store(true, Ordering::SeqCst);
        older.load();
        let writes = older.vault.trial_writes();
        let id = writes[0].device_id.clone().expect("saved first");
        assert!(!writes[0].registered);
        assert_eq!(
            *older.registry.devices.lock().unwrap(),
            vec![device_hash(APP_ID, &id)]
        );
        assert_ne!(id, service.vault.saved_trial().unwrap().device_id.unwrap());
    }

    #[test]
    fn registry_answers_are_read_from_iso_dates() {
        assert_eq!(
            parse_registry_answer(
                br#"{"started_at":"2026-09-10T12:00:00.000Z","now":"2026-09-15T17:30:00+05:30"}"#
            ),
            Some(RegistryAnswer {
                started_at: 1_789_041_600,
                now: 1_789_473_600,
            })
        );
        assert_eq!(
            parse_registry_answer(br#"{"started_at":"2026-09-10T12:00:00Z"}"#),
            None
        );
        assert_eq!(
            parse_registry_answer(br#"{"started_at":1789041600,"now":1789473600}"#),
            None
        );
        assert_eq!(parse_registry_answer(b"<html>"), None);
    }

    #[test]
    fn case_28_elapsed_time_follows_the_monotonic_clock_while_the_wall_clock_is_frozen_or_set_back()
    {
        for wall_later in [NOW, NOW - 5 * DAY] {
            let clock = Arc::new(AtomicI64::new(NOW));
            let mono = Arc::new(AtomicI64::new(0));
            let vault = FakeVault::default();
            *vault.trial.lock().unwrap() = Some(trial_record(DAY, true));
            let service = monotonic_service(
                vault,
                Arc::new(FakeJournal::default()),
                clock.clone(),
                mono.clone(),
            );
            service.load();
            assert_eq!(service.view().state, State::Trial { days_left: 2 });
            clock.store(wall_later, Ordering::SeqCst);
            mono.store(2 * DAY - 60, Ordering::SeqCst);
            service.tick();
            assert_eq!(service.view().state, State::Trial { days_left: 0 });
            assert!(!service.host.blocked());
            assert_eq!(
                service.vault.saved_trial().unwrap().last_seen_at,
                NOW + 2 * DAY - 60,
                "elapsed advanced by the monotonic time"
            );
            // The deadline switches the core off on monotonic time, from memory.
            mono.store(2 * DAY, Ordering::SeqCst);
            service.enforce();
            assert!(service.host.blocked(), "wall clock at {wall_later}");
            assert_eq!(service.view().state, State::TrialEnded);
            assert_eq!(
                service.engine.lock().unwrap().next_transition_at(Moment {
                    wall: wall_later,
                    mono: 2 * DAY
                }),
                None
            );
        }
    }

    #[test]
    fn case_29_a_registration_whose_save_hangs_turns_the_core_off_at_24_hours_until_saved() {
        // Hour 23, the registry answers, the save hangs. Also with the wall clock rolled back
        // two hours while two hours of monotonic time pass.
        for (wall_later, mono_later) in [(NOW + HOUR, HOUR), (NOW - HOUR, 2 * HOUR)] {
            let clock = Arc::new(AtomicI64::new(NOW));
            let mono = Arc::new(AtomicI64::new(0));
            let vault = FakeVault::default();
            *vault.trial.lock().unwrap() = Some(trial_record(23 * HOUR, false));
            let service = monotonic_service(
                vault,
                Arc::new(FakeJournal::default()),
                clock.clone(),
                mono.clone(),
            );
            service.registry.started(NOW - 23 * HOUR, NOW);
            service.vault.trial_write_pause.arm();
            let _enforcer = {
                let service = service.clone();
                thread::spawn(move || service.run_deadlines())
            };
            let loading = {
                let service = service.clone();
                thread::spawn(move || service.load())
            };
            service.vault.trial_write_pause.wait_entered();
            assert!(!service.host.blocked(), "still inside the offline limit");
            clock.store(wall_later, Ordering::SeqCst);
            mono.store(mono_later, Ordering::SeqCst);
            service.poke_deadlines();
            wait_until_blocked(&service);
            let view = service.view();
            assert_eq!(view.state, State::TrialOffline);
            assert!(!view.core_feature);
            service.vault.trial_write_pause.open();
            loading.join().unwrap();
            assert!(!service.host.blocked(), "back on once saved");
            assert!(service.vault.saved_trial().unwrap().registered);
            assert!(service.view().core_feature);
        }
    }

    #[test]
    fn case_30_no_registry_request_until_the_fallback_device_id_is_saved() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = trial_service(trial_record(HOUR, false), clock.clone());
        service.host.no_hardware_uuid.store(true, Ordering::SeqCst);
        *service.vault.trial_save_error.lock().unwrap() = Some("keychain locked".into());
        service.registry.started(NOW - HOUR, NOW);
        service.load();
        assert_eq!(service.registry.calls(), 0);
        assert_eq!(service.vault.saved_trial().unwrap().device_id, None);
        for step in [30, 60, 90] {
            clock.store(NOW + step, Ordering::SeqCst);
            service.woke();
            service.tick();
            assert_eq!(service.registry.calls(), 0, "no request with an unsaved id");
        }
        *service.vault.trial_save_error.lock().unwrap() = None;
        clock.store(NOW + 400, Ordering::SeqCst);
        service.woke();
        service.tick();
        let saved = service.vault.saved_trial().unwrap();
        let id = saved.device_id.expect("saved before the request");
        assert_eq!(
            *service.registry.devices.lock().unwrap(),
            vec![device_hash(APP_ID, &id)]
        );
    }

    fn legacy_trial_key(activated_ago: i64, kind: Option<&str>, product_id: &str) -> Stored {
        Stored {
            license: Some(Record {
                license_key: "KEY-TRIAL".into(),
                instance_id: "lki_KEY-TRIAL".into(),
                product_id: product_id.into(),
                kind: kind.map(str::to_owned),
                activated_at: NOW - activated_ago,
                last_success_at: NOW - DAY,
                last_success_local: NOW - DAY,
                last_observed_at: NOW - DAY,
                revoked: false,
                event_seq: 1,
            }),
            ..Stored::default()
        }
    }

    #[test]
    fn case_31_a_record_from_the_old_trial_keys_is_not_a_license() {
        let service = service(
            legacy_trial_key(4 * DAY, Some("trial"), "pdt_placeholder_openklack_trial"),
            Arc::new(AtomicI64::new(NOW)),
        );
        service
            .dodo
            .answer(Err(DodoError::Offline("offline".into())));
        service.load();
        assert_eq!(service.view().state, State::TrialEnded);
        assert!(!service.view().core_feature);
        assert!(service.host.blocked(), "no paid grace for a trial key");
        assert!(
            service.dodo.calls().is_empty(),
            "never checked as a license"
        );
        let trial = service.vault.saved_trial().unwrap();
        assert_eq!(
            trial.started_at,
            NOW - 4 * DAY,
            "its own start: no new time"
        );
        assert_eq!(service.registry.calls(), 0, "nothing left to register");
        assert!(
            service.vault.load().unwrap().license.is_some(),
            "kept, not deleted"
        );
        // A paid key still activates, and gives the trial key's slot back.
        assert_eq!(
            service.activate("KEY-PAID").map(|view| view.state),
            Ok(State::Licensed)
        );
        assert!(
            service
                .dodo
                .calls()
                .contains(&"deactivate KEY-TRIAL lki_KEY-TRIAL".to_string())
        );
        // A record for a product that isn't this app's paid one, a day in: trial rules, with
        // the registry deciding.
        let fresh = self::service(
            legacy_trial_key(DAY, None, "pdt_other"),
            Arc::new(AtomicI64::new(NOW)),
        );
        fresh.registry.started(NOW - DAY, NOW);
        fresh.load();
        assert_eq!(fresh.view().state, State::Trial { days_left: 2 });
        assert!(!fresh.host.blocked());
        assert!(fresh.dodo.calls().is_empty());
    }

    #[test]
    fn a_registry_answer_while_the_clock_is_behind_is_held_and_nothing_is_saved() {
        let clock = Arc::new(AtomicI64::new(NOW - 2 * DAY));
        let mono = Arc::new(AtomicI64::new(0));
        let vault = FakeVault::default();
        let original = trial_record(HOUR, false);
        *vault.trial.lock().unwrap() = Some(original.clone());
        let service = monotonic_service(
            vault,
            Arc::new(FakeJournal::default()),
            clock.clone(),
            mono.clone(),
        );
        // The registry remembers a start ten days ago: applied with a wrong clock it would be
        // converted wrongly and saved.
        service.registry.started(NOW - 10 * DAY, NOW);
        service.load();
        assert_eq!(service.view().state, State::ClockBehind);
        assert_eq!(service.registry.calls(), 1, "the answer arrives meanwhile");
        mono.store(HOUR, Ordering::SeqCst);
        service.tick();
        service.flush();
        assert!(
            service.vault.trial_writes().is_empty(),
            "every trial write is frozen"
        );
        assert_eq!(service.vault.saved_trial(), Some(original));
        assert!(
            service
                .engine
                .lock()
                .unwrap()
                .pending_registration
                .is_some()
        );
        assert_eq!(service.registry.calls(), 1, "held, not asked again");
        // Corrected: the held answer is converted with the right clock and saved.
        clock.store(NOW, Ordering::SeqCst);
        mono.store(2 * HOUR, Ordering::SeqCst);
        service.tick();
        let saved = service.vault.saved_trial().unwrap();
        assert!(saved.registered);
        assert_eq!(saved.started_at, NOW - 10 * DAY - 2 * HOUR);
        assert_eq!(saved.last_seen_at, NOW, "no time added while behind");
        assert_eq!(service.view().state, State::TrialEnded);
    }

    #[test]
    fn a_registration_counts_elapsed_time_once() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let mono = Arc::new(AtomicI64::new(0));
        let service = monotonic_service(
            FakeVault::default(),
            Arc::new(FakeJournal::default()),
            clock.clone(),
            mono.clone(),
        );
        service.load();
        assert_eq!(service.registry.calls(), 1);
        service.registry.started(NOW, NOW + HOUR);
        clock.store(NOW + HOUR, Ordering::SeqCst);
        mono.store(HOUR, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.registry.calls(), 2);
        let trial = service.vault.saved_trial().unwrap();
        assert!(trial.registered);
        assert_eq!(trial.started_at, NOW);
        let engine = service.engine.lock().unwrap();
        let TrialSlot::Present(current) = &engine.trial else {
            panic!("a trial is running")
        };
        assert_eq!(current.last_seen_at, NOW + HOUR, "an hour, not two");
        assert_eq!(
            engine.state(Moment {
                wall: NOW + HOUR,
                mono: HOUR
            }),
            State::Trial { days_left: 3 }
        );
    }

    #[test]
    fn a_wake_with_the_clock_behind_holds_the_trial_before_any_io() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let mono = Arc::new(AtomicI64::new(0));
        let vault = FakeVault::default();
        *vault.trial.lock().unwrap() = Some(trial_record(DAY, true));
        let service = monotonic_service(
            vault,
            Arc::new(FakeJournal::default()),
            clock.clone(),
            mono.clone(),
        );
        service.load();
        assert!(!service.host.blocked());
        // Slept an hour, and the clock came back two days early.
        clock.store(NOW - 2 * DAY, Ordering::SeqCst);
        mono.store(HOUR, Ordering::SeqCst);
        service.woke();
        assert!(service.host.blocked(), "restricted by the wake itself");
        assert_eq!(service.view().state, State::ClockBehind);
        assert_eq!(service.host.reason(), "Mac clock is behind");
        // Hours pass while the clock is behind: none of them count.
        mono.store(5 * HOUR, Ordering::SeqCst);
        service.tick();
        assert!(service.vault.trial_writes().is_empty());
        clock.store(NOW + HOUR, Ordering::SeqCst);
        mono.store(6 * HOUR, Ordering::SeqCst);
        service.tick();
        assert!(!service.host.blocked());
        let engine = service.engine.lock().unwrap();
        let TrialSlot::Present(trial) = &engine.trial else {
            panic!("a trial is running")
        };
        assert_eq!(
            trial.last_seen_at,
            NOW + HOUR,
            "the hour slept counts, the hold does not"
        );
    }

    #[test]
    fn quitting_never_waits_on_a_stuck_keychain_save() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = trial_service(trial_record(HOUR, true), clock.clone());
        service.load();
        clock.store(NOW + 600, Ordering::SeqCst);
        service.vault.trial_write_pause.arm();
        let started = std::time::Instant::now();
        assert!(!service.clone().flush_within(Duration::from_millis(200)));
        assert!(started.elapsed() < TIMEOUT, "quitting went on");
        service.vault.trial_write_pause.wait_entered();
        service.vault.trial_write_pause.open();
        clock.store(NOW + 1200, Ordering::SeqCst);
        assert!(service.clone().flush_within(TIMEOUT));
        assert_eq!(
            service.vault.saved_trial().unwrap().last_seen_at,
            NOW + 1200
        );
    }

    /// A small deterministic generator, so the random walk below is reproducible.
    struct Walk(u64);

    impl Walk {
        fn next(&mut self, bound: i64) -> i64 {
            self.0 = self
                .0
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            ((self.0 >> 33) % bound.max(1) as u64) as i64
        }
    }

    #[test]
    fn trial_time_holds_up_under_random_clocks_sleeps_save_failures_and_relaunches() {
        for seed in 1..=6 {
            let mut walk = Walk(seed);
            let clock = Arc::new(AtomicI64::new(NOW));
            let mut mono = Arc::new(AtomicI64::new(0));
            let vault = FakeVault::default();
            *vault.trial.lock().unwrap() = Some(trial_record(0, true));
            let mut service = monotonic_service(
                vault,
                Arc::new(FakeJournal::default()),
                clock.clone(),
                mono.clone(),
            );
            service.load();
            // Upper bound on the trial's moment: the latest wall time seen plus all monotonic
            // time since launch. Counting time twice would break it.
            let mut wall_max = NOW;
            let mut mono_total = 0;
            let mut last_elapsed = 0;
            for _ in 0..300 {
                let before = service.vault.trial_writes().len();
                let mut frozen_before = service.view().state == State::ClockBehind;
                match walk.next(7) {
                    0 => clock.store(
                        clock.load(Ordering::SeqCst) + walk.next(6 * DAY) - 3 * DAY,
                        Ordering::SeqCst,
                    ),
                    1 | 2 => {
                        let step = walk.next(6 * HOUR);
                        mono.fetch_add(step, Ordering::SeqCst);
                        clock.fetch_add(walk.next(step + 1), Ordering::SeqCst);
                        mono_total += step;
                    }
                    3 => {
                        let slept = walk.next(2 * DAY);
                        mono.fetch_add(slept, Ordering::SeqCst);
                        clock.fetch_add(slept, Ordering::SeqCst);
                        mono_total += slept;
                        service.woke();
                    }
                    4 => {
                        *service.vault.trial_save_error.lock().unwrap() =
                            (walk.next(2) == 0).then(|| "denied".to_string());
                    }
                    5 => {
                        service.flush();
                        mono = Arc::new(AtomicI64::new(walk.next(DAY)));
                        service = monotonic_service(
                            service.vault.reopen(),
                            Arc::new(FakeJournal::default()),
                            clock.clone(),
                            mono.clone(),
                        );
                        service.load();
                        let saved = service.vault.saved_trial().unwrap();
                        wall_max = saved.last_seen_at;
                        mono_total = 0;
                        last_elapsed = saved.last_seen_at - saved.started_at;
                        // A fresh vault handle counts its own writes.
                        frozen_before = false;
                    }
                    _ => {}
                }
                service.tick();
                wall_max = wall_max.max(clock.load(Ordering::SeqCst));
                let view = service.view();
                let (seen, started) = {
                    let engine = service.engine.lock().unwrap();
                    let TrialSlot::Present(trial) = &engine.trial else {
                        panic!("seed {seed}: the trial record is always present")
                    };
                    (trial.last_seen_at, trial.started_at)
                };
                let elapsed = seen - started;
                assert!(elapsed >= last_elapsed, "seed {seed}: elapsed went back");
                assert!(
                    seen <= wall_max + mono_total,
                    "seed {seed}: time counted twice"
                );
                assert_eq!(
                    service.host.blocked(),
                    !view.core_feature,
                    "seed {seed}: the window and playback disagree"
                );
                if view.core_feature {
                    assert!(
                        elapsed < TRIAL_LENGTH,
                        "seed {seed}: sound past the trial end"
                    );
                }
                if frozen_before && view.state == State::ClockBehind {
                    assert_eq!(
                        service.vault.trial_writes().len(),
                        before,
                        "seed {seed}: a write while the clock is behind"
                    );
                }
                let writes = service.vault.trial_writes();
                for pair in writes.windows(2) {
                    assert!(
                        pair[1].last_seen_at >= pair[0].last_seen_at,
                        "seed {seed}: a saved last_seen_at went back"
                    );
                }
                last_elapsed = elapsed;
            }
        }
    }

    #[test]
    fn a_check_with_nothing_due_releases_the_engine() {
        // The scheduler decides a check is due, an activation lands first, and the scheduler's
        // `begin_check` finds nothing due. The service must stay usable.
        let service = trial_service(trial_record(DAY, true), Arc::new(AtomicI64::new(NOW)));
        within_timeout({
            let service = service.clone();
            move || {
                service.load();
                service.activate("KEY-PAID").expect("activation");
                assert_eq!(service.check_once(false), Ok(State::Licensed));
                assert_eq!(service.view().state, State::Licensed);
                assert_eq!(service.state(), State::Licensed);
                service.tick();
                assert!(!service.host.blocked());
            }
        });
        assert_eq!(
            service.vault.load().unwrap().license.unwrap().license_key,
            "KEY-PAID"
        );
        assert!(
            service.vault.saved_trial().is_some(),
            "the trial record is kept"
        );
    }

    #[test]
    fn a_slow_writer_cannot_restore_a_replaced_record() {
        // A scheduler write of license A pauses mid-save while license B activates. Every write
        // is ordered, so B waits for A's write and lands last.
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_paid(0), clock.clone());
        service.load();
        service.vault.writes.lock().unwrap().clear();
        service.vault.write_pause.arm();
        clock.store(NOW + 10, Ordering::SeqCst);
        let ticker = {
            let service = service.clone();
            thread::spawn(move || service.tick())
        };
        service.vault.write_pause.wait_entered();
        let activator = {
            let service = service.clone();
            thread::spawn(move || service.activate("KEY-PAID-2").map(|view| view.state))
        };
        thread::sleep(Duration::from_millis(100));
        assert!(
            !activator.is_finished(),
            "activation waits for the older write"
        );
        service.vault.write_pause.open();
        ticker.join().unwrap();
        assert_eq!(activator.join().unwrap(), Ok(State::Licensed));
        let writes = service.vault.writes.lock().unwrap();
        assert_eq!(writes[0].license.as_ref().unwrap().license_key, "KEY-PAID");
        assert_eq!(
            writes.last().unwrap().license.as_ref().unwrap().license_key,
            "KEY-PAID-2"
        );
        assert_eq!(
            service.vault.load().unwrap().license.unwrap().license_key,
            "KEY-PAID-2"
        );
        assert!(
            service
                .dodo
                .calls()
                .contains(&"deactivate KEY-PAID lki_KEY-PAID".to_string())
        );
    }

    #[test]
    fn a_late_answer_for_a_removed_record_is_not_written_back() {
        let service = service(with_paid(25 * HOUR), Arc::new(AtomicI64::new(NOW)));
        service.load();
        service.dodo.answer(Ok(Validation {
            valid: false,
            server_time: Some(NOW),
        }));
        assert_eq!(service.check_once(true), Ok(State::Revoked));
        assert!(service.vault.load().unwrap().license.unwrap().revoked);
        service.remove().expect("removed");
        assert!(service.vault.load().unwrap().license.is_none());
        assert_eq!(
            service.check_once(true),
            Ok(State::Trial { days_left: 3 }),
            "nothing to check; a trial started over the absent record"
        );
        assert!(service.vault.load().unwrap().license.is_none());
    }

    #[test]
    fn sound_is_gated_until_the_record_has_been_read() {
        // A pending Keychain read must not leave an unknown entitlement audible, however long
        // it takes; the settings window shows a loading state meanwhile.
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_paid(HOUR), clock.clone());
        assert!(service.host.blocked());
        service.dodo.answer(Err(DodoError::Offline("down".into())));
        service.vault.read_pause.arm();
        let loading = {
            let service = service.clone();
            thread::spawn(move || service.load())
        };
        service.vault.read_pause.wait_entered();
        clock.store(NOW + 30 * DAY, Ordering::SeqCst);
        service.apply();
        assert!(!service.view().ready);
        assert!(service.host.blocked());
        service.vault.read_pause.open();
        loading.join().unwrap();
        assert!(service.view().ready);
        // Thirty days without a successful check: the saved paid record needs one.
        assert_eq!(service.view().state, State::CheckRequired);
        assert!(service.host.blocked());
        // The backoff retry succeeds and anchors time again: the next tick unlocks.
        clock.store(NOW + 30 * DAY + 61, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.view().state, State::Licensed);
        assert!(!service.host.blocked());
    }

    #[test]
    fn a_revocation_stops_sound_before_its_save_finishes() {
        let service = service(with_paid(HOUR), Arc::new(AtomicI64::new(NOW)));
        service.dodo.answer(Ok(Validation {
            valid: false,
            server_time: Some(NOW),
        }));
        service.vault.write_pause.arm();
        let worker = {
            let service = service.clone();
            thread::spawn(move || service.load())
        };
        service.vault.write_pause.wait_entered();
        assert_eq!(service.view().state, State::Revoked);
        assert!(service.host.blocked(), "blocked before the save completes");
        service.vault.write_pause.open();
        worker.join().unwrap();
        assert!(service.host.blocked());
        assert!(service.vault.load().unwrap().license.unwrap().revoked);
    }

    #[test]
    fn an_ended_trial_stops_sound_before_its_end_is_saved() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = trial_service(trial_record(TRIAL_LENGTH - 60, true), clock.clone());
        service.load();
        assert!(!service.host.blocked());
        clock.store(NOW + 60, Ordering::SeqCst);
        service.vault.trial_write_pause.arm();
        let worker = {
            let service = service.clone();
            thread::spawn(move || service.tick())
        };
        service.vault.trial_write_pause.wait_entered();
        assert_eq!(service.view().state, State::TrialEnded);
        assert!(service.host.blocked(), "blocked before the save completes");
        service.vault.trial_write_pause.open();
        worker.join().unwrap();
        assert!(service.host.blocked());
        assert_eq!(service.vault.saved_trial().unwrap().last_seen_at, NOW + 60);
    }

    #[test]
    fn a_stale_gate_update_cannot_reenable_a_removed_license() {
        // An old permissive decision, delayed on its way to the audio engine, arrives after
        // Remove this Mac has blocked playback. Its revision is older, so it is ignored.
        let service = service(with_paid(HOUR), Arc::new(AtomicI64::new(NOW)));
        *service.vault.trial.lock().unwrap() = Some(trial_record(TRIAL_LENGTH + DAY, true));
        service.load();
        assert!(!service.host.blocked());
        service.host.unlock_pause.arm();
        let old = {
            let service = service.clone();
            thread::spawn(move || service.apply())
        };
        service.host.unlock_pause.wait_entered();
        service.remove().expect("removed");
        assert!(service.host.blocked());
        service.host.unlock_pause.open();
        old.join().unwrap();
        assert_eq!(service.view().state, State::TrialEnded);
        assert!(service.host.blocked(), "the stale unlock was ignored");
        // A stale unlock cannot undo a revocation either.
        let revoked = self::service(with_paid(HOUR), Arc::new(AtomicI64::new(NOW)));
        revoked.load();
        revoked.host.unlock_pause.arm();
        let old = {
            let revoked = revoked.clone();
            thread::spawn(move || revoked.apply())
        };
        revoked.host.unlock_pause.wait_entered();
        revoked.dodo.answer(Ok(Validation {
            valid: false,
            server_time: Some(NOW),
        }));
        assert_eq!(revoked.check_once(true), Ok(State::Revoked));
        revoked.host.unlock_pause.open();
        old.join().unwrap();
        assert!(revoked.host.blocked());
    }

    #[test]
    fn an_unlock_waits_for_the_save_that_justifies_it() {
        // CheckRequired → Licensed: playback resumes only once the fresh record is durable.
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_paid(8 * DAY), clock);
        service.vault.write_pause.arm();
        let worker = {
            let service = service.clone();
            thread::spawn(move || service.load())
        };
        service.vault.write_pause.wait_entered();
        // The window shows what playback allows: the saved record still needs a check.
        assert_eq!(service.view().state, State::CheckRequired);
        assert!(!service.view().core_feature);
        assert_eq!(service.engine.lock().unwrap().state(NOW), State::Licensed);
        assert!(service.host.blocked(), "not yet saved");
        service.vault.write_pause.open();
        worker.join().unwrap();
        assert!(!service.host.blocked());
    }

    #[test]
    fn a_registration_unlocks_only_once_it_is_saved() {
        // Past the offline limit, the registry's answer is a grant: saved first, then unlocked.
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = trial_service(trial_record(DAY + HOUR, false), clock);
        service.registry.started(NOW - DAY - HOUR, NOW);
        service.vault.trial_write_pause.arm();
        let worker = {
            let service = service.clone();
            thread::spawn(move || service.load())
        };
        service.vault.trial_write_pause.wait_entered();
        assert_eq!(service.view().state, State::TrialOffline);
        assert!(service.host.blocked(), "not yet saved");
        service.vault.trial_write_pause.open();
        worker.join().unwrap();
        assert!(!service.host.blocked());
        assert_eq!(service.view().state, State::Trial { days_left: 2 });
        // If that save fails, the Mac stays off and the write is retried.
        let failing = trial_service(
            trial_record(DAY + HOUR, false),
            Arc::new(AtomicI64::new(NOW)),
        );
        failing.registry.started(NOW - DAY - HOUR, NOW);
        *failing.vault.trial_save_error.lock().unwrap() = Some("denied".into());
        failing.load();
        // The window agrees with playback: the saved record is still at its offline limit.
        let view = failing.view();
        assert_eq!(view.state, State::TrialOffline);
        assert!(!view.core_feature);
        assert!(view.last_error.unwrap().contains("denied"));
        assert!(failing.host.blocked());
        *failing.vault.trial_save_error.lock().unwrap() = None;
        failing.tick();
        assert!(!failing.host.blocked());
        assert!(failing.vault.saved_trial().unwrap().registered);
    }

    #[test]
    fn launch_checks_regardless_of_recency_and_recovery_runs_once_per_outage() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_paid(HOUR), clock.clone());
        service.dodo.answer(Err(DodoError::Offline("down".into())));
        service.load();
        assert_eq!(service.dodo.calls().len(), 1, "the launch check ran");
        assert_eq!(
            service.state(),
            State::Licensed,
            "a network failure never revokes"
        );
        // Backoff is a minute away and the probe says the network is still down.
        clock.store(NOW + 10, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.dodo.calls().len(), 1);
        // Back: the next poll runs the check ahead of the backoff, once.
        service.host.reachable.store(true, Ordering::SeqCst);
        clock.store(NOW + 20, Ordering::SeqCst);
        service.tick();
        assert_eq!(
            service.dodo.calls().len(),
            1,
            "polled at most every five minutes"
        );
        service
            .dodo
            .answer(Err(DodoError::Offline("still down".into())));
        let poll = REACHABILITY_POLL.as_secs() as i64;
        clock.store(NOW + poll + 1, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.dodo.calls().len(), 2);
        // Reachable but the check failed again: no further recovery checks until the probe has
        // seen the network down again; the backoff (now two minutes) decides.
        clock.store(NOW + 2 * poll + 2, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.dodo.calls().len(), 3, "the backoff retry ran");
        assert_eq!(service.engine.lock().unwrap().schedule.failures, 0);
        assert_eq!(
            service.registry.calls(),
            0,
            "a licensed Mac never registers"
        );
    }

    #[test]
    fn server_errors_never_trigger_recovery_checks() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_paid(HOUR), clock.clone());
        service.dodo.answer(Err(DodoError::ServerError(503)));
        service.load();
        assert_eq!(service.dodo.calls().len(), 1);
        service.host.reachable.store(true, Ordering::SeqCst);
        for step in 1..=3 {
            clock.store(
                NOW + step * REACHABILITY_POLL.as_secs() as i64 / 2,
                Ordering::SeqCst,
            );
            service.tick();
        }
        // Only the backoff retry (one minute after the failure) ran.
        assert_eq!(service.dodo.calls().len(), 2);
    }

    #[test]
    fn a_record_that_cannot_be_saved_leaves_the_trial_and_frees_the_slot() {
        let service = trial_service(trial_record(DAY, true), Arc::new(AtomicI64::new(NOW)));
        service.load();
        *service.vault.save_error.lock().unwrap() = Some("keychain locked".into());
        let error = service.activate("KEY-PAID").unwrap_err();
        assert!(error.contains("keychain locked"), "{error}");
        assert_eq!(service.state(), State::Trial { days_left: 2 });
        assert_eq!(
            service.dodo.calls(),
            [
                "activate KEY-PAID Mac".to_string(),
                "deactivate KEY-PAID lki_KEY-PAID".to_string()
            ]
        );
        assert!(!service.host.blocked(), "the trial keeps playing");
    }

    #[test]
    fn owed_cleanups_stop_at_the_first_rate_limit_and_retry_every_five_minutes() {
        struct LimitedDodo(FakeDodo);
        impl Dodo for LimitedDodo {
            fn activate(&self, key: &str, name: &str) -> Result<Activation, DodoError> {
                self.0.activate(key, name)
            }
            fn validate(&self, key: &str, instance: &str) -> Result<Validation, DodoError> {
                self.0.validate(key, instance)
            }
            fn deactivate(&self, key: &str, instance: &str) -> Result<(), DodoError> {
                self.0.deactivate(key, instance)?;
                Err(DodoError::RateLimited { retry_after: 60 })
            }
        }
        let clock = Arc::new(AtomicI64::new(NOW));
        let clock_copy = clock.clone();
        let limited: Service<LimitedDodo, FakeRegistry, FakeVault, FakeHost, Arc<FakeJournal>> =
            Service::new(
                LimitedDodo(FakeDodo::paid()),
                FakeRegistry::default(),
                FakeVault::default(),
                FakeHost::default(),
                Arc::new(FakeJournal::default()),
                Box::new(move || clock_copy.load(Ordering::SeqCst)),
                Box::new(|| 0),
            );
        limited.load();
        {
            let mut engine = limited.engine.lock().unwrap();
            for id in ["a", "b", "c"] {
                engine.remember_cleanup(Probe {
                    license_key: "K".into(),
                    instance_id: id.into(),
                });
            }
        }
        limited.tick();
        assert_eq!(limited.dodo.0.calls(), vec!["deactivate K a".to_string()]);
        assert_eq!(
            limited.engine.lock().unwrap().stored.pending_cleanups.len(),
            3
        );
        assert_eq!(
            limited.vault.load().unwrap().pending_cleanups.len(),
            3,
            "owed deactivations survive a restart"
        );
        let retry = CLEANUP_RETRY.as_secs() as i64;
        clock.store(NOW + 61, Ordering::SeqCst);
        limited.tick();
        assert_eq!(
            limited.dodo.0.calls().len(),
            1,
            "retried every five minutes"
        );
        clock.store(NOW + retry, Ordering::SeqCst);
        limited.tick();
        assert_eq!(limited.dodo.0.calls().len(), 2, "one more, then held again");
    }

    #[test]
    fn a_failed_save_is_retried_every_tick_and_shown_as_a_storage_error() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_paid(HOUR), clock.clone());
        service.load();
        *service.vault.save_error.lock().unwrap() = Some("keychain locked".into());
        service.dodo.answer(Ok(Validation {
            valid: false,
            server_time: Some(NOW),
        }));
        assert_eq!(service.check_once(true), Ok(State::Revoked));
        assert!(service.host.blocked(), "revoked in memory at once");
        assert!(!service.vault.load().unwrap().license.unwrap().revoked);
        assert!(
            service
                .view()
                .last_error
                .unwrap()
                .contains("keychain locked")
        );
        clock.store(NOW + 5, Ordering::SeqCst);
        service.tick();
        assert!(!service.vault.load().unwrap().license.unwrap().revoked);
        *service.vault.save_error.lock().unwrap() = None;
        clock.store(NOW + 10, Ordering::SeqCst);
        service.tick();
        assert!(service.vault.load().unwrap().license.unwrap().revoked);
        assert_eq!(service.view().last_error, None);
    }

    #[test]
    fn a_grant_takes_effect_only_once_its_record_is_saved() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_paid(8 * DAY), clock.clone());
        service
            .dodo
            .answer(Err(DodoError::Offline("offline".into())));
        service.load();
        assert!(service.host.blocked());
        *service.vault.save_error.lock().unwrap() = Some("denied".into());
        service.dodo.answer(Ok(Validation {
            valid: true,
            server_time: Some(NOW),
        }));
        assert_eq!(service.check_once(true), Ok(State::Licensed));
        assert!(service.host.blocked(), "not durable yet");
        assert!(service.view().last_error.unwrap().contains("denied"));
        assert_eq!(
            service
                .vault
                .load()
                .unwrap()
                .license
                .unwrap()
                .last_success_at,
            NOW - 8 * DAY
        );
        // The write is retried every tick; once it lands, playback resumes.
        clock.store(NOW + 5, Ordering::SeqCst);
        service.tick();
        assert!(service.host.blocked());
        *service.vault.save_error.lock().unwrap() = None;
        clock.store(NOW + 10, Ordering::SeqCst);
        service.tick();
        assert!(!service.host.blocked());
        assert_eq!(service.view().last_error, None);
    }

    #[test]
    fn a_clock_ahead_of_the_server_does_not_check_every_tick() {
        let clock = Arc::new(AtomicI64::new(NOW + 2 * DAY));
        let service = service(with_paid(0), clock.clone());
        service.load();
        service.tick();
        service.tick();
        let validations = service
            .dodo
            .calls()
            .iter()
            .filter(|call| call.starts_with("validate"))
            .count();
        assert_eq!(validations, 1, "the launch check only");
        assert!(!service.engine.lock().unwrap().check_due(NOW + 2 * DAY + 1));
    }

    #[test]
    fn an_unreadable_record_is_a_storage_error_that_is_retried() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_paid(HOUR), clock.clone());
        *service.vault.load_error.lock().unwrap() = Some("keychain denied".into());
        service.load();
        let view = service.view();
        assert!(!view.ready, "an unreadable record is not an empty one");
        assert!(view.last_error.unwrap().contains("keychain denied"));
        assert!(service.host.blocked());
        assert!(service.dodo.calls().is_empty(), "nothing to check yet");
        assert!(
            service.vault.trial_writes().is_empty(),
            "no trial over an unreadable license record"
        );
        // Retried with backoff, not every tick.
        clock.store(NOW + 10, Ordering::SeqCst);
        service.tick();
        assert!(!service.view().ready);
        *service.vault.load_error.lock().unwrap() = None;
        clock.store(NOW + LOAD_RETRY_MIN, Ordering::SeqCst);
        service.tick();
        let view = service.view();
        assert!(view.ready);
        assert_eq!(view.last_error, None);
        assert_eq!(view.state, State::Licensed);
        assert!(!service.host.blocked());
        assert_eq!(
            service.vault.load().unwrap().license.unwrap().license_key,
            "KEY-PAID",
            "the record was never overwritten"
        );
    }

    #[test]
    fn a_revocation_survives_a_restart_even_when_its_save_failed() {
        let service = service(with_paid(0), Arc::new(AtomicI64::new(NOW)));
        service.load();
        *service.vault.save_error.lock().unwrap() = Some("denied".into());
        service.dodo.answer(Ok(Validation {
            valid: false,
            server_time: Some(NOW),
        }));
        assert_eq!(service.check_once(true), Ok(State::Revoked));
        assert!(service.host.blocked());
        let hash = instance_hash("lki_KEY-PAID");
        assert!(
            service.journal.entry(&hash).unwrap().is_some(),
            "journalled before the save"
        );
        assert!(!service.vault.load().unwrap().license.unwrap().revoked);
        // Restart offline over the same stores: the journal wins over the Keychain record.
        let restarted = service_with(
            service.vault.reopen(),
            service.journal.clone(),
            Arc::new(AtomicI64::new(NOW + HOUR)),
        );
        restarted
            .dodo
            .answer(Err(DodoError::Offline("offline".into())));
        restarted.load();
        assert_eq!(restarted.view().state, State::Revoked);
        assert!(restarted.host.blocked());
        // Once the revoked record is saved, the note is no longer needed.
        restarted.tick();
        assert!(restarted.vault.load().unwrap().license.unwrap().revoked);
        assert!(restarted.journal.entry(&hash).unwrap().is_none());
        // `valid: true` for the same activation clears everything.
        restarted.dodo.answer(Ok(Validation {
            valid: true,
            server_time: Some(NOW + HOUR),
        }));
        assert_eq!(restarted.check_once(true), Ok(State::Licensed));
        assert!(restarted.journal.entry(&hash).unwrap().is_none());
        assert!(!restarted.host.blocked());
    }

    #[test]
    fn the_journal_is_cleared_when_the_activation_is_replaced_or_removed() {
        let service = service(with_paid(0), Arc::new(AtomicI64::new(NOW)));
        service.load();
        let hash = instance_hash("lki_KEY-PAID");
        service.journal.revoke(&hash, 2).unwrap();
        service.activate("KEY-PAID-2").unwrap();
        assert!(service.journal.entry(&hash).unwrap().is_none());
        let hash2 = instance_hash("lki_KEY-PAID-2");
        service.journal.revoke(&hash2, 2).unwrap();
        service.remove().unwrap();
        assert!(service.journal.entry(&hash2).unwrap().is_none());
        // Remove whose Keychain save fails: the tombstone stays and an offline restart stays
        // off; once the cleared record is saved, the tombstone goes.
        let service = self::service(with_paid(0), Arc::new(AtomicI64::new(NOW)));
        service.load();
        *service.vault.save_error.lock().unwrap() = Some("denied".into());
        service.remove().unwrap();
        let hash = instance_hash("lki_KEY-PAID");
        assert!(service.journal.entry(&hash).unwrap().is_some(), "tombstone");
        assert!(service.vault.load().unwrap().license.is_some());
        let restarted = service_with(
            service.vault.reopen(),
            service.journal.clone(),
            Arc::new(AtomicI64::new(NOW + 10)),
        );
        restarted
            .dodo
            .answer(Err(DodoError::Offline("offline".into())));
        restarted.load();
        assert!(restarted.host.blocked());
        assert_eq!(restarted.view().state, State::Revoked);
        *service.vault.save_error.lock().unwrap() = None;
        service.tick();
        assert!(service.vault.load().unwrap().license.is_none());
        assert!(service.journal.entry(&hash).unwrap().is_none());
        // A stale entry the durable record has already caught up with is ignored and dropped.
        let vault = FakeVault::default();
        *vault.stored.lock().unwrap() = with_paid(0);
        let journal = Arc::new(FakeJournal::default());
        journal.revoke(&hash, 1).unwrap();
        let fresh = service_with(vault, journal.clone(), Arc::new(AtomicI64::new(NOW)));
        fresh.load();
        assert_eq!(fresh.view().state, State::Licensed);
        assert!(journal.entry(&hash).unwrap().is_none());
        assert!(
            !instance_hash("lki_KEY-PAID").contains("KEY"),
            "hashed, never the id"
        );
        assert_eq!(instance_hash("a").len(), 64);
    }

    #[test]
    fn a_journal_that_cannot_be_written_still_locks_and_is_retried() {
        struct FailingJournal(Arc<FakeJournal>, AtomicBool);
        impl Journal for FailingJournal {
            fn entry(&self, hash: &str) -> Result<Option<u64>, String> {
                self.0.entry(hash)
            }
            fn revoke(&self, hash: &str, seq: u64) -> Result<(), String> {
                if self.1.load(Ordering::SeqCst) {
                    return Err("disk full".into());
                }
                self.0.revoke(hash, seq)
            }
            fn clear(&self, hash: &str, up_to_seq: u64) -> Result<(), String> {
                self.0.clear(hash, up_to_seq)
            }
        }
        let inner = Arc::new(FakeJournal::default());
        let vault = FakeVault::default();
        *vault.stored.lock().unwrap() = with_paid(0);
        let service: Service<FakeDodo, FakeRegistry, FakeVault, FakeHost, FailingJournal> =
            Service::new(
                FakeDodo::paid(),
                FakeRegistry::default(),
                vault,
                FakeHost::default(),
                FailingJournal(inner.clone(), AtomicBool::new(true)),
                Box::new(|| NOW),
                Box::new(|| 0),
            );
        service.load();
        *service.vault.save_error.lock().unwrap() = Some("denied".into());
        service.dodo.answer(Ok(Validation {
            valid: false,
            server_time: Some(NOW),
        }));
        assert_eq!(service.check_once(true), Ok(State::Revoked));
        assert!(service.host.blocked(), "locked in memory regardless");
        assert!(
            service.view().last_error.is_some(),
            "a storage error is shown"
        );
        let hash = instance_hash("lki_KEY-PAID");
        assert!(inner.entry(&hash).unwrap().is_none());
        service.journal.1.store(false, Ordering::SeqCst);
        service.tick();
        assert!(
            inner.entry(&hash).unwrap().is_some(),
            "retried on the next tick"
        );
    }

    #[test]
    fn a_failed_renewal_save_keeps_a_durable_paid_grant_playing() {
        let service = service(with_paid(HOUR), Arc::new(AtomicI64::new(NOW)));
        service.load();
        assert!(!service.host.blocked());
        *service.vault.save_error.lock().unwrap() = Some("denied".into());
        assert_eq!(service.check_once(true), Ok(State::Licensed));
        assert_eq!(service.view().state, State::Licensed);
        assert!(
            !service.host.blocked(),
            "the saved record already grants access"
        );
        assert!(service.view().last_error.unwrap().contains("denied"));
        // An unsaved revocation still counts at once.
        service.dodo.answer(Ok(Validation {
            valid: false,
            server_time: Some(NOW),
        }));
        assert_eq!(service.check_once(true), Ok(State::Revoked));
        assert!(service.host.blocked());
    }

    #[test]
    fn a_clock_behind_the_server_cannot_make_a_revocation_look_old() {
        let clock = Arc::new(AtomicI64::new(NOW - 2 * DAY));
        let service = service(with_paid(0), clock.clone());
        service.load();
        *service.vault.save_error.lock().unwrap() = Some("denied".into());
        service.dodo.answer(Ok(Validation {
            valid: false,
            server_time: Some(NOW),
        }));
        assert_eq!(service.check_once(true), Ok(State::Revoked));
        assert!(service.host.blocked());
        let hash = instance_hash("lki_KEY-PAID");
        assert_eq!(
            service.journal.entry(&hash).unwrap(),
            Some(3),
            "sequence, not a clock"
        );
        let restart = service_with(service.vault.reopen(), service.journal.clone(), clock);
        restart
            .dodo
            .answer(Err(DodoError::Offline("offline".into())));
        restart.load();
        assert_eq!(restart.view().state, State::Revoked);
        assert!(restart.host.blocked());
        // The forced revocation was saved by the launch check's persist, so the note is done.
        assert!(restart.vault.load().unwrap().license.unwrap().revoked);
        assert!(restart.journal.entry(&hash).unwrap().is_none());
        // Back online, `valid: true` moves the record past the entry and unlocks; if that save
        // failed the Mac would stay locked until the next successful check.
        restart.dodo.answer(Ok(Validation {
            valid: true,
            server_time: Some(NOW + DAY),
        }));
        assert_eq!(restart.check_once(true), Ok(State::Licensed));
        assert!(!restart.host.blocked());
        assert!(restart.journal.entry(&hash).unwrap().is_none());
    }

    fn temp_journal(contents: &[u8]) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "openklack-journal-{}.json",
            crate::library::unique_suffix()
        ));
        std::fs::write(&path, contents).unwrap();
        path
    }

    fn aside_copies(path: &std::path::Path) -> Vec<std::path::PathBuf> {
        let stem = path.file_stem().unwrap().to_string_lossy().into_owned();
        std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .filter(|candidate| {
                let name = candidate.file_name().unwrap().to_string_lossy();
                name.starts_with(&stem) && name.contains("corrupt")
            })
            .collect()
    }

    fn corrupt_journal_service(
        path: &std::path::Path,
    ) -> Service<FakeDodo, FakeRegistry, FakeVault, FakeHost, FileJournal> {
        let vault = FakeVault::default();
        *vault.stored.lock().unwrap() = with_paid(HOUR);
        let service = Service::new(
            FakeDodo::paid(),
            FakeRegistry::default(),
            vault,
            FakeHost::default(),
            FileJournal::new(path.to_path_buf()),
            Box::new(|| NOW),
            Box::new(|| 0),
        );
        service.apply();
        service
    }

    #[test]
    fn an_unreadable_journal_keeps_sound_off_until_dodo_answers_and_rebuilds_it() {
        // Offline: the saved record is held, playback stays off, the error shows, nothing is
        // overwritten, and every retry validates again.
        let path = temp_journal(b"invalid json");
        let service = corrupt_journal_service(&path);
        service
            .dodo
            .answer(Err(DodoError::Offline("offline".into())));
        service.load();
        let view = service.view();
        assert!(
            view.ready,
            "the Keychain record is kept as a recovery candidate"
        );
        assert!(view.journal_unreadable);
        assert!(view.last_error.unwrap().contains("journal"));
        assert!(service.host.blocked());
        assert_eq!(
            service.dodo.calls().len(),
            1,
            "validated for the stored key"
        );
        assert_eq!(
            std::fs::read(&path).unwrap(),
            b"invalid json",
            "never overwritten"
        );
        service
            .dodo
            .answer(Err(DodoError::Offline("offline".into())));
        service.check_once(true).unwrap_err();
        assert!(service.host.blocked());
        assert_eq!(service.dodo.calls().len(), 2, "Try again validates again");
        // Online: `valid: true` rebuilds the journal, keeps the corrupt copy aside and unlocks.
        assert_eq!(service.check_once(true), Ok(State::Licensed));
        assert!(!service.view().journal_unreadable);
        assert_eq!(service.view().last_error, None);
        assert!(!service.host.blocked());
        assert!(path.exists(), "a journal is always present");
        let aside = aside_copies(&path);
        assert_eq!(aside.len(), 1, "kept aside for inspection");
        assert_eq!(std::fs::read(&aside[0]).unwrap(), b"invalid json");
        assert_eq!(FileJournal::new(path.clone()).entry("x").unwrap(), None);
        std::fs::remove_file(&path).unwrap();
        std::fs::remove_file(&aside[0]).unwrap();
        // Online with `valid: false`: the revocation is recorded in a rebuilt journal.
        let path = temp_journal(b"{");
        let service = corrupt_journal_service(&path);
        service.dodo.answer(Ok(Validation {
            valid: false,
            server_time: Some(NOW),
        }));
        service.load();
        assert_eq!(service.view().state, State::Revoked);
        assert!(service.host.blocked());
        let hash = instance_hash("lki_KEY-PAID");
        // The revoked record was saved, so the note has been cleared again; the file is valid.
        assert_eq!(FileJournal::new(path.clone()).entry(&hash).unwrap(), None);
        assert!(service.vault.load().unwrap().license.unwrap().revoked);
        for aside in aside_copies(&path) {
            std::fs::remove_file(aside).unwrap();
        }
        std::fs::remove_file(&path).unwrap();
        // A missing file is simply empty.
        assert_eq!(FileJournal::new(path).entry(&hash).unwrap(), None);
    }

    #[test]
    fn journal_notes_are_conditional_on_their_sequence() {
        let path = temp_journal(b"{}");
        let journal = FileJournal::new(path.clone());
        journal.revoke("h", 3).unwrap();
        journal.revoke("h", 2).unwrap();
        assert_eq!(
            journal.entry("h").unwrap(),
            Some(3),
            "an older note never replaces a newer"
        );
        journal.clear("h", 2).unwrap();
        assert_eq!(
            journal.entry("h").unwrap(),
            Some(3),
            "a clear up to 2 leaves 3"
        );
        journal.clear("h", 3).unwrap();
        assert_eq!(journal.entry("h").unwrap(), None);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn a_delayed_clear_cannot_erase_a_newer_revocation() {
        struct RetryJournal {
            inner: Arc<FakeJournal>,
            fail_clear: AtomicBool,
        }
        impl Journal for Arc<RetryJournal> {
            fn entry(&self, hash: &str) -> Result<Option<u64>, String> {
                self.inner.entry(hash)
            }
            fn revoke(&self, hash: &str, seq: u64) -> Result<(), String> {
                self.inner.revoke(hash, seq)
            }
            fn clear(&self, hash: &str, up_to_seq: u64) -> Result<(), String> {
                if self.fail_clear.load(Ordering::SeqCst) {
                    Err("denied".into())
                } else {
                    self.inner.clear(hash, up_to_seq)
                }
            }
        }
        type RetryService = Service<FakeDodo, FakeRegistry, FakeVault, FakeHost, Arc<RetryJournal>>;
        let vault = FakeVault::default();
        *vault.stored.lock().unwrap() = with_paid(HOUR);
        let journal = Arc::new(RetryJournal {
            inner: Arc::new(FakeJournal::default()),
            fail_clear: AtomicBool::new(true),
        });
        let service: RetryService = Service::new(
            FakeDodo::paid(),
            FakeRegistry::default(),
            vault,
            FakeHost::default(),
            journal.clone(),
            Box::new(|| NOW),
            Box::new(|| 0),
        );
        service.apply();
        // `valid: true` is saved, but its journal clear is queued for retry.
        service.load();
        assert!(!service.meta.lock().unwrap().journal_retry.is_empty());
        journal.fail_clear.store(false, Ordering::SeqCst);
        *service.vault.save_error.lock().unwrap() = Some("denied".into());
        service.dodo.answer(Ok(Validation {
            valid: false,
            server_time: Some(NOW),
        }));
        assert_eq!(service.check_once(true), Ok(State::Revoked));
        let hash = instance_hash("lki_KEY-PAID");
        assert_eq!(journal.entry(&hash).unwrap(), Some(3));
        // The save keeps failing; the old clear (up to sequence 2) is retried and must not touch
        // the newer note.
        service.tick();
        assert_eq!(journal.entry(&hash).unwrap(), Some(3));
        assert!(service.host.blocked());
        let restart: RetryService = Service::new(
            FakeDodo::paid(),
            FakeRegistry::default(),
            service.vault.reopen(),
            FakeHost::default(),
            journal.clone(),
            Box::new(|| NOW),
            Box::new(|| 0),
        );
        restart.apply();
        restart
            .dodo
            .answer(Err(DodoError::Offline("offline".into())));
        restart.load();
        assert_eq!(restart.view().state, State::Revoked);
        assert!(restart.host.blocked());
        // Queued ops coalesce per activation: a newer op supersedes an older one.
        {
            let mut meta = service.meta.lock().unwrap();
            meta.journal_retry.clear();
            RetryService::queue_journal_op(&mut meta, "h".into(), JournalOp::Revoke(5));
            RetryService::queue_journal_op(&mut meta, "h".into(), JournalOp::Clear(4));
            assert_eq!(meta.journal_retry.get("h"), Some(&JournalOp::Revoke(5)));
            RetryService::queue_journal_op(&mut meta, "h".into(), JournalOp::Clear(6));
            assert_eq!(meta.journal_retry.get("h"), Some(&JournalOp::Clear(6)));
        }
    }

    #[test]
    fn a_late_load_cannot_overwrite_a_newer_record() {
        struct SnapshotVault {
            inner: FakeVault,
            pause: Pause,
        }
        impl Vault for SnapshotVault {
            fn load(&self) -> Result<Stored, String> {
                let snapshot = self.inner.load()?;
                self.pause.enter();
                Ok(snapshot)
            }
            fn save(&self, stored: &Stored) -> Result<(), String> {
                self.inner.save(stored)
            }
            fn load_trial(&self) -> Result<Option<TrialRecord>, String> {
                self.inner.load_trial()
            }
            fn save_trial(&self, trial: &TrialRecord) -> Result<(), String> {
                self.inner.save_trial(trial)
            }
        }
        let vault = SnapshotVault {
            inner: FakeVault::default(),
            pause: Pause::default(),
        };
        *vault.inner.trial.lock().unwrap() = Some(trial_record(DAY, true));
        let service: Arc<
            Service<FakeDodo, FakeRegistry, SnapshotVault, FakeHost, Arc<FakeJournal>>,
        > = Arc::new(Service::new(
            FakeDodo::paid(),
            FakeRegistry::default(),
            vault,
            FakeHost::default(),
            Arc::new(FakeJournal::default()),
            Box::new(|| NOW),
            Box::new(|| 0),
        ));
        service.apply();
        service.vault.pause.arm();
        let old_load = {
            let service = service.clone();
            thread::spawn(move || service.load())
        };
        service.vault.pause.wait_entered();
        // A manual retry while the first read is still in flight does nothing.
        service.load();
        assert!(!service.view().ready, "single-flight");
        service.vault.pause.open();
        old_load.join().unwrap();
        assert!(service.view().ready);
        // A read that started before an activation is discarded when it lands afterwards.
        service.meta.lock().unwrap().ready = false;
        service.vault.pause.arm();
        let old_load = {
            let service = service.clone();
            thread::spawn(move || service.load())
        };
        service.vault.pause.wait_entered();
        service.activate("KEY-PAID").unwrap();
        assert_eq!(
            service
                .vault
                .inner
                .load()
                .unwrap()
                .license
                .unwrap()
                .license_key,
            "KEY-PAID"
        );
        service.vault.pause.open();
        old_load.join().unwrap();
        assert_eq!(service.view().state, State::Licensed);
        assert_eq!(
            service
                .vault
                .inner
                .load()
                .unwrap()
                .license
                .unwrap()
                .license_key,
            "KEY-PAID"
        );
        assert!(
            !service.view().ready,
            "the discarded read did not mark anything ready"
        );
    }

    #[test]
    fn the_scheduler_sleeps_no_longer_than_the_next_load_retry() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_paid(HOUR), clock);
        *service.vault.load_error.lock().unwrap() = Some("keychain denied".into());
        service.load();
        let wait = service.next_wait();
        assert_eq!(wait, Duration::from_secs(LOAD_RETRY_MIN as u64));
    }

    #[test]
    fn activation_links_carry_only_the_key() {
        let parse = |link: &str| parse_activation_link(&url::Url::parse(link).unwrap());
        assert_eq!(
            parse("openklack://activate?key=ABCD-1234"),
            Some("ABCD-1234".into())
        );
        assert_eq!(
            parse("openklack://activate?key=%20ABCD-1234%20&kind=trial&utm=x"),
            Some("ABCD-1234".into())
        );
        assert_eq!(parse("openklack://activate?kind=trial"), None);
        assert_eq!(parse("openklack://activate?key=bad%20key"), None);
        assert_eq!(parse("openklack://settings?key=ABCD"), None);
        assert_eq!(parse("https://activate/?key=ABCD"), None);
        let service = service(with_paid(HOUR), Arc::new(AtomicI64::new(NOW)));
        service.opened(&[url::Url::parse("openklack://activate?key=K1&kind=trial").unwrap()]);
        assert_eq!(service.view().pending_key.as_deref(), Some("K1"));
        assert_eq!(service.dismiss_key().pending_key, None);
    }

    /// Needs a registry on `OPENKLACK_TRIAL_REGISTRY_URL` that answers `200`, then `429` with
    /// `Retry-After: 120`, then `500`; run with `--ignored` against a local stub.
    #[test]
    #[ignore = "needs a local trial registry stub"]
    fn the_http_registry_speaks_the_contract() {
        let registry = HttpRegistry::new().unwrap();
        let device = device_hash(APP_ID, HARDWARE_UUID);
        let answer = registry.register(&device).expect("200");
        assert_eq!(answer.started_at, 1_789_041_600);
        assert!(answer.now > answer.started_at);
        assert_eq!(
            registry.register(&device),
            Err(RegistryError::RateLimited { retry_after: 120 })
        );
        assert!(matches!(
            registry.register(&device),
            Err(RegistryError::Unexpected(_))
        ));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_hardware_uuid_is_read_from_iokit() {
        let output = std::process::Command::new("ioreg")
            .args(["-rd1", "-c", "IOPlatformExpertDevice"])
            .output()
            .expect("ioreg runs on macOS");
        let listing = String::from_utf8_lossy(&output.stdout);
        let expected = listing
            .lines()
            .find(|line| line.contains("\"IOPlatformUUID\""))
            .and_then(|line| line.rsplit('"').nth(1))
            .expect("ioreg lists the platform UUID");
        assert_eq!(platform_uuid().as_deref(), Some(expected));
        assert_ne!(
            device_hash(APP_ID, expected),
            expected,
            "only the hash is ever sent"
        );
    }

    #[test]
    fn the_monotonic_clock_moves_forward() {
        let first = monotonic_now();
        thread::sleep(Duration::from_millis(1100));
        let second = monotonic_now();
        assert!(second > first, "{first} then {second}");
        assert!(second - first < 5);
    }

    #[test]
    fn retry_after_accepts_seconds_or_a_date_within_a_day() {
        assert_eq!(retry_after_seconds("120", None), Some(120));
        assert_eq!(retry_after_seconds(" 0 ", None), Some(1));
        assert_eq!(retry_after_seconds("999999", None), Some(DAY));
        assert_eq!(retry_after_seconds("soon", None), None);
        let date = chrono::DateTime::from_timestamp(NOW + 90, 0)
            .unwrap()
            .to_rfc2822();
        assert_eq!(retry_after_seconds(&date, Some(NOW)), Some(90));
        assert_eq!(retry_after_seconds(&date, Some(NOW + 500)), Some(1));
    }

    #[cfg(debug_assertions)]
    #[test]
    fn a_debug_build_can_shorten_the_trial() {
        // SAFETY: no other test reads or writes this variable.
        unsafe { std::env::set_var("OPENKLACK_DEBUG_TRIAL_MINUTES", "10") };
        let terms = debug_trial_terms().unwrap();
        assert_eq!(terms.length, 600);
        unsafe { std::env::set_var("OPENKLACK_DEBUG_TRIAL_MINUTES", "soon") };
        assert_eq!(debug_trial_terms(), None);
        unsafe { std::env::remove_var("OPENKLACK_DEBUG_TRIAL_MINUTES") };
        assert_eq!(debug_trial_terms(), None);
    }
}
