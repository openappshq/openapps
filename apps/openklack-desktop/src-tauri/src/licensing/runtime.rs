//! The licensed build's plumbing around `core`: the Keychain record, the Dodo HTTP client,
//! the daily check scheduler, and the commands and events the settings window uses.
//!
//! Rules: lock first, persist after, and unlock only after the record is saved.
//! `Service::mutate` orders every Keychain write, so a slower writer can never put an older
//! record back. `Service::engine` is only ever held for a pure step, never across the network
//! or the Keychain, so reads for the window and the deep link never wait on I/O. Every gate
//! decision carries a revision issued under the engine lock, and the audio side applies only
//! newer ones; a restrictive decision is published before any I/O, a permissive one after the
//! save it depends on. While the record is unknown, playback stays gated.

use super::core::Dodo;
use super::core::{
    Activation, DAY, DodoError, Engine, GRACE_WARNING_AFTER, KeyHint, LicenseError, Probe,
    Products, Refusal, State, Stored, Validation,
};
use crate::engine::Controller;
use serde::Serialize;
use std::{
    sync::{
        Arc, Condvar, Mutex, MutexGuard,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime},
};
use tauri::{Emitter, Manager};

pub const KEYCHAIN_SERVICE: &str = "space.openapps.openklack.license";
const KEYCHAIN_ACCOUNT: &str = "license";
const HOST: &str = env!("OPENKLACK_DODO_HOST");
const ENVIRONMENT: &str = env!("OPENKLACK_LICENSE_ENV");
const PAID_PRODUCT_ID: &str = env!("OPENKLACK_DODO_PAID_PRODUCT_ID");
const TRIAL_PRODUCT_ID: &str = env!("OPENKLACK_DODO_TRIAL_PRODUCT_ID");
const BUY_URL: &str = env!("OPENKLACK_BUY_URL");
const TRIAL_URL: &str = env!("OPENKLACK_TRIAL_URL");
const SUPPORT_URL: &str = env!("OPENKLACK_SUPPORT_URL");
/// The scheduler re-evaluates at least this often so clock changes and long sleeps are noticed.
const MAX_SLEEP: Duration = Duration::from_secs(3600);
/// While checks fail, the network is probed this often so a check runs as soon as it is back.
const REACHABILITY_POLL: Duration = Duration::from_secs(300);
/// Owed deactivations are retried this often.
const CLEANUP_RETRY: Duration = Duration::from_secs(300);

/// Comma-separated IDs let a future bundle product join the paid list without code changes.
pub fn products() -> Products {
    let list = |ids: &str| {
        ids.split(',')
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
            .collect()
    };
    Products {
        paid: list(PAID_PRODUCT_ID),
        trial: list(TRIAL_PRODUCT_ID),
    }
}

fn system_now() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
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

/// Where the record lives. The real one is the single Keychain item; tests use memory.
pub trait Vault: Send + Sync {
    fn load(&self) -> Result<Stored, String>;
    fn save(&self, stored: &Stored) -> Result<(), String>;
}

/// The single Keychain item that holds the record. Never plain preferences.
pub struct Keychain;

#[cfg(target_os = "macos")]
impl Vault for Keychain {
    fn load(&self) -> Result<Stored, String> {
        match security_framework::passwords::get_generic_password(
            KEYCHAIN_SERVICE,
            KEYCHAIN_ACCOUNT,
        ) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| format!("The saved license could not be read: {e}")),
            // errSecItemNotFound: nothing saved yet.
            Err(error) if error.code() == -25300 => Ok(Stored::default()),
            Err(error) => Err(format!("The Keychain could not be read: {error}")),
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
}

#[cfg(not(target_os = "macos"))]
impl Vault for Keychain {
    fn load(&self) -> Result<Stored, String> {
        Ok(Stored::default())
    }

    fn save(&self, _: &Stored) -> Result<(), String> {
        Err("Licensing is supported on macOS.".into())
    }
}

/// Dodo's public endpoints over HTTPS. Requests carry only the key and the activation ID.
pub struct HttpDodo {
    client: reqwest::Client,
}

impl HttpDodo {
    fn new() -> Result<Self, String> {
        if rustls::crypto::CryptoProvider::get_default().is_none() {
            let _ = rustls::crypto::ring::default_provider().install_default();
        }
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
        let request = self
            .client
            .post(format!("{HOST}/licenses/{path}"))
            .json(&body)
            .send();
        let response = tauri::async_runtime::block_on(request).map_err(|error| {
            DodoError::Offline(if error.is_timeout() {
                "timed out".into()
            } else {
                "no connection".into()
            })
        })?;
        let status = response.status().as_u16();
        let header = |name: &str| {
            response
                .headers()
                .get(name)
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned)
        };
        let server_time = header("date").and_then(|date| {
            chrono::DateTime::parse_from_rfc2822(&date)
                .ok()
                .map(|date| date.timestamp())
        });
        let retry_after =
            header("retry-after").and_then(|value| retry_after_seconds(&value, server_time));
        let body = tauri::async_runtime::block_on(response.bytes())
            .map_err(|error| DodoError::Offline(error.to_string()))?;
        let json = serde_json::from_slice(&body).unwrap_or(serde_json::Value::Null);
        Ok((status, server_time, retry_after, json))
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

/// The app around the service: the settings window, the audio engine, and the network.
pub trait Host: Send + Sync {
    fn publish(&self, view: &View);
    /// Gate keyboard sound playback. Decisions carry a revision issued under the engine lock;
    /// the host must apply a decision only if its revision is newer than the last one applied,
    /// atomically with applying it. Everything else in the app keeps working.
    fn set_blocked(&self, revision: u64, blocked: bool);
    /// A cheap connectivity probe, used only after network-level failures.
    fn reachable(&self) -> bool;
}

pub struct TauriHost {
    app: tauri::AppHandle,
}

impl Host for TauriHost {
    fn publish(&self, view: &View) {
        let _ = self.app.emit("license", view);
    }

    fn set_blocked(&self, revision: u64, blocked: bool) {
        if let Some(controller) = self.app.try_state::<Arc<Controller>>() {
            controller.set_license_blocked(revision, blocked);
        }
    }

    fn reachable(&self) -> bool {
        // A TCP handshake with the license host: no request is made, and a failure costs seconds.
        let host = HOST.trim_start_matches("https://");
        std::net::ToSocketAddrs::to_socket_addrs(&(host, 443))
            .ok()
            .and_then(|mut addresses| addresses.next())
            .is_some_and(|address| {
                std::net::TcpStream::connect_timeout(&address, Duration::from_secs(3)).is_ok()
            })
    }
}

/// What the settings window shows. Mirrors the state table in LICENSING.md.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    pub revision: u64,
    /// False until the Keychain has been read; the window shows a loading state.
    pub ready: bool,
    pub environment: &'static str,
    #[serde(flatten)]
    pub state: State,
    pub core_feature: bool,
    /// The clock was set back: a trial counts as ended and a paid license needs a check.
    pub clock_changed: bool,
    pub trial_used: bool,
    pub grace_warning: bool,
    pub checking: bool,
    pub last_success_at: Option<i64>,
    pub last_error: Option<String>,
    pub pending_key: Option<String>,
    /// The deep link said the pending key is a trial key, so a second trial is refused locally.
    pub pending_trial: bool,
    pub buy_url: &'static str,
    pub trial_url: &'static str,
    pub support_url: &'static str,
}

#[derive(Default)]
struct Meta {
    revision: u64,
    ready: bool,
    checking: bool,
    last_error: Option<String>,
    pending_key: Option<String>,
    pending_trial: bool,
    last_reachability_poll: Option<i64>,
    /// A recovery check may run once after the network was seen down.
    recovery_armed: bool,
    /// A Keychain write failed; the record is written again every tick until it succeeds.
    storage_dirty: bool,
    last_cleanup_at: Option<i64>,
}

pub type Clock = Box<dyn Fn() -> i64 + Send + Sync>;

pub struct Service<D: Dodo + Send + Sync, V: Vault, H: Host> {
    /// Held for pure steps only: never across the network or the Keychain.
    engine: Mutex<Engine>,
    meta: Mutex<Meta>,
    /// Orders every Keychain write, and the activation and removal sequences around theirs.
    mutate: Mutex<()>,
    /// One validation in flight at a time, from the scheduler or the window.
    check: Mutex<()>,
    /// Issued under the engine lock with each gate decision; the host applies only newer ones.
    gate_revision: AtomicU64,
    wake: (Mutex<bool>, Condvar),
    dodo: D,
    vault: V,
    host: H,
    clock: Clock,
}

pub type Live = Service<HttpDodo, Keychain, TauriHost>;

impl Live {
    /// Registers the service, gates playback until the record is known, and starts the thread
    /// that reads the Keychain. Launch is never delayed.
    pub fn start(app: &tauri::AppHandle) -> Result<(), String> {
        let service = Arc::new(Service::new(
            HttpDodo::new()?,
            Keychain,
            TauriHost { app: app.clone() },
            Box::new(system_now),
        ));
        app.manage(service.clone());
        service.apply();
        std::thread::Builder::new()
            .name("openklack-license".into())
            .spawn(move || service.run())
            .map_err(|e| e.to_string())?;
        Ok(())
    }
}

impl<D: Dodo + Send + Sync, V: Vault, H: Host> Service<D, V, H> {
    pub fn new(dodo: D, vault: V, host: H, clock: Clock) -> Self {
        Self {
            engine: Mutex::new(Engine::new(Stored::default(), products())),
            meta: Mutex::new(Meta::default()),
            mutate: Mutex::new(()),
            check: Mutex::new(()),
            gate_revision: AtomicU64::new(0),
            wake: (Mutex::new(false), Condvar::new()),
            dodo,
            vault,
            host,
            clock,
        }
    }

    fn now(&self) -> i64 {
        (self.clock)()
    }

    /// Reads the record, runs the launch check, then keeps the daily schedule.
    fn run(&self) {
        self.load();
        loop {
            self.tick();
            self.sleep();
        }
    }

    /// Reads the Keychain. A failure leaves the Mac unlicensed with the reason in Settings.
    pub fn load(&self) {
        let (stored, error) = match self.vault.load() {
            Ok(stored) => (stored, None),
            Err(error) => (Stored::default(), Some(error)),
        };
        {
            let ordered = self.mutate.lock().unwrap();
            self.engine.lock().unwrap().stored = stored;
            self.meta.lock().unwrap().ready = true;
            drop(ordered);
        }
        self.publish(|meta| meta.last_error = error);
        // The record is durable already, so it may unlock playback right away.
        self.apply();
        // The contract's launch check: in the background, whatever the last success time.
        let _ = self.check_once(true);
    }

    /// One pass of the scheduler. Deadlines are enforced first and without waiting on any
    /// write; then due or recovered checks, stale slots, and the permissive re-evaluation.
    pub fn tick(&self) {
        self.gate(false);
        let now = self.now();
        // The high-water mark keeps a rolled-back clock from being trusted.
        if self.engine.lock().unwrap().observe(now) {
            let ordered = self.mutate.lock().unwrap();
            self.persist(&ordered);
        }
        let (due, network_down) = {
            let engine = self.engine.lock().unwrap();
            (engine.check_due(now), engine.schedule.network_down)
        };
        if due {
            let _ = self.check_once(false);
        } else if network_down && self.network_recovered(now) {
            let _ = self.check_once(true);
        }
        self.release_cleanups(now);
        if self.meta.lock().unwrap().storage_dirty {
            let ordered = self.mutate.lock().unwrap();
            self.persist(&ordered);
        }
        self.apply();
    }

    /// After a network-level failure, a cheap probe every few minutes notices the network
    /// coming back and allows one check ahead of the backoff. It re-arms only after the probe
    /// has seen the network down, so a reachable host that keeps failing stays on the backoff.
    fn network_recovered(&self, now: i64) -> bool {
        let due = {
            let mut meta = self.meta.lock().unwrap();
            let due = meta
                .last_reachability_poll
                .is_none_or(|last| now - last >= REACHABILITY_POLL.as_secs() as i64);
            if due {
                meta.last_reachability_poll = Some(now);
            }
            due
        };
        if !due {
            return false;
        }
        let reachable = self.host.reachable();
        let mut meta = self.meta.lock().unwrap();
        if !reachable {
            meta.recovery_armed = true;
            return false;
        }
        std::mem::take(&mut meta.recovery_armed)
    }

    fn sleep(&self) {
        let now = self.now();
        let (next_check, next_transition, probing) = {
            let engine = self.engine.lock().unwrap();
            (
                engine.next_check_at(now),
                engine.next_transition_at(now),
                engine.schedule.network_down || !engine.stored.pending_cleanups.is_empty(),
            )
        };
        let mut wait = [next_check, next_transition]
            .into_iter()
            .flatten()
            .map(|due| Duration::from_secs((due - now).max(0) as u64))
            .min()
            .unwrap_or(MAX_SLEEP);
        if probing || self.meta.lock().unwrap().storage_dirty {
            wait = wait.min(REACHABILITY_POLL.min(CLEANUP_RETRY));
        }
        let wait = wait.clamp(Duration::from_secs(1), MAX_SLEEP);
        let (flag, condvar) = &self.wake;
        let mut woken = flag.lock().unwrap();
        if !*woken {
            woken = condvar.wait_timeout(woken, wait).unwrap().0;
        }
        *woken = false;
    }

    /// Wakes the scheduler: after activation, on wake from sleep, or when asked to check now.
    pub fn poke(&self) {
        let (flag, condvar) = &self.wake;
        *flag.lock().unwrap() = true;
        condvar.notify_all();
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
        let (result, network_down) = {
            let mut engine = self.engine.lock().unwrap();
            let result = engine.finish_check(&probe, answer, self.now());
            (result, engine.schedule.network_down)
        };
        self.gate(false);
        if network_down {
            self.meta.lock().unwrap().recovery_armed = true;
        }
        {
            let ordered = self.mutate.lock().unwrap();
            self.persist(&ordered);
        }
        self.publish(|meta| {
            meta.checking = false;
            match &result {
                Err(error) => meta.last_error = Some(error.message()),
                Ok(_) if !meta.storage_dirty => meta.last_error = None,
                Ok(_) => {}
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

    /// Writes the current record. Requires the ordering lock, so writes land in the order the
    /// changes were made and a slower writer can never restore an older record.
    fn persist(&self, _ordered: &MutexGuard<'_, ()>) {
        let stored = self.engine.lock().unwrap().stored.clone();
        match self.vault.save(&stored) {
            Ok(()) => {
                let was_dirty = std::mem::take(&mut self.meta.lock().unwrap().storage_dirty);
                if was_dirty {
                    self.publish(|meta| meta.last_error = None);
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

    /// Decides the gate under the engine lock and stamps it with the next revision.
    fn decide(&self) -> (u64, bool) {
        let engine = self.engine.lock().unwrap();
        let ready = self.meta.lock().unwrap().ready;
        let blocked = !ready || !engine.core_feature(self.now());
        let revision = self.gate_revision.fetch_add(1, Ordering::SeqCst) + 1;
        (revision, blocked)
    }

    /// Publishes the gate: a restriction always, a permission only when the caller says the
    /// record it depends on is saved.
    fn gate(&self, allow_unlock: bool) {
        let (revision, blocked) = self.decide();
        if blocked || allow_unlock {
            self.host.set_blocked(revision, blocked);
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
        let state = engine.state(now);
        View {
            revision: meta.revision,
            ready: meta.ready,
            environment: ENVIRONMENT,
            state,
            core_feature: state.core_feature(),
            clock_changed: engine.clock_changed(now),
            trial_used: engine.stored.trial_used,
            grace_warning: matches!(state, State::Grace { .. })
                && engine
                    .offline_for(now)
                    .is_some_and(|age| age >= GRACE_WARNING_AFTER),
            checking: meta.checking,
            last_success_at: engine.stored.license.as_ref().map(|r| r.last_success_at),
            last_error: meta.last_error.clone(),
            pending_key: meta.pending_key.clone(),
            pending_trial: meta.pending_trial,
            buy_url: BUY_URL,
            trial_url: TRIAL_URL,
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
    pub fn activate(&self, key: &str, hint: KeyHint) -> Result<View, String> {
        let outcome = {
            let ordered = self.mutate.lock().unwrap();
            self.activate_ordered(&ordered, key, hint)
        };
        let outcome = outcome.map_err(|error| error.message());
        self.publish(|meta| {
            meta.last_error = None;
            if outcome.is_ok() {
                meta.pending_key = None;
                meta.pending_trial = false;
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
        hint: KeyHint,
    ) -> Result<State, LicenseError> {
        let now = self.now();
        self.engine
            .lock()
            .unwrap()
            .activation_allowed(key, hint, now)?;
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
            let replaced = engine.commit_activation(activated);
            (engine.state(now), replaced)
        };
        self.gate(false);
        if let Some(replaced) = replaced {
            self.release(ordered, replaced);
            self.persist(ordered);
        }
        Ok(state)
    }

    /// Settings → License → Remove this Mac. Playback stops before the cleared record is saved.
    pub fn remove(&self) -> Result<View, String> {
        let outcome = {
            let ordered = self.mutate.lock().unwrap();
            let now = self.now();
            let begun = self.engine.lock().unwrap().begin_remove(now);
            begun.and_then(|probe| {
                let answer = self.dodo.deactivate(&probe.license_key, &probe.instance_id);
                let result = self
                    .engine
                    .lock()
                    .unwrap()
                    .finish_remove(&probe, answer, now);
                self.gate(false);
                self.persist(&ordered);
                result
            })
        };
        let outcome = outcome.map_err(|error| error.message());
        self.publish(|meta| meta.last_error = None);
        self.apply();
        self.poke();
        outcome.map(|_| self.view())
    }

    /// `openklack://activate?key=…[&kind=trial]` only pre-fills the key; the user confirms
    /// before activating. Unknown parameters are ignored.
    pub fn opened(&self, urls: &[url::Url]) {
        let link = urls.iter().find_map(parse_activation_link);
        if let Some((key, trial)) = link {
            self.publish(|meta| {
                meta.pending_key = Some(key);
                meta.pending_trial = trial;
            });
        }
    }

    pub fn trial_used(&self) -> bool {
        self.engine.lock().unwrap().stored.trial_used
    }

    pub fn dismiss_key(&self) -> View {
        self.publish(|meta| {
            meta.pending_key = None;
            meta.pending_trial = false;
        })
    }
}

/// The key and whether the link marks it as a trial key, for `openklack://activate` links.
fn parse_activation_link(url: &url::Url) -> Option<(String, bool)> {
    if url.scheme() != "openklack" || url.host_str() != Some("activate") {
        return None;
    }
    let mut key = None;
    let mut trial = false;
    for (name, value) in url.query_pairs() {
        match &*name {
            "key" => {
                let value = value.trim();
                if !value.is_empty()
                    && value.len() <= 200
                    && value.bytes().all(|b| b.is_ascii_graphic())
                {
                    key = Some(value.to_string());
                }
            }
            "kind" => trial = value.eq_ignore_ascii_case("trial"),
            _ => {}
        }
    }
    key.map(|key| (key, trial))
}

/// Called from the audio engine when the Mac wakes: checks again if the last one is a day old.
pub fn wake(app: &tauri::AppHandle) {
    if let Some(service) = app.try_state::<Arc<Live>>() {
        service.poke();
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
    expect_trial: bool,
) -> Result<View, String> {
    let service = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        service.activate(
            &key,
            if expect_trial {
                KeyHint::Trial
            } else {
                KeyHint::Any
            },
        )
    })
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

#[tauri::command]
pub fn dismiss_license_key(state: tauri::State<'_, Arc<Live>>) -> View {
    state.dismiss_key()
}

/// Opens one of the configured checkout or support links in the default browser.
#[tauri::command]
pub fn open_license_link(link: String) -> Result<(), String> {
    let url = match link.as_str() {
        "buy" => BUY_URL,
        "trial" => TRIAL_URL,
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

/// Whether a trial can still start on this Mac: refused locally without calling Dodo otherwise.
#[tauri::command]
pub fn start_license_trial(state: tauri::State<'_, Arc<Live>>) -> Result<View, String> {
    if state.trial_used() {
        return Err(LicenseError::TrialUsed.message());
    }
    open_license_link("trial".into())?;
    Ok(state.view())
}

#[cfg(test)]
mod tests {
    //! The service with a scripted Dodo, an in-memory vault and a fake app, driven by threads so
    //! the lock ordering and gate ordering themselves are under test.
    use super::super::core::{Kind, Record};
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

    /// An in-memory Keychain whose reads and writes can be paused so slow I/O can be raced.
    #[derive(Default)]
    struct FakeVault {
        stored: Mutex<Stored>,
        writes: Mutex<Vec<Stored>>,
        save_error: Mutex<Option<String>>,
        read_pause: Pause,
        write_pause: Pause,
    }

    impl Vault for FakeVault {
        fn load(&self) -> Result<Stored, String> {
            self.read_pause.enter();
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
    }

    /// The audio side: applies only newer gate revisions, atomically, like the controller.
    #[derive(Default)]
    struct FakeHost {
        gate: Mutex<(u64, bool)>,
        reachable: AtomicBool,
        unlock_pause: Pause,
    }

    impl FakeHost {
        fn blocked(&self) -> bool {
            self.gate.lock().unwrap().1
        }
    }

    impl Host for FakeHost {
        fn publish(&self, _: &View) {}
        fn set_blocked(&self, revision: u64, blocked: bool) {
            if !blocked {
                self.unlock_pause.enter();
            }
            let mut gate = self.gate.lock().unwrap();
            if revision > gate.0 {
                *gate = (revision, blocked);
            }
        }
        fn reachable(&self) -> bool {
            self.reachable.load(Ordering::SeqCst)
        }
    }

    type TestService = Service<FakeDodo, FakeVault, FakeHost>;

    fn paid_record(key: &str, last_success_ago: i64) -> Record {
        Record {
            license_key: key.into(),
            instance_id: format!("lki_{key}"),
            product_id: PAID_PRODUCT_ID.split(',').next().unwrap().into(),
            kind: Kind::Paid,
            activated_at: NOW - 30 * DAY,
            last_success_at: NOW - last_success_ago,
            last_success_local: NOW - last_success_ago,
            last_observed_at: NOW - last_success_ago,
            revoked: false,
        }
    }

    fn trial_record(activated_ago: i64) -> Record {
        Record {
            license_key: "KEY-TRIAL".into(),
            instance_id: "lki_KEY-TRIAL".into(),
            product_id: TRIAL_PRODUCT_ID.split(',').next().unwrap().into(),
            kind: Kind::Trial,
            activated_at: NOW - activated_ago,
            last_success_at: NOW - activated_ago,
            last_success_local: NOW - activated_ago,
            last_observed_at: NOW - activated_ago,
            revoked: false,
        }
    }

    fn service(stored: Stored, clock: Arc<AtomicI64>) -> Arc<TestService> {
        let vault = FakeVault::default();
        *vault.stored.lock().unwrap() = stored;
        let service = Arc::new(Service::new(
            FakeDodo::paid(),
            vault,
            FakeHost::default(),
            Box::new(move || clock.load(Ordering::SeqCst)),
        ));
        // As `Live::start` does: gated until the record is read.
        service.apply();
        service
    }

    fn with_trial() -> Stored {
        Stored {
            license: Some(trial_record(DAY)),
            trial_used: true,
            ..Stored::default()
        }
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

    #[test]
    fn a_check_with_nothing_due_releases_the_engine() {
        // The scheduler decides a check is due, an activation lands first, and the scheduler's
        // `begin_check` finds nothing due. The service must stay usable.
        let service = service(with_trial(), Arc::new(AtomicI64::new(NOW)));
        within_timeout({
            let service = service.clone();
            move || {
                service.load();
                service
                    .activate("KEY-PAID", KeyHint::Any)
                    .expect("activation");
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
    }

    #[test]
    fn a_slow_writer_cannot_restore_a_replaced_record() {
        // A scheduler write of trial A pauses mid-save while paid B activates. Every write is
        // ordered, so B waits for A's write and lands last.
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_trial(), clock.clone());
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
            thread::spawn(move || {
                service
                    .activate("KEY-PAID", KeyHint::Any)
                    .map(|view| view.state)
            })
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
        assert_eq!(writes[0].license.as_ref().unwrap().license_key, "KEY-TRIAL");
        assert_eq!(
            writes.last().unwrap().license.as_ref().unwrap().license_key,
            "KEY-PAID"
        );
        assert_eq!(
            service.vault.load().unwrap().license.unwrap().license_key,
            "KEY-PAID"
        );
        assert!(
            service
                .dodo
                .calls()
                .contains(&"deactivate KEY-TRIAL lki_KEY-TRIAL".to_string())
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
        assert_eq!(service.check_once(true), Ok(State::Unlicensed));
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
    fn an_expired_trial_stops_sound_before_its_observation_is_saved() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(with_trial(), clock.clone());
        service.load();
        assert!(!service.host.blocked());
        clock.store(NOW + 3 * DAY, Ordering::SeqCst);
        service.vault.write_pause.arm();
        let worker = {
            let service = service.clone();
            thread::spawn(move || service.tick())
        };
        service.vault.write_pause.wait_entered();
        assert_eq!(service.view().state, State::TrialEnded);
        assert!(service.host.blocked(), "blocked before the save completes");
        service.vault.write_pause.open();
        worker.join().unwrap();
        assert!(service.host.blocked());
    }

    #[test]
    fn a_stale_gate_update_cannot_reenable_a_removed_license() {
        // An old permissive decision, delayed on its way to the audio engine, arrives after
        // Remove this Mac has blocked playback. Its revision is older, so it is ignored.
        let service = service(with_paid(HOUR), Arc::new(AtomicI64::new(NOW)));
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
        assert_eq!(service.view().state, State::Unlicensed);
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
        assert_eq!(service.view().state, State::Licensed);
        assert!(service.host.blocked(), "not yet saved");
        service.vault.write_pause.open();
        worker.join().unwrap();
        assert!(!service.host.blocked());
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
    fn a_record_that_cannot_be_saved_leaves_the_old_activation_and_frees_the_slot() {
        let service = service(with_trial(), Arc::new(AtomicI64::new(NOW)));
        service.load();
        *service.vault.save_error.lock().unwrap() = Some("keychain locked".into());
        let error = service.activate("KEY-PAID", KeyHint::Any).unwrap_err();
        assert!(error.contains("keychain locked"), "{error}");
        assert_eq!(service.state(), State::Trial { days_left: 2 });
        assert_eq!(
            service.dodo.calls()[1..],
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
        let limited: Service<LimitedDodo, FakeVault, FakeHost> = Service::new(
            LimitedDodo(FakeDodo::paid()),
            FakeVault::default(),
            FakeHost::default(),
            Box::new(move || clock_copy.load(Ordering::SeqCst)),
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
    fn activation_links_carry_the_key_and_an_optional_trial_marker() {
        let parse = |link: &str| parse_activation_link(&url::Url::parse(link).unwrap());
        assert_eq!(
            parse("openklack://activate?key=ABCD-1234"),
            Some(("ABCD-1234".into(), false))
        );
        assert_eq!(
            parse("openklack://activate?key=%20ABCD-1234%20&kind=trial&utm=x"),
            Some(("ABCD-1234".into(), true))
        );
        assert_eq!(parse("openklack://activate?kind=trial"), None);
        assert_eq!(parse("openklack://activate?key=bad%20key"), None);
        assert_eq!(parse("openklack://settings?key=ABCD"), None);
        assert_eq!(parse("https://activate/?key=ABCD"), None);
        let service = service(Stored::default(), Arc::new(AtomicI64::new(NOW)));
        service.opened(&[url::Url::parse("openklack://activate?key=K1&kind=trial").unwrap()]);
        let view = service.view();
        assert_eq!(view.pending_key.as_deref(), Some("K1"));
        assert!(view.pending_trial);
        let view = service.dismiss_key();
        assert_eq!(view.pending_key, None);
        assert!(!view.pending_trial);
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
}
