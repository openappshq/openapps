use crate::{
    audio::{self, Cancellable, Playback, PreparedPack, Voices},
    diagnostics::Metrics,
    library::Library,
    model::{Preferences, Runtime},
};
use rodio::Source;
use serde::Serialize;
use std::{
    collections::{HashMap, HashSet},
    ffi::{CStr, c_char},
    fs,
    path::PathBuf,
    sync::{
        Arc, Mutex, OnceLock, RwLock,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
    },
    time::{Duration, Instant},
};
use tauri::Emitter;

static INPUT: OnceLock<SyncSender<Message>> = OnceLock::new();
static OVERFLOW: AtomicBool = AtomicBool::new(false);

pub enum Message {
    Native(i32, u16, String, Instant),
    Preview(Arc<PreparedPack>, mpsc::Sender<Result<u64, String>>),
    PreviewKey(String),
    Refresh,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub version: String,
    pub revision: u64,
    pub preferences: Preferences,
    pub runtime: Runtime,
    pub pause_reason: Option<String>,
    pub effective_preset_id: String,
    pub recovery_notices: Vec<String>,
}

pub struct Controller {
    pub library: Library,
    pub data_directory: PathBuf,
    pub sender: SyncSender<Message>,
    pub visible: AtomicBool,
    app: tauri::AppHandle,
    playback: RwLock<Arc<Playback>>,
    cache: Mutex<HashMap<String, Arc<PreparedPack>>>,
    update_lock: Mutex<()>,
    runtime: Mutex<Runtime>,
    voices: Arc<Voices>,
    output_failed: Arc<AtomicBool>,
    recovery_notices: Vec<String>,
    pub metrics: Arc<Metrics>,
}

impl Controller {
    pub fn start(
        app: tauri::AppHandle,
        directory: PathBuf,
        data_directory: PathBuf,
    ) -> Result<Arc<Self>, String> {
        fs::create_dir_all(&data_directory).map_err(|e| e.to_string())?;
        let library = Library::open(directory, &data_directory)?;
        let preferences_file = data_directory.join("settings.json");
        let (mut prefs, recovery) = if preferences_file.exists() {
            let bytes = fs::read(&preferences_file).map_err(|e| e.to_string())?;
            match serde_json::from_slice::<Preferences>(&bytes)
                .map_err(|e| e.to_string())
                .and_then(|mut prefs| {
                    library.migrate_preferences(&mut prefs);
                    prefs.validate_shape()?;
                    Ok(prefs)
                }) {
                Ok(prefs) => (prefs, None),
                Err(_) => {
                    fs::copy(
                        &preferences_file,
                        data_directory.join(format!(
                            "settings-recovery-{}.json",
                            crate::library::unique_suffix()
                        )),
                    )
                    .map_err(|e| e.to_string())?;
                    (
                        Preferences::default(),
                        Some("Settings could not be loaded. A recovery copy has been kept.".into()),
                    )
                }
            }
        } else {
            (Preferences::default(), None)
        };
        library.migrate_preferences(&mut prefs);
        prefs.validate_shape()?;
        let mut recovery_notices = library.warnings.clone();
        recovery_notices.extend(recovery);
        recovery_notices.sort();
        recovery_notices.dedup();
        let (sender, receiver) = mpsc::sync_channel(512);
        let controller = Arc::new(Self {
            library,
            data_directory,
            sender,
            visible: AtomicBool::new(false),
            app,
            playback: RwLock::new(Arc::new(Playback {
                revision: 0,
                prefs: prefs.clone(),
                packs: HashMap::new(),
            })),
            cache: Mutex::new(HashMap::new()),
            update_lock: Mutex::new(()),
            runtime: Mutex::new(Runtime {
                microphone: 2,
                ..Runtime::default()
            }),
            voices: Arc::new(Voices::default()),
            output_failed: Arc::new(AtomicBool::new(false)),
            recovery_notices,
            metrics: Arc::new(Metrics::default()),
        });
        if let Err(error) = controller.prepare(prefs, true, None) {
            controller.runtime.lock().unwrap().configuration_error = Some(error);
        }
        INPUT
            .set(controller.sender.clone())
            .map_err(|_| "The input engine is already running.")?;
        let worker = controller.clone();
        std::thread::Builder::new()
            .name("openklack-audio".into())
            .spawn(move || {
                let mut output = worker.reopen_output();
                let mut pressed = KeyTracker::default();
                let mut variant = 0usize;
                loop {
                    let message = match receiver.recv_timeout(Duration::from_secs(2)) {
                        Ok(message) => message,
                        Err(mpsc::RecvTimeoutError::Timeout) => {
                            if (output.is_none() || worker.output_failed.load(Ordering::Relaxed))
                                && !worker.runtime.lock().unwrap().suspended
                            {
                                drop(output.take());
                                output = worker.reopen_output();
                            }
                            continue;
                        }
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    };
                    if OVERFLOW.swap(false, Ordering::Relaxed) {
                        worker
                            .metrics
                            .queue_overflows
                            .fetch_add(1, Ordering::Relaxed);
                        pressed.clear();
                        worker.cancel();
                    }
                    if worker.output_failed.load(Ordering::Relaxed)
                        && !worker.runtime.lock().unwrap().suspended
                    {
                        drop(output.take());
                        output = worker.reopen_output();
                    }
                    match message {
                        Message::Native(kind, physical, value, received) if kind < 2 => {
                            let Some(key) = pressed.event(physical, &value, kind == 0) else {
                                continue;
                            };
                            (if kind == 0 {
                                &worker.metrics.presses
                            } else {
                                &worker.metrics.releases
                            })
                            .fetch_add(1, Ordering::Relaxed);
                            if worker.visible.load(Ordering::Relaxed) {
                                let _ = worker.app.emit(
                                    "key",
                                    serde_json::json!({"key": key, "down": kind == 0}),
                                );
                            }
                            let playback = worker.playback.read().unwrap().clone();
                            let runtime = worker.runtime.lock().unwrap().clone();
                            if runtime.pause_reason(&playback.prefs).is_some() {
                                worker.metrics.paused_events.fetch_add(1, Ordering::Relaxed);
                                continue;
                            }
                            // A Weyl sequence changes sample choices without a RNG allocation per stroke.
                            variant = variant.wrapping_add(0x9e3779b9);
                            if let (Some(sink), Some((sample, gain))) = (
                                &output,
                                playback.sample(&runtime.frontmost_app, &key, kind == 0, variant),
                            ) {
                                worker.metrics.queued_sounds.fetch_add(1, Ordering::Relaxed);
                                sink.mixer().add(
                                    Cancellable::new(sample.amplify(gain), worker.voices.clone())
                                        .measured(received, worker.metrics.clone()),
                                );
                            }
                        }
                        Message::Native(2, _, _, _) => {
                            pressed.clear();
                            worker.cancel();
                            let _ = worker.app.emit("keys-reset", ());
                        }
                        Message::Native(kind, value, text, _) => {
                            {
                                let mut runtime = worker.runtime.lock().unwrap();
                                match kind {
                                    100 => runtime.input_permission = value != 0,
                                    101 => {
                                        if runtime.resume_app.is_none() && matches!(value, 0 | 3) {
                                            runtime.temporary_resume = false;
                                        }
                                        runtime.microphone = value;
                                    }
                                    102 => runtime.suspended = value != 0,
                                    104 => {
                                        if runtime
                                            .resume_app
                                            .as_ref()
                                            .is_some_and(|app| app != &text)
                                        {
                                            runtime.temporary_resume = false;
                                            runtime.resume_app = None;
                                        }
                                        runtime.frontmost_app = text;
                                    }
                                    105 => runtime.secure_input = value != 0,
                                    _ => {}
                                }
                            }
                            if matches!(kind, 100 | 102 | 105) {
                                pressed.clear();
                                let _ = worker.app.emit("keys-reset", ());
                            }
                            worker.cancel();
                            if kind == 102 && value != 0 {
                                output = None;
                                worker.runtime.lock().unwrap().audio_ready = false;
                            }
                            if kind == 103 && !worker.runtime.lock().unwrap().suspended {
                                drop(output.take());
                                output = worker.reopen_output();
                            }
                            worker.publish();
                        }
                        Message::Preview(pack, completed) => {
                            let mut duration = Duration::ZERO;
                            if let Some(sink) = &output {
                                worker.cancel();
                                let snapshot = worker.snapshot();
                                let preset = snapshot.preferences.preset("");
                                let volume = preset.volume / 100.0;
                                for (index, key) in
                                    ["KeyA", "KeyS", "KeyD", "Space", "KeyF", "Enter"]
                                        .iter()
                                        .enumerate()
                                {
                                    if let Some((down, up)) =
                                        pack.keys.get(*key).or_else(|| pack.keys.get("default"))
                                    {
                                        for (samples, release) in [(down, false), (up, true)] {
                                            if let Some(sample) = samples.get(if preset.variation {
                                                index % samples.len().max(1)
                                            } else {
                                                0
                                            }) {
                                                let sample = crate::shaping::shape(
                                                    sample.clone(),
                                                    preset,
                                                    key,
                                                );
                                                let delay = Duration::from_millis(
                                                    index as u64 * 145
                                                        + if release { 65 } else { 0 },
                                                );
                                                duration = duration.max(
                                                    delay
                                                        + sample
                                                            .total_duration()
                                                            .unwrap_or_default(),
                                                );
                                                sink.mixer().add(Cancellable::new(
                                                    sample
                                                        .amplify(
                                                            volume
                                                                * pack.gain
                                                                * if release {
                                                                    preset.release_volume / 100.0
                                                                } else {
                                                                    1.0
                                                                },
                                                        )
                                                        .delay(delay),
                                                    worker.voices.clone(),
                                                ));
                                            }
                                        }
                                    }
                                }
                                let _ = completed.send(Ok(duration.as_millis() as u64));
                            } else {
                                let _ = completed.send(Err(
                                    "Audio output unavailable. Check your Mac’s selected output."
                                        .into(),
                                ));
                            }
                        }
                        Message::PreviewKey(key) => {
                            let playback = worker.playback.read().unwrap().clone();
                            if let Some(sink) = &output {
                                for down in [true, false] {
                                    if let Some((sample, gain)) =
                                        playback.sample("", &key, down, variant)
                                    {
                                        sink.mixer().add(Cancellable::new(
                                            sample.amplify(gain).delay(Duration::from_millis(
                                                if down { 0 } else { 65 },
                                            )),
                                            worker.voices.clone(),
                                        ));
                                    }
                                }
                                variant = variant.wrapping_add(0x9e3779b9);
                            }
                        }
                        Message::Refresh => {
                            worker.cancel();
                            worker.publish();
                        }
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        Ok(controller)
    }

    fn cancel(&self) {
        self.voices.generation.fetch_add(1, Ordering::Relaxed);
        let _ = self.app.emit("preview-stopped", ());
    }

    fn reopen_output(&self) -> Option<rodio::MixerDeviceSink> {
        self.metrics.output_restarts.fetch_add(1, Ordering::Relaxed);
        self.output_failed.store(false, Ordering::Relaxed);
        let result = audio::open_output(self.output_failed.clone());
        {
            let mut runtime = self.runtime.lock().unwrap();
            runtime.audio_ready = result.is_ok();
            runtime.audio_error = result.as_ref().err().cloned();
            runtime.output_sample_rate = result
                .as_ref()
                .map_or(0, |s| s.config().sample_rate().get());
        }
        self.publish();
        result.ok()
    }

    pub fn snapshot(&self) -> Snapshot {
        let playback = self.playback.read().unwrap().clone();
        let runtime = self.runtime.lock().unwrap().clone();
        Snapshot {
            version: self.app.package_info().version.to_string(),
            revision: playback.revision,
            pause_reason: runtime.pause_reason(&playback.prefs).map(str::to_owned),
            effective_preset_id: playback.prefs.preset(&runtime.frontmost_app).id.clone(),
            preferences: playback.prefs.clone(),
            runtime,
            recovery_notices: self.recovery_notices.clone(),
        }
    }

    pub fn loaded_audio_bytes(&self) -> usize {
        self.cache
            .lock()
            .unwrap()
            .values()
            .map(|pack| pack.decoded_bytes)
            .sum()
    }

    fn publish(&self) {
        let snapshot = self.snapshot();
        let _ = self.app.emit("state", &snapshot);
        crate::refresh_tray(&self.app, snapshot);
    }

    pub fn load_pack(&self, id: &str) -> Result<Arc<PreparedPack>, String> {
        let mut cache = self.cache.lock().unwrap();
        if !cache.contains_key(id) {
            cache.retain(|_, pack| Arc::strong_count(pack) > 1);
            let pack = self.library.pack(id)?;
            let directory = self.library.verified_directory(id)?;
            cache.insert(id.into(), Arc::new(audio::decode_pack(&pack, &directory)?));
        }
        Ok(cache[id].clone())
    }

    pub fn prepare(
        &self,
        prefs: Preferences,
        persist: bool,
        expected_revision: Option<u64>,
    ) -> Result<Snapshot, String> {
        let _update = self.update_lock.lock().unwrap();
        if expected_revision
            .is_some_and(|revision| revision != self.playback.read().unwrap().revision)
        {
            return Err(
                "Settings changed elsewhere. Your view has been refreshed; try the change again."
                    .into(),
            );
        }
        self.prepare_locked(prefs, persist)
    }

    pub fn update_preferences(
        &self,
        update: impl FnOnce(&mut Preferences),
    ) -> Result<Snapshot, String> {
        let _update = self.update_lock.lock().unwrap();
        let mut prefs = self.playback.read().unwrap().prefs.clone();
        update(&mut prefs);
        self.prepare_locked(prefs, true)
    }

    fn prepare_locked(&self, prefs: Preferences, persist: bool) -> Result<Snapshot, String> {
        prefs.validate_shape()?;
        let (mute_only, mut packs) = {
            let previous = self.playback.read().unwrap();
            if prefs.only_mute_changed(&previous.prefs) {
                (true, previous.packs.clone())
            } else {
                (false, HashMap::new())
            }
        };
        if !mute_only {
            let active: HashSet<_> = std::iter::once(prefs.active_preset_id.as_str())
                .chain(
                    prefs
                        .app_rules
                        .iter()
                        .filter_map(|r| r.preset_id.as_deref()),
                )
                .collect();
            let mut ids = HashSet::new();
            for preset in prefs
                .presets
                .iter()
                .filter(|p| active.contains(p.id.as_str()))
            {
                ids.insert(preset.pack_id.clone());
                ids.extend(preset.overrides.values().map(|v| v.pack_id.clone()));
            }
            let mut decoded_bytes = 0usize;
            for id in ids {
                let pack = self.load_pack(&id)?;
                decoded_bytes += pack.decoded_bytes;
                if decoded_bytes > audio::MAX_DECODED_BYTES {
                    return Err("These presets need more than 128 MB of decoded audio. Use fewer distinct packs in key assignments or app rules.".into());
                }
                packs.insert(id, pack);
            }
        }
        if persist {
            let temporary = self.data_directory.join("settings.json.tmp");
            let mut file = fs::File::create(&temporary).map_err(|e| e.to_string())?;
            serde_json::to_writer_pretty(&mut file, &prefs).map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            fs::rename(temporary, self.data_directory.join("settings.json"))
                .map_err(|e| e.to_string())?;
        }
        let revision = self.playback.read().unwrap().revision + 1;
        *self.playback.write().unwrap() = Arc::new(Playback {
            revision,
            prefs,
            packs,
        });
        if !mute_only {
            self.runtime.lock().unwrap().configuration_error = None;
        }
        self.cache
            .lock()
            .unwrap()
            .retain(|_, pack| Arc::strong_count(pack) > 1);
        self.cancel();
        self.publish();
        Ok(self.snapshot())
    }

    pub fn resume_temporarily(&self) -> Snapshot {
        let prefs = self.playback.read().unwrap().prefs.clone();
        {
            let mut runtime = self.runtime.lock().unwrap();
            if runtime.can_resume(&prefs) {
                runtime.resume_app = if runtime.pause_reason(&prefs) == Some("Paused for this app")
                {
                    Some(runtime.frontmost_app.clone())
                } else {
                    None
                };
                runtime.temporary_resume = true;
            }
        }
        self.publish();
        self.snapshot()
    }
}

#[derive(Default)]
struct KeyTracker(HashMap<u16, String>);
impl KeyTracker {
    fn event(&mut self, physical: u16, logical: &str, down: bool) -> Option<String> {
        if down {
            if self.0.contains_key(&physical) {
                return None;
            }
            self.0.insert(physical, logical.to_string());
            Some(logical.into())
        } else {
            self.0.remove(&physical)
        }
    }
    fn clear(&mut self) {
        self.0.clear();
    }
}

extern "C" fn receive(kind: i32, key: u16, value: *const c_char) {
    let value = if value.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(value) }
            .to_string_lossy()
            .into_owned()
    };
    if let Some(sender) = INPUT.get()
        && sender
            .try_send(Message::Native(kind, key, value, Instant::now()))
            .is_err()
    {
        OVERFLOW.store(true, Ordering::Relaxed);
    }
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn ok_start(callback: extern "C" fn(i32, u16, *const c_char));
    fn ok_request_permission();
}

pub fn start_input() {
    #[cfg(target_os = "macos")]
    unsafe {
        ok_start(receive)
    }
}
pub fn request_permission() {
    #[cfg(target_os = "macos")]
    unsafe {
        ok_request_permission()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn repeats_chords_layout_changes_and_recovery() {
        let mut input = KeyTracker::default();
        assert_eq!(input.event(0, "KeyA", true).as_deref(), Some("KeyA"));
        assert!(input.event(0, "KeyA", true).is_none());
        assert_eq!(
            input.event(55, "MetaLeft", true).as_deref(),
            Some("MetaLeft")
        );
        assert_eq!(input.event(0, "KeyQ", false).as_deref(), Some("KeyA"));
        input.clear();
        assert!(input.event(55, "MetaLeft", false).is_none());
        assert!(input.event(0, "KeyQ", true).is_some());
    }
}
