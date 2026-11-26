//! The QML-facing backend. Deliberately thin: every invokable talks to
//! `crate::core::Core` and returns plain strings / JSON so the bridge surface
//! stays small.

use crate::{audio, core::core, hotkeys, hotkeys::Hotkeys};
use std::{cell::{Cell, RefCell}, fs, path::PathBuf, sync::atomic::Ordering};

thread_local! {
    // Must live on the GUI thread (Windows/macOS requirement).
    static HOTKEYS: RefCell<Option<Hotkeys>> = const { RefCell::new(None) };
    static HOTKEYS_TRIED: Cell<bool> = const { Cell::new(false) };
}

extern "C" {
    fn easyboard_cursor_pos(x: *mut i32, y: *mut i32);
    fn easyboard_set_theme(follow: bool, dark: bool);
    fn easyboard_system_dark() -> bool;
    fn easyboard_clipboard_file(buf: *mut std::os::raw::c_char, cap: i32) -> i32;
    fn easyboard_clipboard_clear();
    fn easyboard_frame_height() -> i32;
    fn easyboard_theme_palette(spec: *const std::os::raw::c_char);
    fn easyboard_dialog_palette(open: bool);
    fn easyboard_system_accent(buf: *mut std::os::raw::c_char, cap: i32) -> i32;
    fn easyboard_app_icon(spec: *const std::os::raw::c_char, out_path: *const std::os::raw::c_char) -> bool;
}

thread_local! {
    // icon spec -> file URL ("" when the app has no icon); GUI thread only
    static APP_ICONS: RefCell<std::collections::HashMap<String, String>> = RefCell::new(Default::default());
}

/// File URL of a PNG of the app icon described by `spec` (see `audio::apps::AudioApp::icon`), or "".
fn app_icon_url(spec: &str) -> String {
    if spec.is_empty() {
        return String::new();
    }
    if let Some(u) = APP_ICONS.with(|m| m.borrow().get(spec).cloned()) {
        return u;
    }
    // FNV-1a of the spec names the file
    let hash = spec.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ b as u64).wrapping_mul(0x0100_0000_01b3));
    let path = icon_dir().join(format!("app-{hash:016x}.png"));
    let url = match (std::ffi::CString::new(spec), std::ffi::CString::new(path.to_string_lossy().as_bytes())) {
        (Ok(c_spec), Ok(c_path)) if unsafe { easyboard_app_icon(c_spec.as_ptr(), c_path.as_ptr()) } => {
            format!("file://{}", to_url_path(&path.to_string_lossy()))
        }
        _ => String::new(),
    };
    APP_ICONS.with(|m| m.borrow_mut().insert(spec.to_string(), url.clone()));
    url
}

static DEVICES: std::sync::Mutex<Option<(String, String)>> = std::sync::Mutex::new(None);
static DEVICES_BUSY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn refresh_devices_now() -> (String, String) {
    let list: Vec<_> = audio::list_inputs()
        .into_iter()
        .map(|d| serde_json::json!({ "id": d.id, "label": d.label }))
        .collect();
    let d = (
        serde_json::to_string(&list).unwrap_or_else(|_| "[]".into()),
        serde_json::to_string(&audio::list_virtual_candidates()).unwrap_or_else(|_| "[]".into()),
    );
    *DEVICES.lock().unwrap() = Some(d.clone());
    d
}

fn refresh_devices_later() {
    if DEVICES_BUSY.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(|| {
        refresh_devices_now();
        DEVICES_BUSY.store(false, Ordering::SeqCst);
    });
}

static SPEAKER_SVG: &str = include_str!("../../assets/icons/speaker.svg");
static MUTED_SVG: &str = include_str!("../../assets/icons/muted.svg");
static LIBRARY_SVG: &str = include_str!("../../assets/icons/library.svg");
static HOME_SVG: &str = include_str!("../../assets/icons/home.svg");
static TRAY_SVG: &str = include_str!("../../assets/tray_icon.svg");
static STUDIO_SVG: &str = include_str!("../../assets/icons/studio.svg");
static UNDO_SVG: &str = include_str!("../../assets/icons/undo.svg");
static REDO_SVG: &str = include_str!("../../assets/icons/redo.svg");
static BACKSPACE_SVG: &str = include_str!("../../assets/icons/backspace.svg");
static BRACEOPEN_SVG: &str = include_str!("../../assets/icons/braceopen.svg");
static BRACECLOSE_SVG: &str = include_str!("../../assets/icons/braceclose.svg");
static REVERT_SVG: &str = include_str!("../../assets/icons/revert.svg");
static SHADOW_PNG: &[u8] = include_bytes!("../../assets/shadow.png");
static LOOP_SVG: &str = include_str!("../../assets/icons/loop.svg");
static STOP_SVG: &str = include_str!("../../assets/icons/stop.svg");
static THEMES_SVG: &str = include_str!("../../assets/icons/themes.svg");
static CHEVRON_SVG: &str = include_str!("../../assets/icons/chevron.svg");
static ROUTING_SVG: &str = include_str!("../../assets/icons/routing.svg");
static SETTINGS_SVG: &str = include_str!("../../assets/icons/settings.svg");
static APP_ICON: &[u8] = include_bytes!("../../assets/app_icon.png");
static TRAY_ICON: &[u8] = include_bytes!("../../assets/tray_icon.png");
static TRAY_ICON_LIGHT: &[u8] = include_bytes!("../../assets/tray_icon_light.png");

/// Starts hidden (tray only) when launched with `--no-gui`.
pub static START_HIDDEN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Set by Main.qml once it has loaded; lets `main` detect a UI that failed to load.
pub static UI_READY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    extern "RustQt" {
        #[qobject]
        #[qml_element]
        type Backend = super::BackendRust;

        /// JSON status polled by QML every ~100 ms. Also pumps global hotkeys.
        #[qinvokable]
        fn poll(self: &Backend) -> QString;
        #[qinvokable]
        fn sounds(self: &Backend) -> QString;
        #[qinvokable]
        fn settings(self: &Backend) -> QString;
        #[qinvokable]
        fn inputs(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "virtualCandidates"]
        fn virtual_candidates(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "setupDone"]
        fn setup_done(self: &Backend) -> bool;
        #[qinvokable]
        #[cxx_name = "startHidden"]
        fn start_hidden(self: &Backend) -> bool;
        #[qinvokable]
        #[cxx_name = "windowReady"]
        fn window_ready(self: &Backend);
        #[qinvokable]
        #[cxx_name = "needsVirtualDevice"]
        fn needs_virtual_device(self: &Backend) -> bool;

        #[qinvokable]
        #[cxx_name = "finishSetup"]
        fn finish_setup(self: &Backend, input: &QString, mix_mic: bool, virtual_device: &QString);
        #[qinvokable]
        #[cxx_name = "applySettings"]
        fn apply_settings(
            self: &Backend,
            input: &QString,
            mix_mic: bool,
            virtual_device: &QString,
            volume_local: f64,
            volume_virtual: f64,
        );

        #[qinvokable]
        fn trigger(self: &Backend, id: &QString);
        #[qinvokable]
        #[cxx_name = "stopAll"]
        fn stop_all(self: &Backend);
        #[qinvokable]
        #[cxx_name = "toggleLoopAll"]
        fn toggle_loop_all(self: &Backend);

        /// Returns an error message, or "" on success.
        #[qinvokable]
        #[cxx_name = "addSound"]
        fn add_sound(
            self: &Backend,
            name: &QString,
            path: &QString,
            image: &QString,
            volume: f64,
            looping: bool,
            hotkey: &QString,
            color: &QString,
        ) -> QString;
        #[qinvokable]
        #[cxx_name = "updateSound"]
        fn update_sound(
            self: &Backend,
            id: &QString,
            name: &QString,
            path: &QString,
            image: &QString,
            remove_image: bool,
            volume: f64,
            looping: bool,
            hotkey: &QString,
            color: &QString,
        ) -> QString;
        #[qinvokable]
        #[cxx_name = "moveSound"]
        fn move_sound(self: &Backend, id: &QString, to: i32);
        #[qinvokable]
        #[cxx_name = "setSortMode"]
        fn set_sort_mode(self: &Backend, mode: &QString);
        #[qinvokable]
        #[cxx_name = "setBehavior"]
        fn set_behavior(self: &Backend, launch: bool, minimized: bool, close_to_tray: bool);
        #[qinvokable]
        #[cxx_name = "iconUrl"]
        fn icon_url(self: &Backend, name: &QString, color: &QString) -> QString;
        #[qinvokable]
        #[cxx_name = "removeSound"]
        fn remove_sound(self: &Backend, id: &QString) -> QString;

        #[qinvokable]
        #[cxx_name = "setAppHotkeys"]
        fn set_app_hotkeys(
            self: &Backend,
            stop_all: &QString,
            loop_all: &QString,
            mute_personal: &QString,
            mute_sink: &QString,
            mute_mic: &QString,
        );
        #[qinvokable]
        #[cxx_name = "setMicVolume"]
        fn set_mic_volume(self: &Backend, v: f64);
        #[qinvokable]
        #[cxx_name = "editorLoad"]
        fn editor_load(self: &Backend, path: &QString) -> QString;
        #[qinvokable]
        #[cxx_name = "editorNew"]
        fn editor_new(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "editorEdit"]
        fn editor_edit(self: &Backend, op: &QString, a: f64, b: f64, arg: f64, start: f64, end: f64) -> QString;
        #[qinvokable]
        #[cxx_name = "editorApplyFx"]
        fn editor_apply_fx(self: &Backend, params: &QString) -> QString;
        #[qinvokable]
        #[cxx_name = "editorPreview"]
        fn editor_preview(self: &Backend, params: &QString, offset: f64, looping: bool, whole: bool) -> QString;


        #[qinvokable]
        #[cxx_name = "editorPreviewLen"]
        fn editor_preview_len(self: &Backend) -> f64;
        #[qinvokable]
        #[cxx_name = "isLibraryFile"]
        fn is_library_file(self: &Backend, path: &QString) -> bool;
        #[qinvokable]
        #[cxx_name = "clipboardFile"]
        fn clipboard_file(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "clearClipboard"]
        fn clear_clipboard(self: &Backend);
        #[qinvokable]
        #[cxx_name = "editorStopPreview"]
        fn editor_stop_preview(self: &Backend);
        #[qinvokable]
        #[cxx_name = "editorSave"]
        fn editor_save(self: &Backend, params: &QString, dest: &QString, format: &QString) -> QString;
        #[qinvokable]
        #[cxx_name = "editorRecordStart"]
        fn editor_record_start(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "editorRecordInfo"]
        fn editor_record_info(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "editorRecordStop"]
        fn editor_record_stop(self: &Backend, at: f64, start: f64, end: f64) -> QString;
        #[qinvokable]
        #[cxx_name = "editorRecordDiscard"]
        fn editor_record_discard(self: &Backend);
        #[qinvokable]
        #[cxx_name = "libStopPreview"]
        fn lib_stop_preview(self: &Backend);

        #[qinvokable]
        #[cxx_name = "urlToPath"]
        fn url_to_path(self: &Backend, url: &QString) -> QString;
        #[qinvokable]
        #[cxx_name = "trayIconUrl"]
        fn tray_icon_url(self: &Backend, light: bool) -> QString;
        #[qinvokable]
        #[cxx_name = "librarySounds"]
        fn library_sounds(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "libSearch"]
        fn lib_search(self: &Backend, query: &QString);
        #[qinvokable]
        #[cxx_name = "libTrending"]
        fn lib_trending(self: &Backend);
        #[qinvokable]
        #[cxx_name = "libPreview"]
        fn lib_preview(self: &Backend, id: &QString, mp3: &QString);
        #[qinvokable]
        #[cxx_name = "libPreviewFile"]
        fn lib_preview_file(self: &Backend, path: &QString);
        #[qinvokable]
        #[cxx_name = "libDownloaded"]
        fn lib_downloaded(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "libRename"]
        fn lib_rename(self: &Backend, path: &QString, name: &QString) -> QString;
        #[qinvokable]
        #[cxx_name = "imageFromUrl"]
        fn image_from_url(self: &Backend, url: &QString);
        #[qinvokable]
        #[cxx_name = "prepareImage"]
        fn prepare_image(self: &Backend, path: &QString);
        #[qinvokable]
        #[cxx_name = "imageFetchState"]
        fn image_fetch_state(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "libRevert"]
        fn lib_revert(self: &Backend, path: &QString);
        #[qinvokable]
        #[cxx_name = "libDelete"]
        fn lib_delete(self: &Backend, path: &QString) -> QString;
        #[qinvokable]
        #[cxx_name = "libMore"]
        fn lib_more(self: &Backend);
        #[qinvokable]
        #[cxx_name = "libState"]
        fn lib_state(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "libDownload"]
        fn lib_download(self: &Backend, id: &QString, title: &QString, mp3: &QString);
        #[qinvokable]
        #[cxx_name = "setHiddenColors"]
        fn set_hidden_colors(self: &Backend, csv: &QString);
        #[qinvokable]
        #[cxx_name = "toggleMute"]
        fn toggle_mute(self: &Backend, which: &QString);
        #[qinvokable]
        #[cxx_name = "setAppearance"]
        fn set_appearance(self: &Backend, follow: bool, dark: bool, tray_follow: bool, tray_dark: bool, tint: bool, show_ids: bool);
        #[qinvokable]
        #[cxx_name = "setCheckUpdates"]
        fn set_check_updates(self: &Backend, on: bool);
        #[qinvokable]
        #[cxx_name = "startUpdateCheck"]
        fn start_update_check(self: &Backend);
        #[qinvokable]
        #[cxx_name = "updateResult"]
        fn update_result(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "cursorPos"]
        fn cursor_pos(self: &Backend) -> QString;
        #[qinvokable]
        fn quit(self: &Backend);

        /// App routing: the routed apps as JSON [{key, name, icon (URL), enabled}].
        #[qinvokable]
        #[cxx_name = "appRoutes"]
        fn app_routes(self: &Backend) -> QString;
        /// Apps playing audio right now, as JSON [{key, name, iconSpec, icon (URL), added}].
        #[qinvokable]
        #[cxx_name = "playingApps"]
        fn playing_apps(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "addAppRoute"]
        fn add_app_route(self: &Backend, key: &QString, name: &QString, icon_spec: &QString);
        #[qinvokable]
        #[cxx_name = "removeAppRoute"]
        fn remove_app_route(self: &Backend, key: &QString);
        #[qinvokable]
        #[cxx_name = "setAppRouteEnabled"]
        fn set_app_route_enabled(self: &Backend, key: &QString, on: bool);
        /// Makes the picture at `path` the background. Returns an error message, or "".
        #[qinvokable]
        #[cxx_name = "setWallpaperFile"]
        fn set_wallpaper_file(self: &Backend, path: &QString) -> QString;
        #[qinvokable]
        #[cxx_name = "setWallpaperOptions"]
        fn set_wallpaper_options(self: &Backend, on: bool, mode: &QString, blur: f64, opacity: f64, brightness: f64, text_shadow: bool);
        #[qinvokable]
        #[cxx_name = "clearWallpaper"]
        fn clear_wallpaper(self: &Backend);
        /// Title bar + border height the window manager adds (0 = unknown).
        /// Release notes (Markdown): the copy from GitHub, or the one shipped with the app.
        /// Installed themes as JSON (see themes::list).
        #[qinvokable]
        fn themes(self: &Backend) -> QString;
        /// The active theme for the UI as JSON, or "" for EasyBoard's own look.
        #[qinvokable]
        #[cxx_name = "themeJson"]
        fn theme_json(self: &Backend) -> QString;
        /// Switches theme ("" = default). Returns an error message, or "".
        #[qinvokable]
        #[cxx_name = "setTheme"]
        fn set_theme(self: &Backend, id: &QString) -> QString;
        /// Installs a theme zip. Returns JSON {id, error}.
        #[qinvokable]
        #[cxx_name = "installTheme"]
        fn install_theme(self: &Backend, path: &QString) -> QString;
        #[qinvokable]
        #[cxx_name = "removeTheme"]
        fn remove_theme(self: &Backend, id: &QString) -> QString;
        #[qinvokable]
        #[cxx_name = "themesFolderUrl"]
        fn themes_folder_url(self: &Backend) -> QString;
        /// Puts the theme's colors into Qt's application palette ("role=#color;..."; "" = normal).
        #[qinvokable]
        #[cxx_name = "applyThemePalette"]
        fn apply_theme_palette(self: &Backend, spec: &QString);
        /// File dialogs: the system's palette while one is open (themes stay out of them).
        #[qinvokable]
        #[cxx_name = "dialogPalette"]
        fn dialog_palette(self: &Backend, open: bool);
        /// The system accent color (#rrggbb), also while a theme is active.
        #[qinvokable]
        #[cxx_name = "systemAccent"]
        fn system_accent(self: &Backend) -> QString;
        /// A soft shadow picture (for 9-slice drawing) as a file URL.
        #[qinvokable]
        #[cxx_name = "shadowUrl"]
        fn shadow_url(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "releaseNotes"]
        fn release_notes(self: &Backend) -> QString;
        #[qinvokable]
        #[cxx_name = "frameHeight"]
        fn frame_height(self: &Backend) -> i32;
        #[qinvokable]
        #[cxx_name = "setSidebarExpanded"]
        fn set_sidebar_expanded(self: &Backend, on: bool);
        #[qinvokable]
        #[cxx_name = "appRoutingSupported"]
        fn app_routing_supported(self: &Backend) -> bool;
    }
}

use cxx_qt_lib::QString;

/// Editor parameters from QML as JSON: crop + track-wide effects, and an optional "sel" object
/// ({a, b, ...effects}) with the effects of the selected part.
fn parse_params(j: &str) -> (crate::fx::Params, Option<crate::fx::SelFx>) {
    let v: serde_json::Value = serde_json::from_str(j).unwrap_or_default();
    let one = |o: &serde_json::Value, start: f64, end: f64| {
        let f = |k: &str, d: f64| o[k].as_f64().unwrap_or(d);
        crate::fx::Params {
            start,
            end,
            speed: f("speed", 1.0),
            gain_db: f("gainDb", 0.0),
            fade_in: f("fadeIn", 0.0),
            fade_out: f("fadeOut", 0.0),
            pitch: f("pitch", 0.0),
            reverse: o["reverse"].as_bool().unwrap_or(false),
            compress: o["compress"].as_bool().unwrap_or(false),
            balance: f("balance", 0.0),
        }
    };
    let start = v["start"].as_f64().unwrap_or(0.0);
    let end = v["end"].as_f64().unwrap_or(1.0);
    let p = one(&v, start, end);
    let sel = &v["sel"];
    let (a, b) = (sel["a"].as_f64().unwrap_or(-1.0), sel["b"].as_f64().unwrap_or(-1.0));
    (p, if a >= 0.0 && b > a { Some((a, b, one(sel, 0.0, 1.0))) } else { None })
}

#[derive(Default)]
pub struct BackendRust {}

fn s(q: &QString) -> String {
    q.to_string()
}

fn opt(q: &QString) -> Option<String> {
    let v = q.to_string();
    if v.trim().is_empty() { None } else { Some(v) }
}

/// Scratch folder for the recolored icons (not the config folder): per process, removed on quit.
fn icon_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("easyboard-icons-{}", std::process::id()));
    let _ = fs::create_dir_all(&dir);
    dir
}

fn cache_icon(name: &str, bytes: &[u8]) -> String {
    let dir = icon_dir();
    let path: PathBuf = dir.join(name);
    if fs::read(&path).map(|b| b != bytes).unwrap_or(true) {
        let _ = fs::write(&path, bytes);
    }
    format!("file://{}", to_url_path(&path.to_string_lossy()))
}

pub fn app_icon_bytes() -> &'static [u8] {
    APP_ICON
}

fn to_url_path(p: &str) -> String {
    let p = p.replace('\\', "/");
    if p.starts_with('/') { p } else { format!("/{p}") }
}

fn percent_decode(input: &str) -> String {
    let b = input.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = std::str::from_utf8(&b[i + 1..i + 3]).ok();
            if let Some(v) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

impl qobject::Backend {
    fn app_routes(&self) -> QString {
        let routes = core().cfg.lock().app_routes.clone();
        let list: Vec<_> = routes
            .iter()
            .map(|r| serde_json::json!({ "key": r.key, "name": r.name, "icon": app_icon_url(&r.icon), "enabled": r.enabled }))
            .collect();
        QString::from(&serde_json::Value::from(list).to_string())
    }

    fn playing_apps(&self) -> QString {
        let added: std::collections::HashSet<String> =
            core().cfg.lock().app_routes.iter().map(|r| r.key.clone()).collect();
        let list: Vec<_> = audio::apps::list_playing()
            .into_iter()
            .map(|a| serde_json::json!({
                "key": a.key, "name": a.name, "iconSpec": a.icon,
                "icon": app_icon_url(&a.icon), "added": added.contains(&a.key),
            }))
            .collect();
        QString::from(&serde_json::Value::from(list).to_string())
    }

    fn add_app_route(&self, key: &QString, name: &QString, icon_spec: &QString) {
        core().add_app_route(&s(key), &s(name), &s(icon_spec));
    }

    fn remove_app_route(&self, key: &QString) {
        core().remove_app_route(&s(key));
    }

    fn set_app_route_enabled(&self, key: &QString, on: bool) {
        core().set_app_route_enabled(&s(key), on);
    }

    fn set_wallpaper_file(&self, path: &QString) -> QString {
        match core().set_wallpaper_file(&s(path)) {
            Ok(()) => QString::from(""),
            Err(e) => QString::from(&e),
        }
    }

    fn set_wallpaper_options(&self, on: bool, mode: &QString, blur: f64, opacity: f64, brightness: f64, text_shadow: bool) {
        core().set_wallpaper_options(on, &s(mode), blur as f32, opacity as f32, brightness as f32, text_shadow);
    }

    fn clear_wallpaper(&self) {
        core().clear_wallpaper();
    }

    fn themes(&self) -> QString {
        QString::from(&serde_json::Value::from(crate::themes::list()).to_string())
    }

    fn theme_json(&self) -> QString {
        let id = core().cfg.lock().theme.clone();
        match crate::themes::load(&id) {
            Ok(serde_json::Value::Null) => QString::from(""),
            Ok(v) => QString::from(&v.to_string()),
            Err(e) => {
                log::warn!("theme '{id}': {e}");
                QString::from("")
            }
        }
    }

    fn set_theme(&self, id: &QString) -> QString {
        let id = s(id);
        if let Err(e) = crate::themes::load(&id) {
            let _ = crate::themes::load(&core().cfg.lock().theme.clone());
            return QString::from(&e);
        }
        let c = core();
        let mut cfg = c.cfg.lock();
        cfg.theme = id;
        let _ = cfg.save();
        QString::from("")
    }

    fn install_theme(&self, path: &QString) -> QString {
        let v = match crate::themes::install_zip(std::path::Path::new(&s(path))) {
            Ok(id) => serde_json::json!({ "id": id, "error": "" }),
            Err(e) => serde_json::json!({ "id": "", "error": e }),
        };
        QString::from(&v.to_string())
    }

    fn remove_theme(&self, id: &QString) -> QString {
        let id = s(id);
        match crate::themes::remove(&id) {
            Ok(()) => {
                let c = core();
                let mut cfg = c.cfg.lock();
                if cfg.theme == id {
                    cfg.theme.clear();
                    let _ = cfg.save();
                    let _ = crate::themes::load("");
                }
                QString::from("")
            }
            Err(e) => QString::from(&e),
        }
    }

    fn themes_folder_url(&self) -> QString {
        let dir = crate::themes::themes_dir();
        let _ = fs::create_dir_all(&dir);
        QString::from(&format!("file://{}", to_url_path(&dir.to_string_lossy())))
    }

    fn apply_theme_palette(&self, spec: &QString) {
        if let Ok(c) = std::ffi::CString::new(s(spec)) {
            unsafe { easyboard_theme_palette(c.as_ptr()) };
        }
    }

    fn dialog_palette(&self, open: bool) {
        unsafe { easyboard_dialog_palette(open) };
    }

    fn system_accent(&self) -> QString {
        let mut buf = [0 as std::os::raw::c_char; 16];
        let n = unsafe { easyboard_system_accent(buf.as_mut_ptr(), buf.len() as i32) };
        if n <= 0 {
            return QString::from("");
        }
        QString::from(&unsafe { std::ffi::CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned())
    }

    fn shadow_url(&self) -> QString {
        QString::from(&cache_icon("shadow-2.png", SHADOW_PNG))
    }

    fn release_notes(&self) -> QString {
        QString::from(&crate::notes::text())
    }

    fn frame_height(&self) -> i32 {
        unsafe { easyboard_frame_height() }
    }

    fn set_sidebar_expanded(&self, on: bool) {
        core().set_sidebar_expanded(on);
    }

    fn app_routing_supported(&self) -> bool {
        audio::apps::supported()
    }

    fn poll(&self) -> QString {
        let c = core();
        HOTKEYS.with(|h| {
            let mut h = h.borrow_mut();
            if h.is_none() && !HOTKEYS_TRIED.with(|t| t.replace(true)) && hotkeys::available() {
                *h = Hotkeys::new();
            }
            if let Some(h) = h.as_mut() {
                h.poll(&c);
            }
        });
        let msg = std::mem::take(&mut *c.last_message.lock());
        let v = serde_json::json!({
            "rev": c.revision.load(Ordering::SeqCst),
            "show": c.show_counter.load(Ordering::SeqCst),
            "quit": c.quit_requested.load(Ordering::SeqCst),
            "msg": msg,
            "playing": c.mixer.playing_ids(),
            "progress": c.mixer.playing_progress().into_iter().collect::<std::collections::HashMap<_, _>>(),
            "loopAll": c.mixer.loop_all(),
            "sort": c.cfg.lock().sort_mode.clone(),
            "closeToTray": c.cfg.lock().close_to_tray,
            "tint": c.cfg.lock().tint,
            "themeFollow": c.cfg.lock().theme_follow,
            "themeDark": c.cfg.lock().theme_dark,
            "muted": c.muted_state(),
            "trayFollow": c.cfg.lock().tray_follow,
            "trayDark": c.cfg.lock().tray_dark,
            "sysDark": unsafe { easyboard_system_dark() },
            "showIds": c.cfg.lock().show_ids,
            "wallpaper": c.wallpaper_json(),
        });
        QString::from(&v.to_string())
    }

    fn sounds(&self) -> QString {
        QString::from(&core().sounds_json())
    }

    fn settings(&self) -> QString {
        let c = core();
        let cfg = c.cfg.lock();
        let v = serde_json::json!({
            "input": cfg.input_device,
            "mixMic": cfg.mix_mic,
            "virtualDevice": cfg.virtual_device,
            "volumeLocal": cfg.volume_local,
            "volumeVirtual": cfg.volume_virtual,
            "volumeMic": cfg.volume_mic,
            "hotkeyStopAll": cfg.hotkey_stop_all,
            "hotkeyLoopAll": cfg.hotkey_loop_all,
            "hiddenColors": cfg.hidden_colors,
            "hotkeyMutePersonal": cfg.hotkey_mute_personal,
            "hotkeyMuteSink": cfg.hotkey_mute_sink,
            "hotkeyMuteMic": cfg.hotkey_mute_mic,
            "launchOnStartup": cfg.launch_on_startup,
            "startMinimized": cfg.start_minimized,
            "closeToTray": cfg.close_to_tray,
            "checkUpdates": cfg.check_updates,
            "version": env!("CARGO_PKG_VERSION"),
            "themeFollow": cfg.theme_follow,
            "themeDark": cfg.theme_dark,
            "trayFollow": cfg.tray_follow,
            "trayDark": cfg.tray_dark,
            "tint": cfg.tint,
            "showIds": cfg.show_ids,
            "sidebarExpanded": cfg.sidebar_expanded,
            "wallpaperOn": cfg.wallpaper_on,
            "wallpaperSet": cfg.wallpaper.is_some(),
            "wallpaperMode": cfg.wallpaper_mode,
            "wallpaperTextShadow": cfg.wallpaper_text_shadow,
            "wallpaperBlur": cfg.wallpaper_blur,
            "wallpaperOpacity": cfg.wallpaper_opacity,
            "wallpaperBrightness": cfg.wallpaper_brightness,
        });
        QString::from(&v.to_string())
    }

    // Listing audio devices can take a second on Windows, so the lists are cached: pages read the
    // cache at once and a background refresh keeps it current.
    fn inputs(&self) -> QString {
        let cached = DEVICES.lock().unwrap().clone();
        match cached {
            Some((i, _)) => {
                refresh_devices_later();
                QString::from(&i)
            }
            None => QString::from(&refresh_devices_now().0),
        }
    }

    fn virtual_candidates(&self) -> QString {
        let cached = DEVICES.lock().unwrap().clone();
        match cached {
            Some((_, v)) => QString::from(&v),
            None => QString::from(&refresh_devices_now().1),
        }
    }

    fn setup_done(&self) -> bool {
        core().cfg.lock().setup_done
    }

    fn window_ready(&self) {
        refresh_devices_later();
        UI_READY.store(true, Ordering::SeqCst);
    }

    fn start_hidden(&self) -> bool {
        let cfg = core().cfg.lock().clone();
        (START_HIDDEN.load(Ordering::SeqCst) || cfg.start_minimized) && cfg.setup_done
    }

    fn needs_virtual_device(&self) -> bool {
        !cfg!(target_os = "linux")
    }

    fn finish_setup(&self, input: &QString, mix_mic: bool, virtual_device: &QString) {
        core().finish_setup(&s(input), mix_mic, &s(virtual_device));
    }

    fn apply_settings(
        &self,
        input: &QString,
        mix_mic: bool,
        virtual_device: &QString,
        volume_local: f64,
        volume_virtual: f64,
    ) {
        core().apply_settings(
            &s(input),
            mix_mic,
            &s(virtual_device),
            volume_local as f32,
            volume_virtual as f32,
        );
    }

    fn trigger(&self, id: &QString) {
        let c = core();
        if let Err(e) = c.trigger(&s(id)) {
            c.report(e);
        }
    }

    fn stop_all(&self) {
        core().stop_all();
    }

    fn toggle_loop_all(&self) {
        let _ = core().set_loop("toggle");
    }

    fn add_sound(
        &self,
        name: &QString,
        path: &QString,
        image: &QString,
        volume: f64,
        looping: bool,
        hotkey: &QString,
        color: &QString,
    ) -> QString {
        let img = opt(image);
        match core().add_sound(
            &s(name),
            &s(path),
            img.as_deref(),
            volume as f32,
            looping,
            opt(hotkey),
            opt(color),
        ) {
            Ok(_) => QString::from(""),
            Err(e) => QString::from(&e),
        }
    }

    fn update_sound(
        &self,
        id: &QString,
        name: &QString,
        path: &QString,
        image: &QString,
        remove_image: bool,
        volume: f64,
        looping: bool,
        hotkey: &QString,
        color: &QString,
    ) -> QString {
        let img = opt(image);
        match core().update_sound(
            &s(id),
            &s(name),
            &s(path),
            img.as_deref(),
            remove_image,
            volume as f32,
            looping,
            opt(hotkey),
            opt(color),
        ) {
            Ok(()) => QString::from(""),
            Err(e) => QString::from(&e),
        }
    }

    fn move_sound(&self, id: &QString, to: i32) {
        let c = core();
        if let Err(e) = c.move_sound(&s(id), to.max(0) as usize) {
            c.report(e);
        }
    }

    fn set_sort_mode(&self, mode: &QString) {
        core().set_sort_mode(&s(mode));
    }

    fn set_behavior(&self, launch: bool, minimized: bool, close_to_tray: bool) {
        core().set_behavior(launch, minimized, close_to_tray);
    }

    /// Writes the embedded SVG (recolored: `currentColor` -> `color`) to the config
    /// folder and returns its file URL.
    fn icon_url(&self, name: &QString, color: &QString) -> QString {
        let n = s(name);
        // the active theme may replace any icon: SVGs are recolored like ours, other pictures used as they are
        let themed = crate::themes::icon_override(&n);
        let themed_svg = match &themed {
            Some((_, p)) if p.extension().map(|e| e.eq_ignore_ascii_case("svg")).unwrap_or(false) => fs::read_to_string(p).ok(),
            Some((_, p)) => return QString::from(&format!("file://{}", to_url_path(&p.to_string_lossy()))),
            None => None,
        };
        let src = if let Some(svg) = themed_svg.as_deref() { svg } else { match n.as_str() {
            "home" => HOME_SVG,
            "settings" => SETTINGS_SVG,
            "studio" => STUDIO_SVG,
            "backspace" => BACKSPACE_SVG,
            "braceopen" => BRACEOPEN_SVG,
            "braceclose" => BRACECLOSE_SVG,
            "revert" => REVERT_SVG,
            "undo" => UNDO_SVG,
            "redo" => REDO_SVG,
            "tray" => TRAY_SVG,
            "speaker" => SPEAKER_SVG,
            "muted" => MUTED_SVG,
            "library" => LIBRARY_SVG,
            "routing" => ROUTING_SVG,
            "chevron" => CHEVRON_SVG,
            "themes" => THEMES_SVG,
            "loop" => LOOP_SVG,
            "stop" => STOP_SVG,
            _ => return QString::from(""),
        } };
        let digits: String = s(color).chars().filter(|c| c.is_ascii_hexdigit()).collect();
        let hex = if digits.len() >= 6 {
            digits[digits.len() - 6..].to_string()
        } else {
            "ffffff".to_string()
        };
        let mut svg = src.replace("currentColor", &format!("#{hex}"));
        // Icons drawn with plain fills (no `currentColor`, no fill on the <svg> tag) would stay
        // black: give the root element the color so the shapes inherit it.
        if let Some(i) = svg.find("<svg") {
            let tag_end = svg[i..].find('>').map(|e| i + e).unwrap_or(i);
            if !svg[i..tag_end].contains(" fill=") {
                svg.insert_str(i + 4, &format!(" fill=\"#{hex}\""));
            }
        }
        // the theme is part of the name: switching themes must not show a cached icon
        let prefix = themed.map(|(t, _)| format!("{t}-")).unwrap_or_default();
        let path = icon_dir().join(format!("{prefix}{n}-{hex}.svg"));
        if fs::read_to_string(&path).map(|c| c != svg).unwrap_or(true) {
            let _ = fs::write(&path, svg);
        }
        QString::from(&format!("file://{}", to_url_path(&path.to_string_lossy())))
    }

    fn remove_sound(&self, id: &QString) -> QString {
        match core().remove_sound(&s(id)) {
            Ok(()) => QString::from(""),
            Err(e) => QString::from(&e),
        }
    }

    fn set_app_hotkeys(
        &self,
        stop_all: &QString,
        loop_all: &QString,
        mute_personal: &QString,
        mute_sink: &QString,
        mute_mic: &QString,
    ) {
        core().set_app_hotkeys(&s(stop_all), &s(loop_all), &s(mute_personal), &s(mute_sink), &s(mute_mic));
    }

    fn set_mic_volume(&self, v: f64) {
        core().set_mic_volume(v as f32);
    }

    fn editor_load(&self, path: &QString) -> QString {
        match core().editor_load(&s(path)) {
            Ok(j) => QString::from(&j),
            Err(e) => QString::from(&serde_json::json!({ "error": e }).to_string()),
        }
    }

    fn editor_new(&self) -> QString {
        QString::from(&core().editor_new())
    }

    fn editor_edit(&self, op: &QString, a: f64, b: f64, arg: f64, start: f64, end: f64) -> QString {
        QString::from(&core().editor_edit(&s(op), a, b, arg, start, end))
    }

    fn editor_apply_fx(&self, params: &QString) -> QString {
        let (p, sel) = parse_params(&s(params));
        QString::from(&core().editor_apply_fx(p, sel))
    }

    fn editor_preview(&self, params: &QString, offset: f64, looping: bool, whole: bool) -> QString {
        let (p, sel) = parse_params(&s(params));
        match core().editor_preview(p, sel, offset, looping, whole) {
            Ok(()) => QString::from(""),
            Err(e) => QString::from(&e),
        }
    }

    fn editor_preview_len(&self) -> f64 {
        core().editor_preview_secs()
    }

    fn is_library_file(&self, path: &QString) -> bool {
        crate::library::inside_library(std::path::Path::new(&s(path)))
    }

    fn clipboard_file(&self) -> QString {
        let mut buf = vec![0u8; 4096];
        let n = unsafe { easyboard_clipboard_file(buf.as_mut_ptr() as *mut std::os::raw::c_char, buf.len() as i32) };
        if n <= 0 {
            return QString::from("");
        }
        QString::from(&String::from_utf8_lossy(&buf[..n as usize]).to_string())
    }

    fn clear_clipboard(&self) {
        unsafe { easyboard_clipboard_clear() }
    }

    fn editor_stop_preview(&self) {
        core().editor_stop_preview();
    }

    fn editor_save(&self, params: &QString, dest: &QString, format: &QString) -> QString {
        let (p, sel) = parse_params(&s(params));
        match core().editor_save(p, sel, &s(dest), &s(format)) {
            Ok(path) => QString::from(&format!("ok:{path}")),
            Err(e) => QString::from(&e),
        }
    }

    fn editor_record_start(&self) -> QString {
        match core().editor_record_start() {
            Ok(()) => QString::from(""),
            Err(e) => QString::from(&e),
        }
    }

    fn editor_record_info(&self) -> QString {
        QString::from(&core().editor_record_info())
    }

    fn editor_record_stop(&self, at: f64, start: f64, end: f64) -> QString {
        QString::from(&core().editor_record_stop(at, start, end))
    }

    fn editor_record_discard(&self) {
        core().editor_stop_record_discard();
    }

    fn lib_stop_preview(&self) {
        crate::library::stop_preview();
    }

    fn url_to_path(&self, url: &QString) -> QString {
        let u = s(url);
        let rest = u.strip_prefix("file://").unwrap_or(&u);
        let mut p = percent_decode(rest);
        // file:///C:/x -> /C:/x -> C:/x
        if cfg!(windows) && p.starts_with('/') && p.chars().nth(2) == Some(':') {
            p.remove(0);
        }
        QString::from(&p)
    }

    fn tray_icon_url(&self, light: bool) -> QString {
        if light {
            QString::from(&cache_icon("tray_icon_light.png", TRAY_ICON_LIGHT))
        } else {
            QString::from(&cache_icon("tray_icon.png", TRAY_ICON))
        }
    }

    fn set_appearance(&self, follow: bool, dark: bool, tray_follow: bool, tray_dark: bool, tint: bool, show_ids: bool) {
        core().set_appearance(follow, dark, tray_follow, tray_dark, tint, show_ids);
        unsafe { easyboard_set_theme(follow, dark) };
    }

    fn library_sounds(&self) -> QString {
        QString::from(&core().library_json())
    }

    fn lib_search(&self, query: &QString) {
        crate::library::search(&s(query));
    }

    fn lib_trending(&self) {
        crate::library::trending();
    }

    fn lib_preview(&self, id: &QString, mp3: &QString) {
        crate::library::preview(&s(id), &s(mp3));
    }

    fn lib_preview_file(&self, path: &QString) {
        crate::library::preview_file(&s(path));
    }

    fn lib_downloaded(&self) -> QString {
        QString::from(&crate::library::downloaded_json())
    }

    fn lib_rename(&self, path: &QString, name: &QString) -> QString {
        QString::from(&crate::library::rename(&s(path), &s(name)))
    }

    fn image_from_url(&self, url: &QString) {
        crate::library::fetch_image(&s(url));
    }

    fn prepare_image(&self, path: &QString) {
        crate::library::prepare_image(&s(path));
    }

    fn image_fetch_state(&self) -> QString {
        QString::from(&crate::library::image_fetch_state())
    }

    fn lib_revert(&self, path: &QString) {
        crate::library::revert(&s(path));
    }

    fn lib_delete(&self, path: &QString) -> QString {
        QString::from(&crate::library::delete(&s(path)))
    }

    fn lib_more(&self) {
        crate::library::more();
    }

    fn lib_state(&self) -> QString {
        QString::from(&crate::library::state())
    }

    fn lib_download(&self, id: &QString, title: &QString, mp3: &QString) {
        crate::library::download(&s(id), &s(title), &s(mp3));
    }

    fn set_hidden_colors(&self, csv: &QString) {
        core().set_hidden_colors(&s(csv));
    }

    fn toggle_mute(&self, which: &QString) {
        let c = core();
        match c.mute_cmd(&s(which)) {
            Ok(m) => c.report(m),
            Err(e) => c.report(e),
        }
    }

    fn set_check_updates(&self, on: bool) {
        core().set_check_updates(on);
    }

    fn start_update_check(&self) {
        crate::update::start();
    }

    fn update_result(&self) -> QString {
        QString::from(&crate::update::result().unwrap_or_default())
    }

    fn cursor_pos(&self) -> QString {
        let (mut x, mut y) = (0i32, 0i32);
        unsafe { easyboard_cursor_pos(&mut x, &mut y) };
        QString::from(&format!("{x},{y}"))
    }

    fn quit(&self) {
        core().shutdown();
        let _ = fs::remove_dir_all(icon_dir());
        std::process::exit(0);
    }
}
