//! The updater in official builds: checks the signed feed, downloads and verifies the update
//! archive in the background, unpacks and verifies the new bundle next to the app, and swaps it
//! in when the app quits or restarts.

use super::policy::{self, Offer, Saved, Source, Trigger};
use super::{Release, Settings, Status, install};
use semver::Version;
use std::{
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::{Emitter, Manager};
use tauri_plugin_updater::{Update, UpdaterExt};
use tokio::sync::{Mutex as AsyncMutex, Notify};

// ponytail: Raise this ceiling only when measured release bundles need more than 128 MiB.
const MAX_UPDATE_BYTES: u64 = 128 * 1024 * 1024;
const UPDATE_TOO_LARGE: &str = "This update exceeds the 128 MB download limit.";
const UNREACHABLE: &str =
    "The update server could not be reached. Check your connection and try again.";
const FEED_CHANGED: &str = "The update feed changed while checking. Try again.";
const MOVE_TO_APPLICATIONS: &str = "Move OpenKlack to Applications to enable updates.";
const AUTOMATIC_INSTALL_OFF: &str = "Automatic installs were turned off. Nothing was installed.";
/// How often the background task wakes to see whether a check is due. Timers pause while the Mac
/// sleeps, so a check that fell due during sleep runs at most this long after waking.
const TIMER: Duration = Duration::from_secs(5 * 60);

fn oversized_update(received: u64, total: Option<u64>) -> bool {
    received > MAX_UPDATE_BYTES || total.is_some_and(|total| total > MAX_UPDATE_BYTES)
}

fn update_error(error: tauri_plugin_updater::Error) -> String {
    use tauri_plugin_updater::Error;
    match error {
        Error::Reqwest(_) | Error::Network(_) => UNREACHABLE.into(),
        Error::ReleaseNotFound | Error::Serialization(_) => policy::INVALID_FEED.into(),
        Error::TargetNotFound(_) | Error::TargetsNotFound(_) => policy::NOT_FOR_THIS_MAC.into(),
        Error::Minisign(_) | Error::Base64(_) | Error::SignatureUtf8(_) => {
            policy::INVALID_SIGNATURE.into()
        }
        error => error.to_string(),
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}

/// Where updates come from and the key they must be signed with.
#[derive(Clone, Debug)]
pub struct Endpoint {
    feed: url::Url,
    signature: url::Url,
    public_key: String,
    downloads: String,
    https_only: bool,
}

fn loopback(url: &url::Url) -> bool {
    matches!(url.host_str(), Some("127.0.0.1" | "localhost"))
}

impl Endpoint {
    fn new(feed: &str, public_key: &str, downloads: &str) -> Result<Self, String> {
        let feed = url::Url::parse(feed).map_err(|e| e.to_string())?;
        let signature = url::Url::parse(&format!("{feed}.sig")).map_err(|e| e.to_string())?;
        let download = url::Url::parse(downloads).map_err(|e| e.to_string())?;
        let https_only = feed.scheme() == "https" && download.scheme() == "https";
        let secure = |url: &url::Url| url.scheme() == "https" || loopback(url);
        if !secure(&feed) || !secure(&download) || !downloads.ends_with('/') {
            return Err("App updates require HTTPS.".into());
        }
        if public_key.trim().is_empty() {
            return Err("This build has no update signing key.".into());
        }
        Ok(Self {
            feed,
            signature,
            public_key: public_key.trim().into(),
            downloads: downloads.into(),
            https_only,
        })
    }

    fn official() -> Result<Self, String> {
        Self::new(
            policy::FEED_URL,
            env!("OPENKLACK_UPDATE_PUBLIC_KEY"),
            policy::RELEASE_DOWNLOADS,
        )
    }

    /// Debug builds only: a local feed, key and download location for update tests. Release
    /// builds don't contain this.
    #[cfg(debug_assertions)]
    fn development() -> Option<Result<Self, String>> {
        let feed = std::env::var("OPENKLACK_DEV_UPDATE_FEED").ok()?;
        let key = std::env::var("OPENKLACK_DEV_UPDATE_PUBLIC_KEY").unwrap_or_default();
        let downloads = std::env::var("OPENKLACK_DEV_UPDATE_DOWNLOADS").unwrap_or_default();
        Some(Self::new(&feed, &key, &downloads))
    }

    fn client(&self) -> Result<reqwest::Client, String> {
        if rustls::crypto::CryptoProvider::get_default().is_none() {
            let _ = rustls::crypto::ring::default_provider().install_default();
        }
        reqwest::Client::builder()
            .https_only(self.https_only)
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::limited(3))
            .build()
            .map_err(|e| e.to_string())
    }
}

/// A plain GET, bounded in size. It carries no identifiers.
async fn get(client: &reqwest::Client, url: &url::Url, limit: usize) -> Result<Vec<u8>, String> {
    let mut response = client
        .get(url.clone())
        .send()
        .await
        .map_err(|_| UNREACHABLE)?;
    if !response.status().is_success() {
        return Err(UNREACHABLE.into());
    }
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return Err(policy::INVALID_FEED.into());
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| UNREACHABLE)? {
        body.extend_from_slice(&chunk);
        if body.len() > limit {
            return Err(policy::INVALID_FEED.into());
        }
    }
    Ok(body)
}

/// Fetches the feed and its signature and returns a verified newer release, if any.
pub async fn fetch_offer(endpoint: &Endpoint, current: &Version) -> Result<Option<Offer>, String> {
    let client = endpoint.client()?;
    let (feed, signature) = tokio::join!(
        get(&client, &endpoint.feed, policy::MAX_FEED_BYTES),
        get(
            &client,
            &endpoint.signature,
            policy::MAX_FEED_SIGNATURE_BYTES
        )
    );
    let source = Source {
        public_key: &endpoint.public_key,
        downloads: &endpoint.downloads,
        arch: std::env::consts::ARCH,
        macos: macos_version(),
    };
    policy::read_feed(&feed?, &signature?, &source, current)
}

/// The fetch an automatic check would make, gated exactly as the background task gates it.
#[cfg(test)]
async fn automatic_fetch(
    saved: &Saved,
    trigger: Trigger,
    endpoint: &Endpoint,
    current: &Version,
) -> Option<Result<Option<Offer>, String>> {
    if !policy::automatic_check_due(saved, now(), trigger) {
        return None;
    }
    Some(fetch_offer(endpoint, current).await)
}

fn macos_version() -> Option<Version> {
    let mut buffer = [0u8; 32];
    let mut length = buffer.len();
    let status = unsafe {
        libc::sysctlbyname(
            c"kern.osproductversion".as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return None;
    }
    let text = std::str::from_utf8(&buffer[..length]).ok()?;
    policy::macos_version(text.trim_end_matches('\0'))
}

/// The app replaces its own bundle, so it needs write access to the bundle and the folder holding
/// it. A disk image, a read-only folder or App Translocation can't be updated in place.
fn location_blocked(bundle: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let writable = |path: &Path| {
        std::ffi::CString::new(path.as_os_str().as_bytes())
            .is_ok_and(|path| unsafe { libc::access(path.as_ptr(), libc::W_OK) } == 0)
    };
    bundle.to_string_lossy().contains("/AppTranslocation/")
        || !bundle.parent().is_some_and(writable)
        || !writable(bundle)
}

/// A verified bundle waiting next to the app. `automatic` means nobody asked for it: the
/// "Download and install automatically" setting did, and turning that off discards it.
struct Staged {
    version: String,
    bundle: PathBuf,
    automatic: bool,
}

pub struct Updates {
    endpoint: Result<Endpoint, String>,
    store: PathBuf,
    /// The installed bundle, when the app runs from one it can replace.
    bundle: Option<PathBuf>,
    location_blocked: bool,
    busy: AsyncMutex<()>,
    saved: Mutex<Saved>,
    pending: Mutex<Option<Update>>,
    staged: Mutex<Option<Staged>>,
    status: Mutex<Status>,
    wake: Notify,
}

fn load(store: &Path) -> Saved {
    std::fs::read(store)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

pub fn init(app: &tauri::AppHandle) {
    let data = app.path().app_data_dir().unwrap_or_default();
    let store = data.join("updates.json");
    let saved = load(&store);
    #[cfg(debug_assertions)]
    let endpoint = Endpoint::development().unwrap_or_else(Endpoint::official);
    #[cfg(not(debug_assertions))]
    let endpoint = Endpoint::official();
    let endpoint = endpoint.and_then(|endpoint| {
        app.plugin(
            tauri_plugin_updater::Builder::new()
                .pubkey(endpoint.public_key.clone())
                .build(),
        )
        .map_err(|e| e.to_string())?;
        Ok(endpoint)
    });
    let bundle = std::env::current_exe()
        .ok()
        .and_then(|exe| tauri_plugin_updater::extract_path_from_executable(&exe).ok())
        .filter(|path| path.extension().is_some_and(|extension| extension == "app"));
    let location_blocked = bundle.as_deref().is_none_or(location_blocked);
    // A swap interrupted last time, or a bundle staged by an earlier run, is cleaned up first;
    // a staged bundle has lost the verified download it belonged to.
    if let Some(bundle) = &bundle {
        install::recover(bundle);
    }
    let status = Status {
        revision: 0,
        supported: true,
        configured: endpoint.is_ok(),
        location_blocked,
        current_version: app.package_info().version.to_string(),
        settings: saved.settings,
        phase: "idle",
        available: None,
        received: 0,
        total: None,
        error: None,
        last_checked_at: saved.history.last_success_at,
    };
    let configured = endpoint.is_ok();
    app.manage(Updates {
        endpoint,
        store,
        bundle,
        location_blocked,
        busy: AsyncMutex::new(()),
        saved: Mutex::new(saved),
        pending: Mutex::new(None),
        staged: Mutex::new(None),
        status: Mutex::new(status),
        wake: Notify::new(),
    });
    if configured {
        schedule(app.clone());
    }
}

/// Wakes at launch, then every few minutes, and checks only when [`policy::automatic_check_due`]
/// says so. With automatic checks off (the default) it never makes a request.
fn schedule(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        let updates = app.state::<Updates>();
        let mut trigger = Trigger::Launch;
        loop {
            let saved = *updates.saved.lock().unwrap();
            let staged = updates.staged.lock().unwrap().is_some();
            if !staged && policy::automatic_check_due(&saved, now(), trigger) {
                check(&app, &updates).await;
            }
            trigger = Trigger::Timer;
            tokio::select! {
                _ = tokio::time::sleep(TIMER) => {}
                _ = updates.wake.notified() => {}
            }
        }
    });
}

impl Updates {
    fn snapshot(&self) -> Status {
        self.status.lock().unwrap().clone()
    }

    fn publish(&self, app: &tauri::AppHandle, change: impl FnOnce(&mut Status)) -> Status {
        let (next, ready_changed) = {
            let mut status = self.status.lock().unwrap();
            let was_ready = status.phase == "ready";
            change(&mut status);
            status.revision += 1;
            (status.clone(), was_ready != (status.phase == "ready"))
        };
        let _ = app.emit("app-update", &next);
        if ready_changed
            && let Some(controller) = app.try_state::<std::sync::Arc<crate::engine::Controller>>()
        {
            crate::refresh_tray(app, controller.snapshot());
        }
        next
    }

    /// Writes the file while holding the `saved` lock, so two changes can never race each other
    /// onto disk with a stale snapshot.
    fn write(&self, saved: &Saved) -> Result<(), String> {
        if let Some(parent) = self.store.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let bytes = serde_json::to_vec_pretty(saved).map_err(|e| e.to_string())?;
        crate::library::write_atomic(&self.store, &bytes)
    }

    /// History is best effort: if it can't be saved, a restart may check a little early.
    fn record(&self, change: impl FnOnce(&mut policy::History)) {
        let mut saved = self.saved.lock().unwrap();
        change(&mut saved.history);
        let _ = self.write(&saved);
    }

    /// Saves the settings first; they take effect only once saved.
    fn update_settings(&self, settings: Settings) -> Result<(), String> {
        let mut saved = self.saved.lock().unwrap();
        let next = Saved {
            settings,
            history: saved.history,
        };
        self.write(&next)?;
        *saved = next;
        Ok(())
    }

    fn may_install(&self, automatic: bool) -> bool {
        policy::may_install(automatic, &self.saved.lock().unwrap().settings)
    }

    /// Drops the staged bundle, if any, and reports why.
    fn discard_staged(&self, app: &tauri::AppHandle, reason: &str) {
        let Some(staged) = self.staged.lock().unwrap().take() else {
            return;
        };
        if let Some(bundle) = &self.bundle {
            let _ = std::fs::remove_dir_all(install::staging_dir(bundle));
        }
        eprintln!(
            "OpenKlack: discarded the staged {} update: {reason}",
            staged.version
        );
        self.publish(app, |status| {
            if status.phase == "ready" {
                status.phase = if status.available.is_some() {
                    "available"
                } else {
                    "idle"
                };
            }
        });
    }

    fn failed(&self, app: &tauri::AppHandle, error: String) {
        self.record(|history| history.failed(now()));
        self.publish(app, |status| {
            status.phase = "error";
            status.error = Some(error);
        });
    }
}

/// One check at a time; a check while another runs, or once an update is staged, does nothing.
async fn check(app: &tauri::AppHandle, updates: &Updates) {
    let Ok(_busy) = updates.busy.try_lock() else {
        return;
    };
    let Ok(endpoint) = updates.endpoint.clone() else {
        return;
    };
    if updates.staged.lock().unwrap().is_some() {
        return;
    }
    *updates.pending.lock().unwrap() = None;
    updates.publish(app, |status| {
        status.phase = "checking";
        status.available = None;
        status.error = None;
    });
    let current = app.package_info().version.clone();
    let found = async {
        let Some(offer) = fetch_offer(&endpoint, &current).await? else {
            return Ok(None);
        };
        // The plugin fetches the feed again to build its update. It must be the feed that was
        // just verified, byte for byte in meaning, or nothing from it is used.
        let https_only = endpoint.https_only;
        let update = app
            .updater_builder()
            .endpoints(vec![endpoint.feed.clone()])
            .map_err(update_error)?
            .pubkey(endpoint.public_key.clone())
            .timeout(Duration::from_secs(30))
            .configure_client(move |client| {
                client
                    .https_only(https_only)
                    .connect_timeout(Duration::from_secs(10))
            })
            .build()
            .map_err(update_error)?
            .check()
            .await
            .map_err(update_error)?;
        match update {
            Some(update)
                if update.raw_json == offer.json
                    && update.version == offer.version.to_string()
                    && update.download_url.as_str() == offer.archive_url
                    && update.signature == offer.archive_signature =>
            {
                Ok(Some((offer, update)))
            }
            _ => Err(FEED_CHANGED.to_string()),
        }
    }
    .await;
    match found {
        Err(error) => updates.failed(app, error),
        Ok(None) => {
            let now = now();
            updates.record(|history| history.succeeded(now));
            updates.publish(app, |status| {
                status.phase = "current";
                status.last_checked_at = Some(now);
            });
        }
        Ok(Some((offer, update))) => {
            let now = now();
            updates.record(|history| history.succeeded(now));
            *updates.pending.lock().unwrap() = Some(update);
            updates.publish(app, |status| {
                status.phase = "available";
                status.last_checked_at = Some(now);
                status.available = Some(Release {
                    version: offer.version.to_string(),
                    notes: offer.notes,
                });
            });
            if updates.may_install(true) && !updates.location_blocked {
                download(app, updates, true).await;
            }
        }
    }
}

/// Downloads and verifies the pending update, unpacks it next to the app, verifies the bundle
/// and stages it for the next quit. Callers hold `busy`. Nothing is installed here, so sound
/// playback is never interrupted. An `automatic` download is dropped if automatic installs are
/// turned off while it runs.
async fn download(app: &tauri::AppHandle, updates: &Updates, automatic: bool) {
    let Ok(endpoint) = updates.endpoint.clone() else {
        return;
    };
    let Some(installed) = updates.bundle.clone().filter(|_| !updates.location_blocked) else {
        return updates.failed(app, MOVE_TO_APPLICATIONS.into());
    };
    let Some(update) = updates.pending.lock().unwrap().clone() else {
        return;
    };
    updates.publish(app, |status| {
        status.phase = "downloading";
        status.received = 0;
        status.total = None;
        status.error = None;
    });
    let mut received = 0u64;
    let mut last_progress = Instant::now();
    let (too_large, exceeded) = tokio::sync::oneshot::channel();
    let mut too_large = Some(too_large);
    let mut update = update;
    update.timeout = Some(Duration::from_secs(300));
    let fetched = update.download(
        |chunk, total| {
            received += chunk as u64;
            if oversized_update(received, total) {
                if let Some(signal) = too_large.take() {
                    let _ = signal.send(());
                }
                return;
            }
            if last_progress.elapsed() >= Duration::from_millis(250) || total == Some(received) {
                last_progress = Instant::now();
                updates.publish(app, |status| {
                    status.received = received;
                    status.total = total;
                });
            }
        },
        || {
            updates.publish(app, |status| status.phase = "verifying");
        },
    );
    let result = tokio::select! {
        biased;
        Ok(()) = exceeded => Err(UPDATE_TOO_LARGE.to_string()),
        result = fetched => result.map_err(update_error),
    };
    let version = update.version.clone();
    let public_key = endpoint.public_key.clone();
    let signature = update.signature.clone();
    let staged = match result {
        Ok(bytes) => {
            let installed = installed.clone();
            let version = version.clone();
            tauri::async_runtime::spawn_blocking(move || {
                if oversized_update(bytes.len() as u64, None) {
                    return Err(UPDATE_TOO_LARGE.to_string());
                }
                policy::verify(&bytes, &signature, &public_key)?;
                let bundle = install::unpack(&bytes, &installed)?;
                install::verify_bundle(&bundle, &installed, &version).inspect_err(|_| {
                    let _ = std::fs::remove_dir_all(install::staging_dir(&installed));
                })?;
                Ok(bundle)
            })
            .await
            .map_err(|e| e.to_string())
            .and_then(|result| result)
        }
        Err(error) => Err(error),
    };
    match staged {
        Err(error) => updates.failed(app, error),
        // Permission is checked again here: it may have been withdrawn during the download.
        Ok(_) if !updates.may_install(automatic) => {
            let _ = std::fs::remove_dir_all(install::staging_dir(&installed));
            eprintln!(
                "OpenKlack: dropped the automatic {version} download: {AUTOMATIC_INSTALL_OFF}"
            );
            updates.publish(app, |status| status.phase = "available");
        }
        Ok(bundle) => {
            *updates.staged.lock().unwrap() = Some(Staged {
                version,
                bundle,
                automatic,
            });
            updates.publish(app, |status| status.phase = "ready");
            #[cfg(debug_assertions)]
            if std::env::var_os("OPENKLACK_DEV_QUIT_WHEN_UPDATE_READY").is_some() {
                app.exit(0);
            }
        }
    }
}

/// Installs a staged update while the app exits, before it quits or restarts. The bundle is
/// verified again first, since it waited on disk, and an automatic one only installs if
/// automatic installs are still on. The swap runs to completion on this thread: the process
/// never exits in the middle of it.
pub fn install_on_exit(app: &tauri::AppHandle) {
    let Some(updates) = app.try_state::<Updates>() else {
        return;
    };
    let Some(installed) = updates.bundle.clone() else {
        return;
    };
    let Some(staged) = updates.staged.lock().unwrap().take() else {
        return;
    };
    if !updates.may_install(staged.automatic) {
        let _ = std::fs::remove_dir_all(install::staging_dir(&installed));
        eprintln!(
            "OpenKlack: the staged {} update was not installed: {AUTOMATIC_INSTALL_OFF}",
            staged.version
        );
        return;
    }
    let result = install::verify_bundle(&staged.bundle, &installed, &staged.version)
        .and_then(|()| install::swap(&installed, &staged.bundle, &mut |_| Ok(())));
    match result {
        Ok(()) => eprintln!("OpenKlack: installed the staged update."),
        Err(error) => {
            let _ = std::fs::remove_dir_all(install::staging_dir(&installed));
            eprintln!("OpenKlack: the staged update was not installed: {error}");
        }
    }
}

pub fn ready(app: &tauri::AppHandle) -> bool {
    app.try_state::<Updates>()
        .is_some_and(|updates| updates.staged.lock().unwrap().is_some())
}

/// Quits and reopens the app; the staged update installs on the way out.
pub fn restart(app: &tauri::AppHandle) {
    if ready(app) {
        app.request_restart();
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
    if let Err(error) = &state.endpoint {
        return Err(error.clone());
    }
    check(&app, &state).await;
    Ok(state.snapshot())
}

#[tauri::command]
pub async fn download_update(
    app: tauri::AppHandle,
    state: tauri::State<'_, Updates>,
) -> Result<Status, String> {
    let Ok(_busy) = state.busy.try_lock() else {
        return Ok(state.snapshot());
    };
    if state.staged.lock().unwrap().is_some() {
        return Ok(state.snapshot());
    }
    if state.pending.lock().unwrap().is_none() {
        return Err("Check for updates before downloading.".into());
    }
    download(&app, &state, false).await;
    Ok(state.snapshot())
}

/// Saves the choice first; it takes effect only once saved. Turning automatic installs off
/// discards an update that was staged automatically; one the user asked for stays.
#[tauri::command]
pub fn set_update_settings(
    app: tauri::AppHandle,
    state: tauri::State<'_, Updates>,
    settings: Settings,
) -> Result<Status, String> {
    state.update_settings(settings)?;
    if state
        .staged
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|staged| !policy::may_install(staged.automatic, &settings))
    {
        state.discard_staged(&app, AUTOMATIC_INSTALL_OFF);
    }
    let status = state.publish(&app, |status| status.settings = settings);
    if settings.check_automatically {
        state.wake.notify_one();
    }
    Ok(status)
}

#[tauri::command]
pub fn restart_to_update(app: tauri::AppHandle) -> Result<(), String> {
    if !ready(&app) {
        return Err("No update is ready to install.".into());
    }
    restart(&app);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A loopback server that counts requests and answers each with 404.
    fn counting_server() -> (String, Arc<AtomicUsize>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(AtomicUsize::new(0));
        let counted = requests.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                counted.fetch_add(1, Ordering::SeqCst);
                let mut buffer = [0u8; 4096];
                let _ = stream.read(&mut buffer);
                let _ = stream.write_all(
                    b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                );
            }
        });
        (origin, requests)
    }

    #[test]
    fn a_fresh_install_makes_no_feed_request() {
        let (origin, requests) = counting_server();
        let endpoint = Endpoint::new(
            &format!("{origin}/updates/openklack/latest.json"),
            "key",
            &format!("{origin}/releases/download/"),
        )
        .unwrap();
        let current = Version::new(0, 1, 0);
        let fresh = Saved::default();
        tauri::async_runtime::block_on(async {
            for trigger in [Trigger::Launch, Trigger::Timer] {
                assert!(
                    automatic_fetch(&fresh, trigger, &endpoint, &current)
                        .await
                        .is_none()
                );
            }
        });
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(requests.load(Ordering::SeqCst), 0);

        // Control: with automatic checks on, the same path does reach the server.
        let mut enabled = fresh;
        enabled.settings.check_automatically = true;
        let result = tauri::async_runtime::block_on(automatic_fetch(
            &enabled,
            Trigger::Launch,
            &endpoint,
            &current,
        ));
        assert_eq!(result, Some(Err(UNREACHABLE.to_string())));
        assert!(requests.load(Ordering::SeqCst) >= 1);
    }

    #[test]
    fn endpoints_require_https_except_on_loopback_and_a_key() {
        assert!(Endpoint::new(policy::FEED_URL, "key", policy::RELEASE_DOWNLOADS).is_ok());
        assert!(
            Endpoint::new(
                "http://openapps.space/updates/openklack/latest.json",
                "key",
                policy::RELEASE_DOWNLOADS
            )
            .is_err()
        );
        assert!(
            Endpoint::new(
                policy::FEED_URL,
                "key",
                "http://github.com/openappshq/openapps/releases/download/"
            )
            .is_err()
        );
        assert!(Endpoint::new(policy::FEED_URL, " ", policy::RELEASE_DOWNLOADS).is_err());
        let local = Endpoint::new(
            "http://127.0.0.1:8080/latest.json",
            "key",
            "http://127.0.0.1:8080/releases/",
        )
        .unwrap();
        assert!(!local.https_only);
        assert_eq!(
            local.signature.as_str(),
            "http://127.0.0.1:8080/latest.json.sig"
        );
    }

    #[test]
    fn update_errors_are_bounded_and_readable() {
        assert_eq!(
            update_error(tauri_plugin_updater::Error::Network(
                "internal detail".into()
            )),
            UNREACHABLE
        );
        assert!(!oversized_update(MAX_UPDATE_BYTES, None));
        assert!(oversized_update(MAX_UPDATE_BYTES + 1, None));
        assert!(oversized_update(1, Some(MAX_UPDATE_BYTES + 1)));
        assert!(location_blocked(Path::new("/nonexistent/OpenKlack.app")));
        assert!(macos_version().is_some());
        let bundle: serde_json::Value =
            serde_json::from_str(include_str!("../../tauri.conf.json")).unwrap();
        assert_eq!(bundle["version"].as_str(), Some(env!("CARGO_PKG_VERSION")));
        // The updater's configuration comes from the release overlay, never from source builds.
        assert!(bundle.get("plugins").is_none());
    }
}
