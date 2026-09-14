//! The licensed build's plumbing around `core`: the Keychain record, the Dodo HTTP client,
//! the daily check scheduler, and the commands and events the settings window uses.
//!
//! Locking: `Service::mutate` orders every change to the stored record together with its
//! Keychain write, so a slower writer can never put an older record back. `Service::engine`
//! is only ever held for a pure step, never across the network or the Keychain, so reads for
//! the window and the deep link never wait on I/O.

use super::core::Dodo;
use super::core::{
    Activation, DAY, DodoError, Engine, GRACE_WARNING_AFTER, KeyHint, LicenseError, Probe,
    Products, Refusal, State, Stored, Validation,
};
use crate::engine::Controller;
use serde::Serialize;
use std::{
    sync::{Arc, Condvar, Mutex, MutexGuard},
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
            500..=599 => DodoError::Offline(format!("server error {status}")),
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
    /// Gate keyboard sound playback. Everything else in the app keeps working.
    fn set_blocked(&self, blocked: bool);
    /// A cheap connectivity probe, used only while checks are failing.
    fn reachable(&self) -> bool;
}

pub struct TauriHost {
    app: tauri::AppHandle,
}

impl Host for TauriHost {
    fn publish(&self, view: &View) {
        let _ = self.app.emit("license", view);
    }

    fn set_blocked(&self, blocked: bool) {
        if let Some(controller) = self.app.try_state::<Arc<Controller>>() {
            controller.set_license_blocked(blocked);
        }
    }

    fn reachable(&self) -> bool {
        // A TCP handshake with the license host: nothing is sent, and a failure costs seconds.
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
    pub trial_used: bool,
    pub grace_warning: bool,
    pub checking: bool,
    pub last_success_at: Option<i64>,
    pub last_error: Option<String>,
    pub pending_key: Option<String>,
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
    last_reachability_poll: Option<i64>,
}

pub type Clock = Box<dyn Fn() -> i64 + Send + Sync>;

pub struct Service<D: Dodo + Send + Sync, V: Vault, H: Host> {
    /// Held for pure steps only: never across the network or the Keychain.
    engine: Mutex<Engine>,
    meta: Mutex<Meta>,
    /// Orders every change to the record together with its save. Network calls that lead to a
    /// change run under it, but the background validation does not: its answer is matched to
    /// the activation it was asked about when it is applied.
    mutate: Mutex<()>,
    /// One validation in flight at a time, from the scheduler or the window.
    check: Mutex<()>,
    wake: (Mutex<bool>, Condvar),
    dodo: D,
    vault: V,
    host: H,
    clock: Clock,
}

pub type Live = Service<HttpDodo, Keychain, TauriHost>;

impl Live {
    /// Registers the service and starts its thread. The Keychain is read on that thread, so
    /// launch is never delayed; until it is read, playback is not gated.
    pub fn start(app: &tauri::AppHandle) -> Result<(), String> {
        let service = Arc::new(Service::new(
            HttpDodo::new()?,
            Keychain,
            TauriHost { app: app.clone() },
            Box::new(system_now),
        ));
        app.manage(service.clone());
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
        let ordered = self.mutate.lock().unwrap();
        let (stored, error) = match self.vault.load() {
            Ok(stored) => (stored, None),
            Err(error) => (Stored::default(), Some(error)),
        };
        self.engine.lock().unwrap().stored = stored;
        self.publish(|meta| {
            meta.ready = true;
            meta.last_error = error;
        });
        drop(ordered);
        self.apply();
        // The contract's launch check: in the background, whatever the last success time.
        let _ = self.check_once(true);
    }

    /// One pass of the scheduler: due or recovered checks, stale slots, and time-only
    /// transitions such as a trial ending or grace running out.
    pub fn tick(&self) {
        let now = self.now();
        {
            // The high-water mark keeps a rolled-back clock from extending a trial.
            let ordered = self.mutate.lock().unwrap();
            if self.engine.lock().unwrap().observe(now) {
                self.persist(&ordered);
            }
        }
        let (due, failing) = {
            let engine = self.engine.lock().unwrap();
            (engine.check_due(now), engine.schedule.failures > 0)
        };
        if due {
            let _ = self.check_once(false);
        } else if failing && self.poll_reachability(now) {
            let _ = self.check_once(true);
        }
        self.release_stale();
        self.apply();
    }

    /// While checks fail, a cheap probe every few minutes runs the check as soon as the network
    /// is back instead of waiting out the backoff.
    fn poll_reachability(&self, now: i64) -> bool {
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
        due && self.host.reachable()
    }

    fn sleep(&self) {
        let now = self.now();
        let (next_check, next_transition, failing) = {
            let engine = self.engine.lock().unwrap();
            (
                engine.next_check_at(now),
                engine.next_transition_at(now),
                engine.schedule.failures > 0,
            )
        };
        let mut wait = [next_check, next_transition]
            .into_iter()
            .flatten()
            .map(|due| Duration::from_secs((due - now).max(0) as u64))
            .min()
            .unwrap_or(MAX_SLEEP);
        if failing {
            wait = wait.min(REACHABILITY_POLL);
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

    /// Runs one validation. The network call holds neither lock; the answer is applied to the
    /// activation it was asked about, in order with every other change.
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
        let result = {
            let ordered = self.mutate.lock().unwrap();
            let result = self
                .engine
                .lock()
                .unwrap()
                .finish_check(&probe, answer, self.now());
            self.persist(&ordered);
            result
        };
        self.publish(|meta| {
            meta.checking = false;
            meta.last_error = result.as_ref().err().map(LicenseError::message);
        });
        result
    }

    /// Frees slots this Mac gave up while Dodo was unreachable.
    fn release_stale(&self) {
        let ordered = self.mutate.lock().unwrap();
        let pending = self.engine.lock().unwrap().take_stale(self.now());
        if pending.is_empty() {
            return;
        }
        for probe in pending {
            self.release(&ordered, probe);
        }
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
        if let Err(error) = self.vault.save(&stored) {
            self.publish(|meta| meta.last_error = Some(error));
        }
    }

    fn state(&self) -> State {
        self.engine.lock().unwrap().state(self.now())
    }

    /// Reflects the state on the audio engine: only keyboard sound playback is gated, and only
    /// once the record has been read.
    fn apply(&self) {
        let ready = self.meta.lock().unwrap().ready;
        let enabled = !ready || self.engine.lock().unwrap().core_feature(self.now());
        self.host.set_blocked(!enabled);
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
            trial_used: engine.stored.trial_used,
            grace_warning: matches!(state, State::Grace { .. })
                && engine
                    .stored
                    .license
                    .as_ref()
                    .is_some_and(|record| now - record.last_success_at >= GRACE_WARNING_AFTER),
            checking: meta.checking,
            last_success_at: engine.stored.license.as_ref().map(|r| r.last_success_at),
            last_error: meta.last_error.clone(),
            pending_key: meta.pending_key.clone(),
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
        if let Some(replaced) = replaced {
            self.release(ordered, replaced);
            self.persist(ordered);
        }
        Ok(state)
    }

    /// Settings → License → Remove this Mac.
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

    /// `openklack://activate?key=…` only pre-fills the key; the user confirms before activating.
    pub fn opened(&self, urls: &[url::Url]) {
        let key = urls.iter().find_map(|url| {
            if url.scheme() != "openklack" || url.host_str() != Some("activate") {
                return None;
            }
            url.query_pairs()
                .find(|(name, _)| name == "key")
                .map(|(_, value)| value.trim().to_string())
                .filter(|key| {
                    !key.is_empty() && key.len() <= 200 && key.bytes().all(|b| b.is_ascii_graphic())
                })
        });
        if let Some(key) = key {
            self.publish(|meta| meta.pending_key = Some(key));
        }
    }

    pub fn trial_used(&self) -> bool {
        self.engine.lock().unwrap().stored.trial_used
    }

    pub fn dismiss_key(&self) -> View {
        self.publish(|meta| meta.pending_key = None)
    }
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
        service.apply();
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
    //! the lock ordering itself is under test.
    use super::super::core::{Kind, Record};
    use super::*;
    use std::{
        sync::{
            atomic::{AtomicBool, AtomicI64, Ordering},
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

    /// An in-memory Keychain whose writes can be paused so an older writer can be raced.
    #[derive(Default)]
    struct FakeVault {
        stored: Mutex<Stored>,
        writes: Mutex<Vec<Stored>>,
        pause_writes: AtomicBool,
        gate: (Mutex<bool>, Condvar),
    }

    impl FakeVault {
        fn open(&self) {
            *self.gate.0.lock().unwrap() = true;
            self.gate.1.notify_all();
        }
    }

    impl Vault for FakeVault {
        fn load(&self) -> Result<Stored, String> {
            Ok(self.stored.lock().unwrap().clone())
        }
        fn save(&self, stored: &Stored) -> Result<(), String> {
            if self.pause_writes.swap(false, Ordering::SeqCst) {
                let mut open = self.gate.0.lock().unwrap();
                while !*open {
                    open = self.gate.1.wait(open).unwrap();
                }
            }
            *self.stored.lock().unwrap() = stored.clone();
            self.writes.lock().unwrap().push(stored.clone());
            Ok(())
        }
    }

    #[derive(Default)]
    struct FakeHost {
        blocked: AtomicBool,
        reachable: AtomicBool,
    }

    impl Host for FakeHost {
        fn publish(&self, _: &View) {}
        fn set_blocked(&self, blocked: bool) {
            self.blocked.store(blocked, Ordering::SeqCst);
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
            seen_at: NOW - last_success_ago,
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
            seen_at: NOW - activated_ago,
            revoked: false,
        }
    }

    fn service(stored: Stored, clock: Arc<AtomicI64>) -> Arc<TestService> {
        let vault = FakeVault::default();
        *vault.stored.lock().unwrap() = stored;
        Arc::new(Service::new(
            FakeDodo::paid(),
            vault,
            FakeHost::default(),
            Box::new(move || clock.load(Ordering::SeqCst)),
        ))
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
        // P0 regression: the scheduler decides a check is due, an activation lands first, and the
        // scheduler's `begin_check` finds nothing due. The service must stay usable.
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(
            Stored {
                license: Some(trial_record(DAY)),
                trial_used: true,
                ..Stored::default()
            },
            clock,
        );
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
                assert!(!service.host.blocked.load(Ordering::SeqCst));
            }
        });
        assert_eq!(
            service.vault.load().unwrap().license.unwrap().license_key,
            "KEY-PAID"
        );
    }

    #[test]
    fn a_slow_writer_cannot_restore_a_replaced_record() {
        // P0 regression: a scheduler write of trial A pauses mid-save while paid B activates.
        // Every write is ordered, so B waits for A's write and lands last.
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(
            Stored {
                license: Some(trial_record(DAY)),
                trial_used: true,
                ..Stored::default()
            },
            clock.clone(),
        );
        service.load();
        service.vault.writes.lock().unwrap().clear();
        service.vault.pause_writes.store(true, Ordering::SeqCst);
        let ticker = {
            let service = service.clone();
            clock.store(NOW + 10, Ordering::SeqCst);
            thread::spawn(move || service.tick())
        };
        // The tick is now paused inside the Keychain write of trial A.
        thread::sleep(Duration::from_millis(100));
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
        service.vault.open();
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
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(
            Stored {
                license: Some(paid_record("KEY-PAID", 25 * HOUR)),
                ..Stored::default()
            },
            clock,
        );
        service.load();
        // A revocation must never be undone by an older writer either.
        service.dodo.validate.lock().unwrap().push(Ok(Validation {
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
    fn launch_checks_regardless_of_recency_and_the_network_coming_back_checks_again() {
        let clock = Arc::new(AtomicI64::new(NOW));
        let service = service(
            Stored {
                license: Some(paid_record("KEY-PAID", HOUR)),
                ..Stored::default()
            },
            clock.clone(),
        );
        service
            .dodo
            .validate
            .lock()
            .unwrap()
            .push(Err(DodoError::Offline("down".into())));
        service.load();
        assert_eq!(service.dodo.calls().len(), 1, "the launch check ran");
        assert_eq!(
            service.state(),
            State::Licensed,
            "a network failure never revokes"
        );
        // Backoff is a minute away; the network is still down, so nothing is called.
        clock.store(NOW + 10, Ordering::SeqCst);
        service.tick();
        assert_eq!(service.dodo.calls().len(), 1);
        // The network is back: the poll notices and the check runs before the backoff ends.
        service.host.reachable.store(true, Ordering::SeqCst);
        clock.store(NOW + 20, Ordering::SeqCst);
        service.tick();
        assert_eq!(
            service.dodo.calls().len(),
            1,
            "polled at most every five minutes"
        );
        clock.store(
            NOW + REACHABILITY_POLL.as_secs() as i64 + 1,
            Ordering::SeqCst,
        );
        service.tick();
        assert_eq!(service.dodo.calls().len(), 2);
        assert_eq!(service.engine.lock().unwrap().schedule.failures, 0);
    }

    #[test]
    fn a_record_that_cannot_be_saved_leaves_the_old_activation_and_frees_the_slot() {
        struct FailingVault;
        impl Vault for FailingVault {
            fn load(&self) -> Result<Stored, String> {
                Ok(Stored {
                    license: Some(trial_record(DAY)),
                    trial_used: true,
                    ..Stored::default()
                })
            }
            fn save(&self, _: &Stored) -> Result<(), String> {
                Err("keychain locked".into())
            }
        }
        let service: Service<FakeDodo, FailingVault, FakeHost> = Service::new(
            FakeDodo::paid(),
            FailingVault,
            FakeHost::default(),
            Box::new(|| NOW),
        );
        service.load();
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
    }

    #[test]
    fn the_record_is_not_gated_before_it_is_read() {
        let service = service(Stored::default(), Arc::new(AtomicI64::new(NOW)));
        service.apply();
        assert!(!service.host.blocked.load(Ordering::SeqCst));
        assert!(!service.view().ready);
        service.load();
        assert!(service.view().ready);
        assert!(service.host.blocked.load(Ordering::SeqCst));
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
