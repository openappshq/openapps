//! The licensed build's plumbing around `core`: the Keychain record, the Dodo HTTP client,
//! the daily check scheduler, and the commands and events the settings window uses.

use super::core::Dodo;
use super::core::{
    Activation, DodoError, Engine, GRACE_WARNING_AFTER, KeyHint, LicenseError, Products, State,
    Stored, Validation,
};
use crate::engine::Controller;
use serde::Serialize;
use std::{
    sync::{Arc, Condvar, Mutex},
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

fn now() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}

/// The single Keychain item that holds the record. Never plain preferences.
mod vault {
    use super::Stored;

    #[cfg(target_os = "macos")]
    pub fn load() -> Result<Stored, String> {
        match security_framework::passwords::get_generic_password(
            super::KEYCHAIN_SERVICE,
            super::KEYCHAIN_ACCOUNT,
        ) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| format!("The saved license could not be read: {e}")),
            // errSecItemNotFound: nothing saved yet.
            Err(error) if error.code() == -25300 => Ok(Stored::default()),
            Err(error) => Err(format!("The Keychain could not be read: {error}")),
        }
    }

    #[cfg(target_os = "macos")]
    pub fn save(stored: &Stored) -> Result<(), String> {
        let bytes = serde_json::to_vec(stored).map_err(|e| e.to_string())?;
        security_framework::passwords::set_generic_password(
            super::KEYCHAIN_SERVICE,
            super::KEYCHAIN_ACCOUNT,
            &bytes,
        )
        .map_err(|error| format!("The license could not be saved to the Keychain: {error}"))
    }

    #[cfg(not(target_os = "macos"))]
    pub fn load() -> Result<Stored, String> {
        Ok(Stored::default())
    }

    #[cfg(not(target_os = "macos"))]
    pub fn save(_: &Stored) -> Result<(), String> {
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
        let retry_after = header("retry-after").and_then(|value| value.trim().parse::<i64>().ok());
        let body = tauri::async_runtime::block_on(response.bytes())
            .map_err(|error| DodoError::Offline(error.to_string()))?;
        let json = serde_json::from_slice(&body).unwrap_or(serde_json::Value::Null);
        Ok((status, server_time, retry_after, json))
    }

    fn error(status: u16, retry_after: Option<i64>) -> DodoError {
        match status {
            429 => DodoError::RateLimited {
                retry_after: retry_after.unwrap_or(60).clamp(1, 3600),
            },
            500..=599 => DodoError::Offline(format!("server error {status}")),
            _ => DodoError::Unexpected(format!("unexpected response {status}")),
        }
    }
}

impl super::core::Dodo for HttpDodo {
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
                        created_at: created_at.or(server_time).unwrap_or_else(now),
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

/// What the settings window shows. Mirrors the state table in LICENSING.md.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    pub revision: u64,
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
    checking: bool,
    last_error: Option<String>,
    pending_key: Option<String>,
}

pub struct Service {
    engine: Mutex<Engine>,
    meta: Mutex<Meta>,
    dodo: HttpDodo,
    /// One check at a time, whether from the scheduler or from the window.
    check: Mutex<()>,
    wake: (Mutex<bool>, Condvar),
    app: tauri::AppHandle,
}

impl Service {
    /// Loads the record and starts the background scheduler. Never delays launch: a failure to
    /// read the Keychain leaves the Mac unlicensed with the reason shown in Settings.
    pub fn start(app: &tauri::AppHandle) -> Result<(), String> {
        let (stored, load_error) = match vault::load() {
            Ok(stored) => (stored, None),
            Err(error) => (Stored::default(), Some(error)),
        };
        let service = Arc::new(Self {
            engine: Mutex::new(Engine::new(stored, products())),
            meta: Mutex::new(Meta {
                last_error: load_error,
                ..Meta::default()
            }),
            dodo: HttpDodo::new()?,
            check: Mutex::new(()),
            wake: (Mutex::new(false), Condvar::new()),
            app: app.clone(),
        });
        app.manage(service.clone());
        service.apply();
        std::thread::Builder::new()
            .name("openklack-license".into())
            .spawn(move || service.run())
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    fn run(&self) {
        loop {
            let at = now();
            let (next_check, next_transition) = {
                let engine = self.engine.lock().unwrap();
                (engine.next_check_at(at), engine.next_transition_at(at))
            };
            let wait = [next_check, next_transition]
                .into_iter()
                .flatten()
                .map(|due| Duration::from_secs((due - at).max(0) as u64))
                .min()
                .unwrap_or(MAX_SLEEP)
                .clamp(Duration::from_secs(1), MAX_SLEEP);
            {
                let (flag, condvar) = &self.wake;
                let mut woken = flag.lock().unwrap();
                if !*woken {
                    woken = condvar.wait_timeout(woken, wait).unwrap().0;
                }
                *woken = false;
            }
            if self.engine.lock().unwrap().check_due(now()) {
                let _ = self.check_once(false);
            }
            // Trials end and grace runs out by time alone.
            self.apply();
        }
    }

    /// Wakes the scheduler: after activation, on wake from sleep, or when asked to check now.
    pub fn poke(&self) {
        let (flag, condvar) = &self.wake;
        *flag.lock().unwrap() = true;
        condvar.notify_all();
    }

    fn check_once(&self, forced: bool) -> Result<State, LicenseError> {
        let Ok(_running) = self.check.try_lock() else {
            return Ok(self.engine.lock().unwrap().state(now()));
        };
        let now = now();
        // Read what the call needs, then release the engine so the window stays responsive
        // while the request is in flight.
        let (key, instance) = {
            let engine = self.engine.lock().unwrap();
            if !forced && !engine.check_due(now) {
                return Ok(engine.state(now));
            }
            if let Some(hold_until) = engine.schedule.hold_until
                && now < hold_until
            {
                return Err(LicenseError::RateLimited {
                    retry_after: hold_until - now,
                });
            }
            match engine.stored.license.as_ref() {
                Some(record) if !record.revoked => {
                    (record.license_key.clone(), record.instance_id.clone())
                }
                _ => return Ok(engine.state(now)),
            }
        };
        self.publish(|meta| meta.checking = true);
        let answer = self.dodo.validate(&key, &instance);
        let result = self.engine.lock().unwrap().check(&Replay(answer), now);
        self.persist();
        self.publish(|meta| {
            meta.checking = false;
            meta.last_error = result.as_ref().err().map(LicenseError::message);
        });
        result
    }

    fn persist(&self) {
        let stored = self.engine.lock().unwrap().stored.clone();
        if let Err(error) = vault::save(&stored) {
            self.publish(|meta| meta.last_error = Some(error));
        }
    }

    /// Reflects the state on the audio engine: only keyboard sound playback is gated.
    fn apply(&self) {
        let enabled = self.engine.lock().unwrap().core_feature(now());
        if let Some(controller) = self.app.try_state::<Arc<Controller>>() {
            controller.set_license_blocked(!enabled);
        }
        self.publish(|_| {});
    }

    fn view(&self) -> View {
        let now = now();
        let engine = self.engine.lock().unwrap();
        let meta = self.meta.lock().unwrap();
        let state = engine.state(now);
        View {
            revision: meta.revision,
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
        let _ = self.app.emit("license", &view);
        view
    }

    fn activate(&self, key: &str, hint: KeyHint) -> Result<View, String> {
        let _running = self.check.lock().unwrap();
        let result = self
            .engine
            .lock()
            .unwrap()
            .activate(key, hint, &self.dodo, now());
        self.persist();
        let outcome = result.map_err(|error| error.message());
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

    fn remove(&self) -> Result<View, String> {
        let _running = self.check.lock().unwrap();
        let result = self.engine.lock().unwrap().remove(&self.dodo, now());
        self.persist();
        let outcome = result.map_err(|error| error.message());
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
}

/// Hands the engine an answer that was fetched without holding its lock.
struct Replay(Result<Validation, DodoError>);

impl super::core::Dodo for Replay {
    fn activate(&self, _: &str, _: &str) -> Result<Activation, DodoError> {
        Err(DodoError::Unexpected("no activation during a check".into()))
    }
    fn validate(&self, _: &str, _: &str) -> Result<Validation, DodoError> {
        self.0.clone()
    }
    fn deactivate(&self, _: &str, _: &str) -> Result<(), DodoError> {
        Err(DodoError::Unexpected(
            "no deactivation during a check".into(),
        ))
    }
}

/// Called from the audio engine when the Mac wakes: checks again if the last one is a day old.
pub fn wake(app: &tauri::AppHandle) {
    if let Some(service) = app.try_state::<Arc<Service>>() {
        service.poke();
    }
}

pub fn opened(app: &tauri::AppHandle, urls: &[url::Url]) {
    if let Some(service) = app.try_state::<Arc<Service>>() {
        service.opened(urls);
    }
    let _ = crate::show_settings(app);
}

#[tauri::command]
pub fn license_status(state: tauri::State<'_, Arc<Service>>) -> View {
    state.view()
}

#[tauri::command]
pub async fn activate_license(
    state: tauri::State<'_, Arc<Service>>,
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
pub async fn remove_license(state: tauri::State<'_, Arc<Service>>) -> Result<View, String> {
    let service = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || service.remove())
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn check_license_now(state: tauri::State<'_, Arc<Service>>) -> Result<View, String> {
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
pub fn dismiss_license_key(state: tauri::State<'_, Arc<Service>>) -> View {
    state.publish(|meta| meta.pending_key = None)
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
pub fn start_license_trial(state: tauri::State<'_, Arc<Service>>) -> Result<View, String> {
    if state.engine.lock().unwrap().stored.trial_used {
        return Err(LicenseError::TrialUsed.message());
    }
    open_license_link("trial".into())?;
    Ok(state.view())
}
