//! Application core: config + mixer + audio outputs. Shared (via `Arc`) by the
//! GUI, the global hotkeys and the CLI/IPC server.

use crate::{
    audio::{self, Outputs},
    config::{self, AppRoute, Config, Sound},
    decode::{decode_file, Decoded},
    fx,
    mixer::{Mixer, OUT_LOCAL, OUT_VIRTUAL},
};
use parking_lot::Mutex;
use serde_json::json;
use std::{
    collections::HashMap,
    path::Path,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, OnceLock,
    },
    time::{SystemTime, UNIX_EPOCH},
};

// Decoded sounds kept ready to play (f32 stereo: about 23 MB per minute of audio); the least recently
// played ones are dropped beyond this and decoded again when needed.
const CACHE_LIMIT_BYTES: usize = 64 * 1024 * 1024;

static CORE: OnceLock<Arc<Core>> = OnceLock::new();

/// The single process-wide core instance.
pub fn core() -> Arc<Core> {
    CORE.get_or_init(|| Arc::new(Core::new())).clone()
}

#[derive(Default)]
struct Cache {
    map: HashMap<String, CacheEntry>,
    tick: u64,
    bytes: usize,
}

struct CacheEntry {
    data: Arc<Decoded>,
    modified: Option<SystemTime>,
    used: u64,
}

const TILE_COLORS: [&str; 12] = [
    "", "#e5484d", "#f76b15", "#f5d90a", "#30a46c", "#12a594", "#0b74d1", "#8e4ec6", "#d63cc4",
    "#e93d82", "#5fd08a", "#4cb8ff",
];
const TILE_COLOR_NAMES: [&str; 12] = [
    "Default", "Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Magenta", "Pink", "Light green",
    "Light blue",
];
const SORT_MODES: [&str; 11] = [
    "manual", "az", "za", "id_asc", "id_desc", "len_asc", "len_desc", "color", "color_desc",
    "added_asc", "added_desc",
];

fn enabled_routes(cfg: &Config) -> Vec<String> {
    cfg.app_routes.iter().filter(|r| r.enabled).map(|r| r.key.clone()).collect()
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

pub struct Core {
    pub cfg: Mutex<Config>,
    durations: Mutex<HashMap<String, (Option<SystemTime>, f64)>>,
    pub mixer: Arc<Mixer>,
    outputs: Mutex<Option<Outputs>>,
    cache: Mutex<Cache>,
    /// Bumped whenever sounds / hotkeys / loop flags change.
    pub revision: AtomicU64,
    /// Bumped when another process asks us to show the window.
    pub show_counter: AtomicU64,
    pub quit_requested: AtomicBool,
    /// Bumped when the background picture is replaced.
    wallpaper_rev: AtomicU64,
    pub last_message: Mutex<String>,
    /// Runtime mute state: [personal, sink, mic].
    soft_muted: Mutex<[bool; 3]>,
    sys_muted: Mutex<[bool; 3]>,
    /// The sound editor's working audio and the running microphone recording.
    editor: Mutex<crate::editor::Session>,
    recorder: Mutex<Option<audio::Recorder>>,
    preview_secs: Mutex<f64>,
}

impl Core {
    fn new() -> Self {
        Self {
            cfg: Mutex::new(Config::load()),
            durations: Mutex::new(HashMap::new()),
            mixer: Mixer::new(),
            outputs: Mutex::new(None),
            cache: Mutex::new(Cache::default()),
            revision: AtomicU64::new(1),
            show_counter: AtomicU64::new(0),
            quit_requested: AtomicBool::new(false),
            wallpaper_rev: AtomicU64::new(0),
            last_message: Mutex::new(String::new()),
            soft_muted: Mutex::new([false; 3]),
            sys_muted: Mutex::new([false; 3]),
            editor: Mutex::new(crate::editor::Session::default()),
            recorder: Mutex::new(None),
            preview_secs: Mutex::new(0.0),
        }
    }

    // ------------------------------------------------------------ audio ----

    pub fn start_audio(&self) {
        let cfg = self.cfg.lock().clone();
        if !cfg.setup_done {
            return;
        }
        let mut outputs = self.outputs.lock();
        if let Some(mut old) = outputs.take() {
            old.stop();
        }
        if let Err(e) = audio::prepare_virtual(&cfg) {
            self.report(format!("Virtual input: {e}"));
        }
        audio::set_mic_volume(cfg.volume_mic);
        *outputs = Some(Outputs::start(self.mixer.clone(), &cfg));
        audio::apps::set_routes(enabled_routes(&cfg));
    }

    // ------------------------------------------------------ app routing ----

    /// Changes the routed apps, saves them and follows the change in the audio.
    fn update_routes(&self, f: impl FnOnce(&mut Vec<AppRoute>)) {
        let (restart, keys) = {
            let mut cfg = self.cfg.lock();
            let before = audio::mic_feed_needed(&cfg);
            f(&mut cfg.app_routes);
            let _ = cfg.save();
            (cfg.setup_done && before != audio::mic_feed_needed(&cfg), enabled_routes(&cfg))
        };
        if restart {
            // Linux: "EasyBoard Mic" appears / goes away with the first / last routed app
            self.start_audio();
            self.apply_gains(true);
        } else {
            audio::apps::set_routes(keys);
        }
    }

    pub fn add_app_route(&self, key: &str, name: &str, icon: &str) {
        if key.is_empty() {
            return;
        }
        self.update_routes(|r| {
            if let Some(e) = r.iter_mut().find(|e| e.key == key) {
                e.enabled = true;
            } else {
                r.push(AppRoute { key: key.into(), name: name.into(), icon: icon.into(), enabled: true });
            }
        });
    }

    pub fn remove_app_route(&self, key: &str) {
        self.update_routes(|r| r.retain(|e| e.key != key));
    }

    pub fn set_app_route_enabled(&self, key: &str, on: bool) {
        self.update_routes(|r| {
            if let Some(e) = r.iter_mut().find(|e| e.key == key) {
                e.enabled = on;
            }
        });
    }

    pub fn shutdown(&self) {
        self.mixer.stop_all();
        if let Some(mut o) = self.outputs.lock().take() {
            o.stop();
        }
        audio::shutdown_virtual();
    }

    fn load(&self, path: &str) -> Result<Arc<Decoded>, String> {
        let modified = std::fs::metadata(path).and_then(|m| m.modified()).ok();
        {
            let mut c = self.cache.lock();
            c.tick += 1;
            let tick = c.tick;
            if let Some(e) = c.map.get_mut(path) {
                if e.modified == modified {
                    e.used = tick;
                    return Ok(e.data.clone());
                }
            }
        }
        let data = Arc::new(decode_file(Path::new(path))?);
        let mut c = self.cache.lock();
        if let Some(old) = c.map.remove(path) {
            c.bytes -= old.data.bytes();
        }
        c.bytes += data.bytes();
        let used = c.tick;
        c.map.insert(path.to_string(), CacheEntry { data: data.clone(), modified, used });
        while c.bytes > CACHE_LIMIT_BYTES && c.map.len() > 1 {
            let oldest = c.map.iter().min_by_key(|(_, e)| e.used).map(|(k, _)| k.clone());
            match oldest {
                Some(k) if k != path => {
                    if let Some(e) = c.map.remove(&k) {
                        c.bytes -= e.data.bytes();
                    }
                }
                _ => break,
            }
        }
        Ok(data)
    }

    // --------------------------------------------------------- playback ----

    /// Plays a sound. If it is already playing, this stops it instead, so the same
    /// sound never runs twice at once (different sounds can overlap freely).
    pub fn trigger(&self, id: &str) -> Result<String, String> {
        let sound = self
            .cfg
            .lock()
            .find(id)
            .cloned()
            .ok_or_else(|| format!("no sound with id '{id}'"))?;

        if self.mixer.is_playing(&sound.id) {
            self.mixer.stop(&sound.id);
            return Ok(format!("stopped {} ({})", sound.id, sound.name));
        }
        let data = self.load(&sound.path).map_err(|e| {
            let msg = format!("{}: {e}", sound.name);
            self.report(msg.clone());
            msg
        })?;
        self.mixer.play(&sound.id, data, sound.volume, sound.looping);
        Ok(format!("playing {} ({})", sound.id, sound.name))
    }

    pub fn stop_all(&self) -> String {
        self.mixer.stop_all();
        "stopped all audio".into()
    }

    /// `loop on|off|toggle` controls loop-everything mode;
    /// `loop ID on|off|toggle` sets that one sound's own loop flag.
    pub fn set_loop(&self, arg: &str) -> Result<String, String> {
        let arg = arg.trim();
        let (first, rest) = match arg.split_once(char::is_whitespace) {
            Some((a, r)) => (a, r.trim()),
            None => (arg, ""),
        };
        let first_l = first.to_ascii_lowercase();
        if rest.is_empty() {
            return match first_l.as_str() {
                "on" => {
                    self.mixer.set_loop_all(true);
                    Ok("loop mode: on".into())
                }
                "off" => {
                    self.mixer.set_loop_all(false);
                    Ok("loop mode: off".into())
                }
                "toggle" => {
                    let v = !self.mixer.loop_all();
                    self.mixer.set_loop_all(v);
                    Ok(format!("loop mode: {}", if v { "on" } else { "off" }))
                }
                _ => Err(format!("a sound ID needs on, off or toggle (e.g. loop {first} toggle)")),
            };
        }
        let mode = rest.to_ascii_lowercase();
        if !["on", "off", "toggle"].contains(&mode.as_str()) {
            return Err(format!("expected on, off or toggle, got '{rest}'"));
        }
        let mut cfg = self.cfg.lock();
        let s = cfg
            .find_mut(first)
            .ok_or_else(|| format!("no sound with id '{first}'"))?;
        s.looping = match mode.as_str() {
            "on" => true,
            "off" => false,
            _ => !s.looping,
        };
        let (sid, v) = (s.id.clone(), s.looping);
        let _ = cfg.save();
        drop(cfg);
        self.mixer.set_loop(&sid, v);
        self.bump();
        Ok(format!("loop for {sid}: {}", if v { "on" } else { "off" }))
    }

    // ---------------------------------------------------- sound editing ----

    pub fn add_sound(
        &self,
        name: &str,
        path: &str,
        new_image: Option<&str>,
        volume: f32,
        looping: bool,
        hotkey: Option<String>,
        color: Option<String>,
    ) -> Result<String, String> {
        if !Path::new(path).is_file() {
            return Err(format!("audio file not found: {path}"));
        }
        let image = match new_image {
            Some(p) => Some(config::import_image(Path::new(p)).map_err(|e| e.to_string())?),
            None => None,
        };
        let mut cfg = self.cfg.lock();
        let id = cfg.next_id();
        cfg.sounds.push(Sound {
            id: id.clone(),
            name: name.trim().to_string(),
            path: path.to_string(),
            image,
            volume: volume.clamp(0.0, 2.0),
            looping,
            hotkey,
            color,
            added: now_ms(),
        });
        cfg.save().map_err(|e| e.to_string())?;
        drop(cfg);
        self.bump();
        Ok(id)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn update_sound(
        &self,
        id: &str,
        name: &str,
        path: &str,
        new_image: Option<&str>,
        remove_image: bool,
        volume: f32,
        looping: bool,
        hotkey: Option<String>,
        color: Option<String>,
    ) -> Result<(), String> {
        if !Path::new(path).is_file() {
            return Err(format!("audio file not found: {path}"));
        }
        let imported = match new_image {
            Some(p) => Some(config::import_image(Path::new(p)).map_err(|e| e.to_string())?),
            None => None,
        };
        let mut cfg = self.cfg.lock();
        let s = cfg.find_mut(id).ok_or_else(|| format!("no sound with id '{id}'"))?;
        if imported.is_some() || remove_image {
            if let Some(old) = s.image.take() {
                config::delete_image(&old);
            }
        }
        if imported.is_some() {
            s.image = imported;
        }
        s.name = name.trim().to_string();
        s.path = path.to_string();
        s.volume = volume.clamp(0.0, 2.0);
        s.looping = looping;
        s.hotkey = hotkey;
        s.color = color;
        let sid = s.id.clone();
        cfg.save().map_err(|e| e.to_string())?;
        drop(cfg);
        self.mixer.set_loop(&sid, looping);
        self.bump();
        Ok(())
    }

    /// Moves a sound to `to` (index in the manual order). Ids never change.
    pub fn move_sound(&self, id: &str, to: usize) -> Result<(), String> {
        let mut cfg = self.cfg.lock();
        let nid = config::normalize_id(id);
        let from = cfg
            .sounds
            .iter()
            .position(|s| s.id == nid)
            .ok_or_else(|| format!("no sound with id '{id}'"))?;
        let item = cfg.sounds.remove(from);
        let to = to.min(cfg.sounds.len());
        cfg.sounds.insert(to, item);
        cfg.save().map_err(|e| e.to_string())?;
        drop(cfg);
        self.bump();
        Ok(())
    }

    pub fn set_sort_mode(&self, mode: &str) {
        if !SORT_MODES.contains(&mode) {
            return;
        }
        {
            let mut cfg = self.cfg.lock();
            cfg.sort_mode = mode.to_string();
            let _ = cfg.save();
        }
        self.bump();
    }

    /// Makes `path` the background picture (copied into the images folder as "wallpaper.<ext>").
    pub fn set_wallpaper_file(&self, path: &str) -> Result<(), String> {
        let name = config::import_wallpaper(Path::new(path)).map_err(|e| format!("Could not use that picture: {e}"))?;
        {
            let mut cfg = self.cfg.lock();
            cfg.wallpaper = Some(name);
            cfg.wallpaper_on = true;
            let _ = cfg.save();
        }
        self.wallpaper_rev.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    /// Forgets the background picture and deletes its file.
    pub fn clear_wallpaper(&self) {
        let mut cfg = self.cfg.lock();
        if let Some(name) = cfg.wallpaper.take() {
            config::delete_image(&name);
        }
        let _ = cfg.save();
    }

    pub fn set_wallpaper_options(&self, on: bool, mode: &str, blur: f32, opacity: f32, brightness: f32, text_shadow: bool) {
        let mut cfg = self.cfg.lock();
        cfg.wallpaper_text_shadow = text_shadow;
        cfg.wallpaper_on = on;
        if matches!(mode, "board" | "behind" | "all") {
            cfg.wallpaper_mode = mode.to_string();
        }
        cfg.wallpaper_blur = blur.clamp(0.0, 1.0);
        cfg.wallpaper_opacity = opacity.clamp(0.0, 1.0);
        cfg.wallpaper_brightness = brightness.clamp(0.0, 2.0);
        let _ = cfg.save();
    }

    /// The background picture for the UI: {url ("" = none / off), mode, blur, opacity, brightness}.
    /// The URL changes when the picture is replaced, so QML loads the new one.
    pub fn wallpaper_json(&self) -> serde_json::Value {
        let cfg = self.cfg.lock();
        let url = match (&cfg.wallpaper, cfg.wallpaper_on) {
            (Some(name), true) => {
                let p = config::images_dir().join(name).to_string_lossy().replace('\\', "/");
                let p = if p.starts_with('/') { p } else { format!("/{p}") };
                format!("file://{p}?v={}", self.wallpaper_rev.load(Ordering::SeqCst))
            }
            _ => String::new(),
        };
        json!({
            "url": url,
            "mode": cfg.wallpaper_mode,
            "textShadow": cfg.wallpaper_text_shadow,
            "blur": cfg.wallpaper_blur,
            "opacity": cfg.wallpaper_opacity,
            "brightness": cfg.wallpaper_brightness,
        })
    }

    pub fn set_sidebar_expanded(&self, on: bool) {
        let mut cfg = self.cfg.lock();
        cfg.sidebar_expanded = on;
        let _ = cfg.save();
    }

    pub fn set_check_updates(&self, on: bool) {
        let mut cfg = self.cfg.lock();
        cfg.check_updates = on;
        let _ = cfg.save();
    }

    pub fn set_appearance(&self, follow: bool, dark: bool, tray_follow: bool, tray_dark: bool, tint: bool, show_ids: bool) {
        let mut cfg = self.cfg.lock();
        cfg.theme_follow = follow;
        cfg.theme_dark = dark;
        cfg.tray_follow = tray_follow;
        cfg.tray_dark = tray_dark;
        cfg.tint = tint;
        cfg.show_ids = show_ids;
        let _ = cfg.save();
    }

    /// `personal|sink|mic [+|-]PERCENT` : set, raise or lower a volume; without a number, report it.
    pub fn volume_cmd(&self, arg: &str) -> Result<String, String> {
        let mut it = arg.split_whitespace();
        let target = it.next().ok_or("usage: --volume personal|sink|mic [+|-]PERCENT")?.to_ascii_lowercase();
        let spec = it.next();
        let name = match target.as_str() {
            "personal" | "local" | "own" => "personal",
            "sink" | "virtual" | "cable" => "sink",
            "mic" | "microphone" => "mic",
            other => return Err(format!("unknown volume '{other}' (use personal, sink or mic)")),
        };
        let current = {
            let c = self.cfg.lock();
            match name {
                "personal" => c.volume_local,
                "sink" => c.volume_virtual,
                _ => c.volume_mic,
            }
        };
        let Some(spec) = spec else {
            return Ok(format!("{name} volume is {}%", (current * 100.0).round()));
        };
        let num = spec.trim_end_matches('%');
        let value: f32 = num.parse().map_err(|_| format!("'{spec}' is not a number"))?;
        let new = if num.starts_with('+') || num.starts_with('-') { current * 100.0 + value } else { value };
        let new = new.clamp(0.0, 150.0) / 100.0;
        {
            let mut c = self.cfg.lock();
            match name {
                "personal" => c.volume_local = new,
                "sink" => c.volume_virtual = new,
                _ => c.volume_mic = new,
            }
            let _ = c.save();
        }
        {}
        self.apply_gains(true);
        self.bump();
        Ok(format!("{name} volume set to {}%", (new * 100.0).round()))
    }

    pub fn set_behavior(&self, launch: bool, minimized: bool, close_to_tray: bool) {
        let launch_changed = {
            let mut cfg = self.cfg.lock();
            let changed = cfg.launch_on_startup != launch;
            cfg.launch_on_startup = launch;
            cfg.start_minimized = minimized;
            cfg.close_to_tray = close_to_tray;
            let _ = cfg.save();
            changed
        };
        if launch_changed {
            // in the background: the system can take a moment, and the toggle must not wait for it
            std::thread::spawn(move || {
                if let Err(e) = crate::autostart::set(launch) {
                    core().report(format!("Launch on startup: {e}"));
                }
            });
        }
    }

    /// Length of a sound in seconds (cached). Reads the header first, decodes as a fallback.
    fn duration_secs(&self, path: &str) -> Option<f64> {
        let modified = std::fs::metadata(path).and_then(|m| m.modified()).ok();
        if let Some((m, d)) = self.durations.lock().get(path) {
            if *m == modified {
                return Some(*d);
            }
        }
        let d = crate::decode::probe_duration(Path::new(path)).or_else(|| {
            self.load(path).ok().map(|d| d.frames() as f64 / d.rate.max(1) as f64)
        })?;
        self.durations.lock().insert(path.to_string(), (modified, d));
        Some(d)
    }

    fn sort_sounds(&self, v: &mut Vec<Sound>, mode: &str) {
        let id_key = |s: &Sound| (s.id.parse::<u32>().unwrap_or(u32::MAX), s.id.clone());
        match mode {
            "az" => v.sort_by_key(|s| s.name.to_lowercase()),
            "za" => {
                v.sort_by_key(|s| s.name.to_lowercase());
                v.reverse();
            }
            "id_asc" => v.sort_by_key(id_key),
            "id_desc" => {
                v.sort_by_key(id_key);
                v.reverse();
            }
            "len_asc" | "len_desc" => {
                let mut keyed: Vec<(f64, Sound)> = v
                    .drain(..)
                    .map(|s| (self.duration_secs(&s.path).unwrap_or(0.0), s))
                    .collect();
                keyed.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
                if mode == "len_desc" {
                    keyed.reverse();
                }
                *v = keyed.into_iter().map(|(_, s)| s).collect();
            }
            "color" | "color_desc" => {
                v.sort_by_key(|s| {
                    let c = s.color.as_deref().unwrap_or("");
                    TILE_COLORS.iter().position(|x| x.eq_ignore_ascii_case(c)).unwrap_or(usize::MAX)
                });
                if mode == "color_desc" {
                    v.reverse();
                }
            }
            "added_asc" | "added_desc" => {
                v.sort_by_key(|s| (s.added, id_key(s)));
                if mode == "added_desc" {
                    v.reverse();
                }
            }
            _ => {}
        }
    }

    pub fn remove_sound(&self, id: &str) -> Result<(), String> {
        let mut cfg = self.cfg.lock();
        let nid = config::normalize_id(id);
        let pos = cfg
            .sounds
            .iter()
            .position(|s| s.id == nid)
            .ok_or_else(|| format!("no sound with id '{id}'"))?;
        let s = cfg.sounds.remove(pos);
        if let Some(img) = &s.image {
            config::delete_image(img);
        }
        cfg.save().map_err(|e| e.to_string())?;
        drop(cfg);
        self.mixer.stop(&s.id);
        self.bump();
        Ok(())
    }

    // --------------------------------------------------------- settings ----

    pub fn finish_setup(&self, input: &str, mix_mic: bool, virtual_device: &str) {
        {
            let mut cfg = self.cfg.lock();
            cfg.input_device = input.to_string();
            cfg.mix_mic = mix_mic;
            cfg.virtual_device = virtual_device.to_string();
            cfg.setup_done = true;
            let _ = cfg.save();
        }
        self.start_audio();
        self.bump();
    }

    pub fn apply_settings(
        &self,
        input: &str,
        mix_mic: bool,
        virtual_device: &str,
        volume_local: f32,
        volume_virtual: f32,
    ) {
        let restart;
        {
            let mut cfg = self.cfg.lock();
            restart = cfg.input_device != input
                || cfg.mix_mic != mix_mic
                || cfg.virtual_device != virtual_device;
            cfg.input_device = input.to_string();
            cfg.mix_mic = mix_mic;
            cfg.virtual_device = virtual_device.to_string();
            cfg.volume_local = volume_local.clamp(0.0, 1.5);
            cfg.volume_virtual = volume_virtual.clamp(0.0, 1.5);
            let _ = cfg.save();
        }
        if restart {
            self.start_audio();
        }
        self.apply_gains(restart);
    }

    /// Pushes the configured volumes to the mixer / audio backend, honoring the mute state.
    fn apply_gains(&self, mic: bool) {
        let (l, v, m) = {
            let c = self.cfg.lock();
            (c.volume_local, c.volume_virtual, c.volume_mic)
        };
        let mu = *self.soft_muted.lock();
        self.mixer.set_output_gain(OUT_LOCAL, if mu[0] { 0.0 } else { l });
        self.mixer.set_output_gain(OUT_VIRTUAL, if mu[1] { 0.0 } else { v });
        self.sync_app_gain();
        if mic {
            audio::set_mic_volume(if mu[2] { 0.0 } else { m });
        }
    }

    /// Routed apps follow the EasyBoard Sink (soundboard) volume and mute, wherever it was muted.
    fn sync_app_gain(&self) {
        let v = self.cfg.lock().volume_virtual;
        audio::apps::set_gain(if self.muted_state()[1] { 0.0 } else { v });
    }

    /// Current mute state [personal, sink, mic]: the real system state where known, else our own.
    pub fn muted_state(&self) -> [bool; 3] {
        let (a, b) = (*self.sys_muted.lock(), *self.soft_muted.lock());
        [a[0] || b[0], a[1] || b[1], a[2] || b[2]]
    }

    /// Keeps `sys_muted` in sync with changes made outside EasyBoard (e.g. in Pavucontrol).
    pub fn start_mute_watcher(self: &Arc<Self>) {
        let core = self.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(std::time::Duration::from_millis(700));
            if let Some(m) = audio::get_mutes() {
                *core.sys_muted.lock() = m;
            }
            core.sync_app_gain();
        });
    }

    /// Downloaded library sounds as JSON [{name, path}], sorted by name.
    pub fn library_json(&self) -> String {
        let v: Vec<serde_json::Value> = crate::library::audio_files()
            .into_iter()
            .map(|p| {
                json!({ "name": crate::library::title_for(&p), "path": p.to_string_lossy() })
            })
            .collect();
        serde_json::to_string(&v).unwrap()
    }

    /// A file moved: sounds on the board that used `old` now point at `new`.
    pub fn repoint_audio(&self, old: &str, new: &str) {
        // Only the audio path changes: the sound keeps its id, name, color, volume and hotkey.
        let norm = |p: &str| {
            let p = p.replace('\\', "/");
            if cfg!(windows) { p.to_lowercase() } else { p }
        };
        let old = norm(old);
        let mut changed = false;
        {
            let mut cfg = self.cfg.lock();
            for snd in cfg.sounds.iter_mut() {
                if norm(&snd.path) == old {
                    snd.path = new.to_string();
                    changed = true;
                }
            }
            if changed {
                let _ = cfg.save();
            }
        }
        if changed {
            self.bump();
        }
    }

    pub fn set_hidden_colors(&self, csv: &str) {
        let mut cfg = self.cfg.lock();
        cfg.hidden_colors = csv.split(',').map(|s| s.trim().to_ascii_lowercase()).filter(|s| !s.is_empty()).collect();
        let _ = cfg.save();
    }

    /// Text for `--list` / `--list-full`.
    pub fn list_text(&self, opt: &str, full: bool) -> Result<String, String> {
        let spec = opt.trim().strip_prefix("sort=").unwrap_or(opt.trim()).to_ascii_lowercase();
        let (key, desc) = match spec.split_once(':') {
            Some((k, d)) => (k.to_string(), matches!(d, "desc" | "rev" | "reverse")),
            None => (spec.clone(), false),
        };
        let mode = match (key.as_str(), desc) {
            ("" | "id", false) => "id_asc",
            ("" | "id", true) => "id_desc",
            ("name" | "az", false) => "az",
            ("name" | "az", true) => "za",
            ("length", false) => "len_asc",
            ("length", true) => "len_desc",
            ("color" | "colour", false) => "color",
            ("color" | "colour", true) => "color_desc",
            ("added", false) => "added_asc",
            ("added", true) => "added_desc",
            ("manual", _) => "manual",
            (other, _) => return Err(format!("unknown sort '{other}' (use id, name, length, color, added or manual; add :desc to reverse)")),
        };
        let (mut sounds, hidden) = {
            let c = self.cfg.lock();
            (c.sounds.clone(), c.hidden_colors.clone())
        };
        self.sort_sounds(&mut sounds, mode);
        if mode == "manual" && desc {
            sounds.reverse();
        }
        if sounds.is_empty() {
            return Ok("No sounds yet.\n".into());
        }
        let color_name = |c: &Option<String>| -> String {
            match c.as_deref().filter(|c| !c.is_empty()) {
                None => "Default".into(),
                Some(c) => TILE_COLORS
                    .iter()
                    .position(|x| x.eq_ignore_ascii_case(c))
                    .map(|i| TILE_COLOR_NAMES[i].to_string())
                    .unwrap_or_else(|| c.to_string()),
            }
        };
        let is_hidden = |c: &Option<String>| {
            let key = c.as_deref().filter(|c| !c.is_empty()).map(|c| c.to_ascii_lowercase()).unwrap_or_else(|| "default".into());
            hidden.contains(&key)
        };
        let wid = sounds.iter().map(|s| s.id.chars().count()).max().unwrap_or(2);
        let wname = sounds.iter().map(|s| s.name.chars().count()).max().unwrap_or(4);
        let wpath = sounds.iter().map(|s| s.path.chars().count()).max().unwrap_or(4);
        let wcol = sounds.iter().map(|s| color_name(&s.color).chars().count()).max().unwrap_or(7);
        let mut out = String::new();
        for s in &sounds {
            if full {
                out.push_str(&format!(
                    "ID: {:<wid$}  Name: {:<wname$}  Audio File: {:<wpath$}  Image: {:<3}  Color: {:<wcol$}  Hidden: {}\n",
                    s.id,
                    s.name,
                    s.path,
                    if s.image.is_some() { "Yes" } else { "No" },
                    color_name(&s.color),
                    if is_hidden(&s.color) { "Yes" } else { "No" },
                ));
            } else {
                out.push_str(&format!("ID: {:<wid$}  Name: {}\n", s.id, s.name));
            }
        }
        Ok(out)
    }

    /// `personal|sink|mic [on|off|toggle]` (default toggle). `on` = muted.
    pub fn mute_cmd(&self, arg: &str) -> Result<String, String> {
        let mut it = arg.split_whitespace();
        let target = it.next().ok_or("usage: --mute personal|sink|mic [on|off|toggle]")?.to_ascii_lowercase();
        let idx = match target.as_str() {
            "personal" | "local" | "own" => 0,
            "sink" | "virtual" | "cable" | "soundboard" => 1,
            "mic" | "microphone" => 2,
            other => return Err(format!("unknown target '{other}' (use personal, sink or mic)")),
        };
        let mode = it.next().unwrap_or("toggle").to_ascii_lowercase();
        let current = self.muted_state()[idx];
        let on = match mode.as_str() {
            "on" | "mute" => true,
            "off" | "unmute" => false,
            "toggle" => !current,
            other => return Err(format!("expected on, off or toggle, got '{other}'")),
        };
        // Real (system level) mute where the platform supports it; otherwise the volume is set to zero.
        if audio::set_mute(idx, on) {
            self.sys_muted.lock()[idx] = on;
            self.soft_muted.lock()[idx] = false;
        } else {
            self.soft_muted.lock()[idx] = on;
        }
        self.apply_gains(true);
        let now = on;
        let name = ["Personal volume", "Soundboard", "Microphone"][idx];
        Ok(format!("{name} {}", if now { "muted" } else { "unmuted" }))
    }

    pub fn set_app_hotkeys(&self, stop_all: &str, loop_all: &str, mute_personal: &str, mute_sink: &str, mute_mic: &str) {
        {
            let mut cfg = self.cfg.lock();
            cfg.hotkey_stop_all = stop_all.trim().to_string();
            cfg.hotkey_loop_all = loop_all.trim().to_string();
            cfg.hotkey_mute_personal = mute_personal.trim().to_string();
            cfg.hotkey_mute_sink = mute_sink.trim().to_string();
            cfg.hotkey_mute_mic = mute_mic.trim().to_string();
            let _ = cfg.save();
        }
        self.bump();
    }

    pub fn set_mic_volume(&self, v: f32) {
        let v = v.clamp(0.0, 1.5);
        {
            let mut cfg = self.cfg.lock();
            cfg.volume_mic = v;
            let _ = cfg.save();
        }
        self.apply_gains(true);
    }

    // ---------------------------------------------------------- helpers ----

    pub fn sounds_json(&self) -> String {
        let (mut sounds, mode) = {
            let cfg = self.cfg.lock();
            (cfg.sounds.clone(), cfg.sort_mode.clone())
        };
        self.sort_sounds(&mut sounds, &mode);
        let list: Vec<_> = sounds
            .iter()
            .map(|s| {
                json!({
                    "id": s.id,
                    "name": s.name,
                    "path": s.path,
                    "image": s.image.as_ref()
                        .map(|i| config::images_dir().join(i).to_string_lossy().replace('\\', "/"))
                        .unwrap_or_default(),
                    "volume": s.volume,
                    "loop": s.looping,
                    "hotkey": s.hotkey.clone().unwrap_or_default(),
                    "color": s.color.clone().unwrap_or_default(),
                })
            })
            .collect();
        serde_json::to_string(&list).unwrap()
    }

    // ------------------------------------------------------ sound editor ----

    /// Opens a file in the editor; returns the editor state as JSON.
    pub fn editor_load(&self, path: &str) -> Result<String, String> {
        let data = self.load(path)?;
        let mut s = self.editor.lock();
        s.open(data, path);
        Ok(s.state(0.0, 1.0).to_string())
    }

    /// Empties the editor.
    pub fn editor_new(&self) -> String {
        self.mixer.stop("_preview");
        let mut s = self.editor.lock();
        s.clear();
        s.state(0.0, 1.0).to_string()
    }

    /// One structural edit (see `Session::edit`); returns the new editor state or {"error": ...}.
    pub fn editor_edit(&self, op: &str, a: f64, b: f64, arg: f64, start: f64, end: f64) -> String {
        self.mixer.stop("_preview");
        let mut s = self.editor.lock();
        match s.edit(op, a, b, arg, start, end) {
            Ok((ns, ne)) => s.state(ns, ne).to_string(),
            Err(e) => json!({ "error": e }).to_string(),
        }
    }

    /// Bakes the selection's effects into the audio; the track-wide ones stay pending.
    pub fn editor_apply_fx(&self, p: fx::Params, sel: Option<fx::SelFx>) -> String {
        self.mixer.stop("_preview");
        let Some(sel) = sel else {
            return json!({ "error": "Select a part of the audio first." }).to_string();
        };
        let mut s = self.editor.lock();
        match s.apply_fx((p.start, p.end), sel) {
            Ok((ns, ne)) => s.state(ns, ne).to_string(),
            Err(e) => json!({ "error": e }).to_string(),
        }
    }

    /// Plays the edited version through the mixer (id "_preview"), starting `offset` (0..1) into it.
    pub fn editor_preview(&self, p: fx::Params, sel: Option<fx::SelFx>, offset: f64, looping: bool, whole: bool) -> Result<(), String> {
        let data = self.editor.lock().data().ok_or("There is nothing to play.")?;
        self.mixer.stop("_preview");
        // With a selection only that part (inside the crop) is played, unless `whole`: then the whole crop.
        let out = fx::render(&data, &p, sel, !whole)?;
        *self.preview_secs.lock() = out.frames() as f64 / out.rate.max(1) as f64;
        // Only you hear the preview, never the "EasyBoard Sink" / "EasyBoard Mic" inputs.
        self.mixer.play_local_from("_preview", Arc::new(out), 1.0, looping, offset);
        Ok(())
    }

    /// Length in seconds of what the last preview plays (for a smooth playhead).
    pub fn editor_preview_secs(&self) -> f64 {
        *self.preview_secs.lock()
    }

    pub fn editor_record_start(&self) -> Result<(), String> {
        let mut r = self.recorder.lock();
        if r.is_some() {
            return Err("Already recording.".into());
        }
        self.mixer.stop("_preview");
        let dev = self.cfg.lock().input_device.clone();
        *r = Some(audio::start_recording(&dev));
        Ok(())
    }

    /// {"recording": bool, "seconds": f, "level": 0..1, "error": ""}
    pub fn editor_record_info(&self) -> String {
        match self.recorder.lock().as_ref() {
            Some(r) => json!({ "recording": true, "seconds": r.seconds(), "level": r.level(), "peaks": r.peaks(300), "error": r.error() }).to_string(),
            None => json!({ "recording": false, "seconds": 0.0, "level": 0.0, "error": "" }).to_string(),
        }
    }

    /// Stops the recording and inserts it at fraction `at` (or makes it the audio when the editor
    /// is empty). Returns the new editor state or {"error": ...}.
    pub fn editor_record_stop(&self, at: f64, start: f64, end: f64) -> String {
        let Some(rec) = self.recorder.lock().take() else {
            return json!({ "error": "Not recording." }).to_string();
        };
        match rec.finish() {
            Ok(audio) => {
                let mut s = self.editor.lock();
                let (ns, ne) = s.insert_audio(&audio, at, start, end);
                s.state(ns, ne).to_string()
            }
            Err(e) => json!({ "error": e }).to_string(),
        }
    }

    pub fn editor_stop_record_discard(&self) {
        if let Some(r) = self.recorder.lock().take() {
            let _ = r.finish();
        }
    }

    /// Sound library preview: plays a file on your own output only (id "_lib").
    pub fn play_library_preview(&self, path: &str) -> Result<(), String> {
        let data = self.load(path)?;
        self.mixer.stop("_lib");
        self.mixer.play_local("_lib", data, 1.0);
        Ok(())
    }

    pub fn stop_library_preview(&self) {
        self.mixer.stop("_lib");
    }

    pub fn editor_stop_preview(&self) {
        self.mixer.stop("_preview");
    }

    /// Saves the edited audio. `dest` empty: replace the original, in its own format when
    /// that can be written (WAV always; others need ffmpeg), otherwise as "<name>.wav" next to
    /// it, and board sounds using the old file are repointed. `dest` given: write a copy there
    /// (format from its extension) and leave everything else alone.
    pub fn editor_save(&self, p: fx::Params, sel: Option<fx::SelFx>, dest: &str, format: &str) -> Result<String, String> {
        let (data, path) = {
            let s = self.editor.lock();
            (s.data().ok_or("There is nothing to save.")?, s.path.clone())
        };
        let path = path.as_str();
        if path.is_empty() && dest.trim().is_empty() {
            return Err("This audio has no file yet. Use \"Save as Copy\".".into());
        }
        let src = Path::new(path);
        let out = fx::render(&data, &p, sel, false)?;
        let copy = !dest.trim().is_empty();

        let target = if copy {
            let mut t = std::path::PathBuf::from(dest.trim());
            if t.extension().is_none() {
                t.set_extension("wav");
            }
            t
        } else {
            let src_ext = src.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
            let writable = |e: &str| e == "wav" || (fx::FORMATS.contains(&e) && fx::ffmpeg_available());
            let want = format.trim().trim_start_matches('.').to_ascii_lowercase();
            if want.is_empty() || want == src_ext {
                if writable(&src_ext) {
                    src.to_path_buf()
                } else {
                    let t = src.with_extension("wav");
                    if t.exists() {
                        return Err(format!("{} already exists; use \"Save as Copy\" instead", t.display()));
                    }
                    t
                }
            } else {
                if !writable(&want) {
                    return Err(format!("Saving as .{want} needs ffmpeg, which was not found."));
                }
                let t = src.with_extension(&want);
                if t.exists() {
                    return Err(format!("{} already exists; use \"Save as Copy\" instead", t.display()));
                }
                t
            }
        };
        fx::write_audio(&target, &out)?;

        if !copy {
            let new_path = target.to_string_lossy().to_string();
            if new_path != path {
                // another format: every sound that used the file now uses the new one
                let norm = |p: &str| p.replace('\\', "/");
                {
                    let mut cfg = self.cfg.lock();
                    for s in cfg.sounds.iter_mut().filter(|s| norm(&s.path) == norm(path)) {
                        s.path = new_path.clone();
                    }
                    let _ = cfg.save();
                }
                let _ = std::fs::remove_file(path);
                crate::library::mark_edited(path);
                crate::library::file_converted(path, &new_path);
            } else {
                crate::library::mark_edited(path);
            }
            {
                let mut c = self.cache.lock();
                if let Some(old) = c.map.remove(path) {
                    c.bytes -= old.data.bytes();
                }
            }
            self.durations.lock().clear();
            self.bump();
        }
        Ok(target.display().to_string())
    }

    /// A file on disk changed (replaced / reverted): forget what was decoded from it.
    pub fn audio_changed(&self, path: &str) {
        {
            let mut c = self.cache.lock();
            if let Some(old) = c.map.remove(path) {
                c.bytes -= old.data.bytes();
            }
        }
        self.durations.lock().clear();
        self.bump();
    }

    pub fn bump(&self) {
        self.revision.fetch_add(1, Ordering::SeqCst);
    }

    pub fn report(&self, msg: String) {
        log::warn!("{msg}");
        *self.last_message.lock() = msg;
    }
}
