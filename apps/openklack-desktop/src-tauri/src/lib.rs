mod audio;
mod diagnostics;
mod engine;
mod library;
mod licensing;
mod model;
mod pack_io;
mod shaping;
mod updates;

use engine::{Controller, Message, Snapshot};
use model::Preferences;
use std::sync::{Arc, atomic::Ordering};
use tauri::{
    Manager,
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu},
    tray::TrayIconBuilder,
};
use tauri_plugin_autostart::ManagerExt as AutostartExt;
use tauri_plugin_dialog::DialogExt;

fn settings_dialog(
    app: &tauri::AppHandle,
) -> Result<tauri_plugin_dialog::FileDialogBuilder<tauri::Wry>, String> {
    let window = app
        .get_webview_window("settings")
        .ok_or("Open settings before choosing a file.")?;
    Ok(app.dialog().file().set_parent(&window))
}

#[cfg(target_os = "macos")]
static TRAY_APP: std::sync::OnceLock<tauri::AppHandle> = std::sync::OnceLock::new();

fn report_tray_error(app: &tauri::AppHandle, error: String) {
    refresh_tray(app, app.state::<Arc<Controller>>().snapshot());
    let mut dialog = app
        .dialog()
        .message(format!("Your settings were not changed. {error}"))
        .title("Could not save OpenKlack settings")
        .kind(tauri_plugin_dialog::MessageDialogKind::Error);
    if let Some(window) = app.get_webview_window("settings") {
        dialog = dialog.parent(&window);
    }
    dialog.show(|_| {});
}

#[cfg(target_os = "macos")]
extern "C" fn tray_volume(preset: *const std::ffi::c_char, volume: f64) {
    if preset.is_null() || !volume.is_finite() {
        return;
    }
    let id = unsafe { std::ffi::CStr::from_ptr(preset) }
        .to_string_lossy()
        .into_owned();
    if let Some(app) = TRAY_APP.get().cloned() {
        let controller = app.state::<Arc<Controller>>().inner().clone();
        tauri::async_runtime::spawn_blocking(move || {
            if let Err(error) = controller.update_preferences(|prefs| {
                if let Some(preset) = prefs.presets.iter_mut().find(|p| p.id == id) {
                    preset.volume = volume as f32;
                }
            }) {
                report_tray_error(&app, error);
            }
        });
    }
}

fn add_tray_volume(app: &tauri::AppHandle, state: &Snapshot) {
    #[cfg(target_os = "macos")]
    if let Some(tray) = app.tray_by_id("openklack") {
        let preset = state.preferences.preset(&state.runtime.frontmost_app);
        let Ok(id) = std::ffi::CString::new(preset.id.clone()) else {
            return;
        };
        let volume = preset.volume;
        let _ = tray.with_inner_tray_icon(move |tray| {
            unsafe extern "C" {
                fn ok_tray_volume(
                    status: *mut std::ffi::c_void,
                    preset: *const std::ffi::c_char,
                    volume: f64,
                    changed: extern "C" fn(*const std::ffi::c_char, f64),
                );
            }
            if let Some(item) = tray.ns_status_item() {
                unsafe {
                    ok_tray_volume(
                        (&*item as *const _) as *mut std::ffi::c_void,
                        id.as_ptr(),
                        f64::from(volume),
                        tray_volume,
                    );
                }
            }
        });
    }
}

#[tauri::command]
fn startup_state(app: tauri::AppHandle, enabled: Option<bool>) -> Result<bool, String> {
    let manager = app.autolaunch();
    if let Some(enabled) = enabled {
        if enabled {
            manager.enable()
        } else {
            manager.disable()
        }
        .map_err(|e| e.to_string())?;
    }
    manager.is_enabled().map_err(|e| e.to_string())
}

#[tauri::command]
fn get_diagnostics(state: tauri::State<'_, Arc<Controller>>) -> Result<String, String> {
    serde_json::to_string_pretty(&state.metrics.report(&state)).map_err(|e| e.to_string())
}

#[tauri::command]
async fn export_diagnostics(app: tauri::AppHandle, report: String) -> Result<bool, String> {
    if report.len() > 65536
        || !serde_json::from_str::<serde_json::Value>(&report)
            .map_err(|e| e.to_string())?
            .is_object()
    {
        return Err("Refresh the diagnostics report before exporting it.".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let Some(file) = settings_dialog(&app)?
            .set_title("Save the diagnostics you reviewed")
            .set_file_name("OpenKlack-diagnostics.json")
            .add_filter("Diagnostics", &["json"])
            .blocking_save_file()
        else {
            return Ok(false);
        };
        library::write_atomic(
            &file.into_path().map_err(|e| e.to_string())?,
            report.as_bytes(),
        )?;
        Ok(true)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn choose_application(app: tauri::AppHandle) -> Result<Option<serde_json::Value>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(file) = settings_dialog(&app)?
            .set_title("Choose an app for this rule")
            .set_directory("/Applications")
            .add_filter("Mac applications", &["app"])
            .blocking_pick_file()
        else {
            return Ok(None);
        };
        let path = file.into_path().map_err(|e| e.to_string())?;
        let name = path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        #[cfg(target_os = "macos")]
        {
            unsafe extern "C" {
                fn ok_application_id(path: *const std::ffi::c_char) -> *mut std::ffi::c_char;
                fn ok_free_string(value: *mut std::ffi::c_char);
            }
            let path = std::ffi::CString::new(path.as_os_str().as_encoded_bytes())
                .map_err(|e| e.to_string())?;
            let value = unsafe { ok_application_id(path.as_ptr()) };
            if value.is_null() {
                return Err("Choose a Mac application with a bundle identifier.".into());
            }
            let identifier = unsafe { std::ffi::CStr::from_ptr(value) }
                .to_string_lossy()
                .into_owned();
            unsafe { ok_free_string(value) };
            Ok(Some(
                serde_json::json!({"bundleId":identifier, "name":name}),
            ))
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = path;
            Err("App selection is supported on macOS.".into())
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
fn get_state(state: tauri::State<'_, Arc<Controller>>) -> Snapshot {
    state.snapshot()
}

#[tauri::command]
fn set_keyboard_visible(state: tauri::State<'_, Arc<Controller>>, visible: bool) {
    state.visible.store(visible, Ordering::Relaxed);
}

#[tauri::command]
async fn retry_sounds(state: tauri::State<'_, Arc<Controller>>) -> Result<Snapshot, String> {
    let controller = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || controller.update_preferences(|_| {}))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
fn get_catalog(state: tauri::State<'_, Arc<Controller>>) -> Vec<serde_json::Value> {
    state
        .library
        .catalog()
        .iter()
        .map(|pack| {
            serde_json::json!({
                "id": pack.id, "name": pack.name, "brand": pack.brand, "kind": pack.kind,
                "description": pack.description, "color": pack.color, "author": pack.author,
                "supportsKeyUp": pack.supports_key_up, "sampleCount": pack.sample_count,
                "source": pack.source, "license": pack.license,
                "version": pack.version, "originalId": pack.original_id, "credits": pack.credits,
            })
        })
        .collect()
}

#[tauri::command]
async fn import_sounds(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<Controller>>,
) -> Result<Option<library::Imported>, String> {
    let controller = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let Some(file) = settings_dialog(&app)?
            .set_title("Import sounds or settings")
            .add_filter(
                "Sound packs, settings, and recordings",
                &["openklack", "zip", "wav", "mp3", "ogg", "flac"],
            )
            .blocking_pick_file()
        else {
            return Ok(None);
        };
        let path = file.into_path().map_err(|e| e.to_string())?;
        let imported = controller.library.import(&path)?;
        if let Some(preset) = &imported.preset {
            controller.update_preferences(|prefs| {
                prefs.presets.push(preset.clone());
                prefs.active_preset_id = preset.id.clone();
            })?;
        }
        Ok(Some(imported))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn export_preset(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<Controller>>,
    preset_id: String,
) -> Result<bool, String> {
    let controller = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let prefs = controller.snapshot().preferences;
        let preset = prefs
            .presets
            .iter()
            .find(|p| p.id == preset_id)
            .ok_or("This preset no longer exists.")?;
        let Some(file) = settings_dialog(&app)?
            .set_title("Export settings with sounds and credits")
            .set_file_name("My keyboard.openklack")
            .add_filter("OpenKlack settings", &["openklack"])
            .blocking_save_file()
        else {
            return Ok(false);
        };
        controller
            .library
            .export(preset, &file.into_path().map_err(|e| e.to_string())?)?;
        Ok(true)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn refresh_official_packs(state: tauri::State<'_, Arc<Controller>>) -> Result<usize, String> {
    let controller = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || controller.library.install_bundled_updates())
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn save_preferences(
    state: tauri::State<'_, Arc<Controller>>,
    preferences: Preferences,
    expected_revision: u64,
) -> Result<Snapshot, String> {
    let controller = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        controller.prepare(preferences, true, Some(expected_revision))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn preview_pack(
    state: tauri::State<'_, Arc<Controller>>,
    pack_id: String,
) -> Result<u64, String> {
    let controller = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let pack = controller.load_pack(&pack_id)?;
        let (completed, response) = std::sync::mpsc::channel();
        controller
            .sender
            .send(Message::Preview(pack, completed))
            .map_err(|e| e.to_string())?;
        response
            .recv_timeout(std::time::Duration::from_secs(5))
            .map_err(|_| "The preview engine did not respond. Try again.".to_string())?
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
fn stop_preview(state: tauri::State<'_, Arc<Controller>>) -> Result<(), String> {
    state
        .sender
        .send(Message::Refresh)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn preview_key(state: tauri::State<'_, Arc<Controller>>, key: String) -> Result<(), String> {
    if key.is_empty() || key.len() > 40 || key.chars().any(char::is_control) {
        return Err("Select a key on the keyboard to preview it.".into());
    }
    if !state.snapshot().runtime.audio_ready {
        return Err("Audio output unavailable. Check your Mac’s selected output.".into());
    }
    state
        .sender
        .try_send(Message::PreviewKey(key))
        .map_err(|_| "The audio engine is busy. Try the key again.".into())
}

#[tauri::command]
fn request_input_permission(app: tauri::AppHandle) -> Result<(), String> {
    app.run_on_main_thread(engine::request_permission)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn resume_temporarily(state: tauri::State<'_, Arc<Controller>>) -> Snapshot {
    state.resume_temporarily()
}

pub fn show_settings(app: &tauri::AppHandle) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window("settings") {
        window.show()?;
        window.unminimize()?;
        window.set_focus()?;
    } else {
        tauri::WebviewWindowBuilder::new(
            app,
            "settings",
            tauri::WebviewUrl::App("index.html".into()),
        )
        .title("OpenKlack")
        .inner_size(1080.0, 760.0)
        .min_inner_size(760.0, 600.0)
        .center()
        .build()?;
    }
    Ok(())
}

fn tray_menu(app: &tauri::AppHandle, state: &Snapshot) -> tauri::Result<Menu<tauri::Wry>> {
    let menu = Menu::new(app)?;
    if updates::ready(app) {
        menu.append(&MenuItem::with_id(
            app,
            "update-restart",
            "Update ready — Restart",
            true,
            None::<&str>,
        )?)?;
        menu.append(&PredefinedMenuItem::separator(app)?)?;
    }
    menu.append(&MenuItem::with_id(
        app,
        "status",
        state.pause_reason.as_deref().unwrap_or("Sound is on"),
        false,
        None::<&str>,
    )?)?;
    menu.append(&CheckMenuItem::with_id(
        app,
        "mute",
        "Mute",
        true,
        state.preferences.muted,
        None::<&str>,
    )?)?;
    if state.runtime.can_resume(&state.preferences) {
        menu.append(&MenuItem::with_id(
            app,
            "resume",
            "Resume temporarily",
            true,
            None::<&str>,
        )?)?;
    }
    let preset = state.preferences.preset(&state.runtime.frontmost_app);
    let volume = Submenu::new(app, format!("Volume · {:.0}%", preset.volume), true)?;
    for level in [0, 10, 25, 40, 55, 70, 85, 100] {
        volume.append(&CheckMenuItem::with_id(
            app,
            format!("volume:{level}"),
            format!("{level}%"),
            true,
            (preset.volume - level as f32).abs() < 0.5,
            None::<&str>,
        )?)?;
    }
    menu.append(&volume)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    let mut packs = app.state::<Arc<Controller>>().library.catalog();
    packs.sort_by_key(|pack| format!("{} {}", pack.brand, pack.name).to_lowercase());
    let sounds = Submenu::new(app, "More sounds", true)?;
    for pack in &packs {
        let item = CheckMenuItem::with_id(
            app,
            format!("sound:{}", pack.id),
            format!(
                "{} {}{}",
                pack.brand,
                if pack.name == "Unknown" {
                    "Classic"
                } else {
                    &pack.name
                },
                if pack.source.is_empty() {
                    " (Imported)"
                } else {
                    ""
                }
            )
            .trim(),
            true,
            pack.id == preset.pack_id,
            None::<&str>,
        )?;
        if state.preferences.favorite_pack_ids.contains(&pack.id) {
            menu.append(&item)?;
        } else {
            sounds.append(&item)?;
        }
    }
    if !sounds.items()?.is_empty() {
        menu.append(&sounds)?;
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(
        app,
        "settings",
        "Open OpenKlack…",
        true,
        Some("CmdOrCtrl+,"),
    )?)?;
    menu.append(&MenuItem::with_id(
        app,
        "quit",
        "Quit OpenKlack",
        true,
        Some("CmdOrCtrl+Q"),
    )?)?;
    Ok(menu)
}

pub fn refresh_tray(app: &tauri::AppHandle, state: Snapshot) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(tray) = handle.tray_by_id("openklack") {
            if let Ok(menu) = tray_menu(&handle, &state) {
                let _ = tray.set_menu(Some(menu));
                add_tray_volume(&handle, &state);
            }
            let _ = tray.set_tooltip(Some(format!(
                "OpenKlack · {}",
                state.pause_reason.as_deref().unwrap_or("Sound is on")
            )));
        }
    });
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .args(["--background"])
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            get_state,
            set_keyboard_visible,
            startup_state,
            get_diagnostics,
            export_diagnostics,
            retry_sounds,
            get_catalog,
            save_preferences,
            preview_pack,
            stop_preview,
            preview_key,
            request_input_permission,
            resume_temporarily,
            import_sounds,
            export_preset,
            refresh_official_packs,
            choose_application,
            #[cfg(feature = "updater")]
            updates::service::updater_status,
            #[cfg(feature = "updater")]
            updates::service::check_for_updates,
            #[cfg(feature = "updater")]
            updates::service::download_update,
            #[cfg(feature = "updater")]
            updates::service::set_update_settings,
            #[cfg(feature = "updater")]
            updates::service::restart_to_update,
            #[cfg(not(feature = "updater"))]
            updates::unavailable::updater_status,
            #[cfg(not(feature = "updater"))]
            updates::unavailable::check_for_updates,
            #[cfg(not(feature = "updater"))]
            updates::unavailable::download_update,
            #[cfg(not(feature = "updater"))]
            updates::unavailable::set_update_settings,
            #[cfg(not(feature = "updater"))]
            updates::unavailable::restart_to_update,
            #[cfg(feature = "licensing")]
            licensing::runtime::license_status,
            #[cfg(feature = "licensing")]
            licensing::runtime::activate_license,
            #[cfg(feature = "licensing")]
            licensing::runtime::remove_license,
            #[cfg(feature = "licensing")]
            licensing::runtime::check_license_now,
            #[cfg(feature = "licensing")]
            licensing::runtime::dismiss_license_key,
            #[cfg(feature = "licensing")]
            licensing::runtime::open_license_link,
            #[cfg(feature = "licensing")]
            licensing::runtime::reload_license
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            updates::init(app.handle());
            let resources = app.path().resource_dir()?;
            let controller =
                Controller::start(app.handle().clone(), resources, app.path().app_data_dir()?)
                    .map_err(std::io::Error::other)?;
            app.manage(controller.clone());
            #[cfg(target_os = "macos")]
            let _ = TRAY_APP.set(app.handle().clone());
            TrayIconBuilder::with_id("openklack")
                .icon(tauri::image::Image::from_bytes(include_bytes!(
                    "../../../../design/assets/openklack/menu-template@2x.png"
                ))?)
                .icon_as_template(true)
                .tooltip("OpenKlack")
                .menu(&tray_menu(app.handle(), &controller.snapshot())?)
                .on_menu_event(|app, event| {
                    let id = event.id.as_ref();
                    if id == "quit" {
                        app.exit(0);
                        return;
                    }
                    if id == "settings" {
                        let _ = show_settings(app);
                        return;
                    }
                    if id == "update-restart" {
                        updates::restart(app);
                        return;
                    }
                    let controller = app.state::<Arc<Controller>>().inner().clone();
                    if id == "resume" {
                        controller.resume_temporarily();
                        return;
                    }
                    let effective = controller.snapshot().effective_preset_id;
                    let id = id.to_string();
                    let app = app.clone();
                    tauri::async_runtime::spawn_blocking(move || {
                        if let Err(error) = controller.update_preferences(|preferences| {
                            if id == "mute" {
                                preferences.muted = !preferences.muted;
                            } else if let Some(value) = id
                                .strip_prefix("volume:")
                                .and_then(|v| v.parse::<f32>().ok())
                            {
                                if let Some(preset) =
                                    preferences.presets.iter_mut().find(|p| p.id == effective)
                                {
                                    preset.volume = value;
                                }
                            } else if let Some(pack_id) = id.strip_prefix("sound:")
                                && let Some(preset) =
                                    preferences.presets.iter_mut().find(|p| p.id == effective)
                            {
                                preset.pack_id = pack_id.into();
                            }
                        }) {
                            report_tray_error(&app, error);
                        }
                    });
                })
                .build(app)?;
            add_tray_volume(app.handle(), &controller.snapshot());
            // Licensing starts after the controller so a check can gate playback, and in the
            // background so it never delays launch.
            #[cfg(feature = "licensing")]
            licensing::runtime::Service::start(app.handle()).map_err(std::io::Error::other)?;
            // Debug builds accept `--no-input-listener` so update tests can run the app without
            // Input Monitoring or a global key listener. Release builds always listen.
            #[cfg(debug_assertions)]
            let listen = !std::env::args().any(|arg| arg == "--no-input-listener");
            #[cfg(not(debug_assertions))]
            let listen = true;
            if listen {
                engine::start_input();
            }
            if !std::env::args().any(|arg| arg == "--background") {
                show_settings(app.handle())?;
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::Destroyed) {
                window
                    .state::<Arc<Controller>>()
                    .visible
                    .store(false, Ordering::Relaxed);
            }
        })
        .build(tauri::generate_context!())
        .expect("OpenKlack could not start")
        .run(|app, event| match event {
            tauri::RunEvent::ExitRequested {
                code: None, api, ..
            } => api.prevent_exit(),
            #[cfg(target_os = "macos")]
            tauri::RunEvent::Reopen {
                has_visible_windows: false,
                ..
            } => {
                let _ = show_settings(app);
            }
            // openklack://activate?key=… from the website's thanks page.
            #[cfg(target_os = "macos")]
            tauri::RunEvent::Opened { urls } => {
                #[cfg(feature = "licensing")]
                licensing::runtime::opened(app, &urls);
                #[cfg(not(feature = "licensing"))]
                {
                    let _ = urls;
                    let _ = show_settings(app);
                }
            }
            // The trial's `last_seen_at` is saved on quit, then a staged update is installed.
            tauri::RunEvent::Exit => {
                #[cfg(feature = "licensing")]
                licensing::runtime::quit(app);
                updates::install_on_exit(app);
            }
            _ => {}
        });
}
