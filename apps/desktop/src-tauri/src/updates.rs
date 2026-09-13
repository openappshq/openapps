use serde::Serialize;
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};
use tauri::{Emitter, Manager, async_runtime::Mutex as AsyncMutex};
use tauri_plugin_updater::{Config, Update, UpdaterExt};

// ponytail: Raise this ceiling only when measured release bundles need more than 128 MiB.
const MAX_UPDATE_BYTES: u64 = 128 * 1024 * 1024;
const UPDATE_TOO_LARGE: &str = "This update exceeds the 128 MB download limit.";

fn oversized_update(received: u64, total: Option<u64>) -> bool {
    received > MAX_UPDATE_BYTES || total.is_some_and(|total| total > MAX_UPDATE_BYTES)
}

fn update_error(error: tauri_plugin_updater::Error) -> String {
    use tauri_plugin_updater::Error;
    match error {
        Error::Reqwest(_) | Error::Network(_) => {
            "The update server could not be reached. Check your connection and try again.".into()
        }
        Error::ReleaseNotFound | Error::Serialization(_) => {
            "The update server returned an invalid release. Try again later.".into()
        }
        Error::TargetNotFound(_) | Error::TargetsNotFound(_) => {
            "This release does not include an update for your Mac.".into()
        }
        Error::Minisign(_) | Error::Base64(_) | Error::SignatureUtf8(_) => {
            "The update signature could not be verified. Nothing was installed.".into()
        }
        error => error.to_string(),
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Release {
    version: String,
    notes: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    revision: u64,
    configured: bool,
    current_version: String,
    phase: &'static str,
    available: Option<Release>,
    received: u64,
    total: Option<u64>,
    error: Option<String>,
}

pub struct Updates {
    pending: AsyncMutex<Option<Update>>,
    status: Mutex<Status>,
}

fn configured(value: Option<&serde_json::Value>) -> Result<bool, String> {
    let Some(value) = value else {
        return Ok(false);
    };
    let config: Config = serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
    if config.dangerous_insecure_transport_protocol
        || config.dangerous_accept_invalid_certs
        || config.dangerous_accept_invalid_hostnames
        || config.endpoints.iter().any(|url| url.scheme() != "https")
    {
        return Err("App updates require HTTPS with normal certificate verification.".into());
    }
    Ok(!config.pubkey.trim().is_empty() && !config.endpoints.is_empty())
}

pub fn init(app: &tauri::AppHandle) {
    let setup = configured(app.config().plugins.0.get("updater")).and_then(|enabled| {
        if enabled {
            app.plugin(tauri_plugin_updater::Builder::new().build())
                .map_err(|e| e.to_string())?;
        }
        Ok(enabled)
    });
    app.manage(Updates {
        pending: AsyncMutex::new(None),
        status: Mutex::new(Status {
            revision: 0,
            configured: setup.as_ref().copied().unwrap_or(false),
            current_version: app.package_info().version.to_string(),
            phase: "idle",
            available: None,
            received: 0,
            total: None,
            error: setup.err(),
        }),
    });
}

impl Updates {
    fn snapshot(&self) -> Status {
        self.status.lock().unwrap().clone()
    }

    fn publish(&self, app: &tauri::AppHandle, change: impl FnOnce(&mut Status)) -> Status {
        let next = {
            let mut status = self.status.lock().unwrap();
            change(&mut status);
            status.revision += 1;
            status.clone()
        };
        let _ = app.emit("app-update", &next);
        next
    }

    fn failed(&self, app: &tauri::AppHandle, error: String) -> Status {
        self.publish(app, |status| {
            status.phase = "error";
            status.error = Some(error);
        })
    }
}

#[tauri::command]
pub fn updater_status(state: tauri::State<'_, Updates>) -> Status {
    state.snapshot()
}

#[tauri::command]
pub async fn check_for_updates(
    app: tauri::AppHandle,
    state: tauri::State<'_, Updates>,
) -> Result<Status, String> {
    let Ok(mut pending) = state.pending.try_lock() else {
        return Ok(state.snapshot());
    };
    if !state.snapshot().configured {
        return Err("This build does not include an update service.".into());
    }
    *pending = None;
    state.publish(&app, |status| {
        status.phase = "checking";
        status.available = None;
        status.error = None;
    });
    let result = async {
        app.updater_builder()
            .timeout(Duration::from_secs(30))
            .configure_client(|client| {
                client
                    .https_only(true)
                    .connect_timeout(Duration::from_secs(10))
            })
            .build()?
            .check()
            .await
    }
    .await;
    match result {
        Ok(update) => {
            *pending = update.map(|mut update| {
                update.timeout = Some(Duration::from_secs(300));
                update
            });
            Ok(state.publish(&app, |status| {
                status.available = pending.as_ref().map(|update| Release {
                    version: update.version.clone(),
                    notes: update
                        .body
                        .as_ref()
                        .map(|notes| notes.chars().take(16_000).collect()),
                });
                status.phase = if status.available.is_some() {
                    "available"
                } else {
                    "current"
                };
            }))
        }
        Err(error) => Ok(state.failed(&app, update_error(error))),
    }
}

#[tauri::command]
pub async fn install_update(
    app: tauri::AppHandle,
    state: tauri::State<'_, Updates>,
    version: String,
) -> Result<Status, String> {
    let Ok(pending) = state.pending.try_lock() else {
        return Ok(state.snapshot());
    };
    let update = pending
        .as_ref()
        .filter(|update| update.version == version)
        .cloned()
        .ok_or("The available update changed. Check again before installing.")?;
    state.publish(&app, |status| {
        status.phase = "downloading";
        status.received = 0;
        status.total = None;
        status.error = None;
    });
    let mut received = 0u64;
    let mut last_progress = Instant::now();
    let (too_large, exceeded) = tokio::sync::oneshot::channel();
    let mut too_large = Some(too_large);
    let download = update.download(
        |chunk, total| {
            received += chunk as u64;
            if oversized_update(received, total) {
                if let Some(signal) = too_large.take() {
                    let _ = signal.send(());
                }
                return;
            }
            if last_progress.elapsed() >= Duration::from_millis(100) || total == Some(received) {
                last_progress = Instant::now();
                state.publish(&app, |status| {
                    status.received = received;
                    status.total = total;
                });
            }
        },
        || {
            state.publish(&app, |status| status.phase = "verifying");
        },
    );
    let result = tokio::select! {
        biased;
        Ok(()) = exceeded => Err(UPDATE_TOO_LARGE.to_string()),
        result = download => result.map_err(update_error),
    };
    let bytes = match result {
        Ok(bytes) if !oversized_update(bytes.len() as u64, None) => bytes,
        Ok(_) => return Ok(state.failed(&app, UPDATE_TOO_LARGE.into())),
        Err(error) => return Ok(state.failed(&app, error)),
    };
    state.publish(&app, |status| status.phase = "installing");
    match tauri::async_runtime::spawn_blocking(move || update.install(bytes)).await {
        Ok(Ok(())) => {
            state.publish(&app, |status| status.phase = "restarting");
            app.restart();
        }
        Ok(Err(error)) => Ok(state.failed(&app, update_error(error))),
        Err(error) => Ok(state.failed(&app, error.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn updates_need_explicit_secure_configuration_and_matching_app_versions() {
        assert_eq!(
            update_error(tauri_plugin_updater::Error::Network(
                "internal detail".into()
            )),
            "The update server could not be reached. Check your connection and try again."
        );
        assert!(!oversized_update(MAX_UPDATE_BYTES, None));
        assert!(oversized_update(MAX_UPDATE_BYTES + 1, None));
        assert!(oversized_update(1, Some(MAX_UPDATE_BYTES + 1)));
        assert!(!configured(None).unwrap());
        assert!(!configured(Some(&serde_json::json!({"pubkey":"", "endpoints":[]}))).unwrap());
        let mut config = serde_json::json!({"pubkey":"test-public-key", "endpoints":["https://example.invalid/latest.json"]});
        assert!(configured(Some(&config)).unwrap());
        config["dangerousAcceptInvalidCerts"] = true.into();
        assert!(configured(Some(&config)).is_err());
        config["dangerousAcceptInvalidCerts"] = false.into();
        config["endpoints"] = serde_json::json!(["http://example.invalid/latest.json"]);
        assert!(configured(Some(&config)).is_err());
        let bundle: serde_json::Value =
            serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        assert_eq!(bundle["version"].as_str(), Some(env!("CARGO_PKG_VERSION")));
    }
}
