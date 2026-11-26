use directories::ProjectDirs;
use rand::{distributions::Alphanumeric, Rng};
use serde::{Deserialize, Serialize};
use std::{fs, io, path::{Path, PathBuf}};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Sound {
    pub id: String,
    pub name: String,
    /// Absolute path to the audio file. Audio is never copied.
    pub path: String,
    /// File name (not path) of the copied picture inside `images/`.
    #[serde(default)]
    pub image: Option<String>,
    #[serde(default = "one")]
    pub volume: f32,
    /// Loop this sound whenever it plays.
    #[serde(default, rename = "loop")]
    pub looping: bool,
    /// e.g. "Ctrl+Shift+F1"
    #[serde(default)]
    pub hotkey: Option<String>,
    /// Tile color as "#rrggbb"; None = theme default.
    #[serde(default)]
    pub color: Option<String>,
    /// When the sound was added (ms since the Unix epoch; 0 for sounds from older versions).
    #[serde(default)]
    pub added: u64,
}

fn one() -> f32 { 1.0 }

/// An application whose audio is mixed into "EasyBoard Mic" (App routing).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AppRoute {
    /// Stable identity used to find the app's audio (see `audio::apps`).
    pub key: String,
    /// Name shown in the list.
    pub name: String,
    /// Where the icon comes from: "theme:<icon name>" or "file:<exe / .app path>"; "" = none.
    #[serde(default)]
    pub icon: String,
    #[serde(default = "yes")]
    pub enabled: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub setup_done: bool,
    /// Name of the microphone chosen in the setup wizard.
    #[serde(default)]
    pub input_device: String,
    /// Mix the microphone into the "EasyBoard Sink" input.
    #[serde(default = "yes")]
    pub mix_mic: bool,
    /// Volume of what you hear (0..=1).
    #[serde(default = "one")]
    pub volume_local: f32,
    /// Volume of what others hear (0..=1).
    #[serde(default = "one")]
    pub volume_virtual: f32,
    /// Global hotkeys for stopping / looping everything ("" = none).
    #[serde(default)]
    pub hotkey_stop_all: String,
    #[serde(default)]
    pub hotkey_loop_all: String,
    /// Colors hidden on the board: lowercase "#rrggbb", or "default" for sounds without a color.
    #[serde(default)]
    pub hidden_colors: Vec<String>,
    /// Hotkeys that mute / unmute the personal volume, the sink (soundboard) and the microphone.
    #[serde(default)]
    pub hotkey_mute_personal: String,
    #[serde(default)]
    pub hotkey_mute_sink: String,
    #[serde(default)]
    pub hotkey_mute_mic: String,
    /// Level of the "EasyBoard Mic" input (Linux), 0..=1.5.
    #[serde(default = "one")]
    pub volume_mic: f32,
    /// Name of the virtual output device on Windows/macOS
    /// (e.g. "CABLE Input", "VB-Cable"). Unused on Linux.
    #[serde(default)]
    pub virtual_device: String,
    /// "manual" | "az"/"za" | "id_asc"/"id_desc" | "len_asc"/"len_desc" | "color"/"color_desc" | "added_asc"/"added_desc"
    #[serde(default = "manual")]
    pub sort_mode: String,
    #[serde(default)]
    pub launch_on_startup: bool,
    #[serde(default)]
    pub start_minimized: bool,
    #[serde(default = "yes")]
    pub close_to_tray: bool,
    #[serde(default = "yes")]
    pub check_updates: bool,
    /// Theme: follow the system, or force dark / light.
    #[serde(default = "yes")]
    pub theme_follow: bool,
    #[serde(default = "yes")]
    pub theme_dark: bool,
    /// Tray icon follows the system theme (otherwise the app theme).
    #[serde(default = "yes")]
    pub tray_follow: bool,
    #[serde(default = "yes")]
    pub tray_dark: bool,
    /// Slight tint of the window color with the accent color.
    #[serde(default)]
    pub tint: bool,
    /// Show sound IDs on the board tiles.
    #[serde(default = "yes")]
    pub show_ids: bool,
    /// Active theme: folder name in `themes/` ("" = EasyBoard's own look).
    #[serde(default)]
    pub theme: String,
    /// Background picture: file name inside `images/` (always "wallpaper.<ext>").
    #[serde(default)]
    pub wallpaper: Option<String>,
    #[serde(default)]
    pub wallpaper_on: bool,
    /// Where the picture shows: "board" (only in the Soundboard's box), "behind" (behind the UI
    /// elements) or "all" (also behind buttons and the sidebar).
    #[serde(default = "board")]
    pub wallpaper_mode: String,
    /// Older setting, replaced by `wallpaper_mode` (true = "all"); only read.
    #[serde(default, skip_serializing)]
    pub wallpaper_whole: bool,
    /// 0..=1
    #[serde(default)]
    pub wallpaper_blur: f32,
    /// 0..=1
    #[serde(default = "one")]
    pub wallpaper_opacity: f32,
    /// 0..=2, 1 = unchanged
    #[serde(default = "one")]
    pub wallpaper_brightness: f32,
    /// A small shadow under all text while a background picture is shown.
    #[serde(default)]
    pub wallpaper_text_shadow: bool,
    /// Left sidebar shows the page names next to the icons.
    #[serde(default)]
    pub sidebar_expanded: bool,
    /// Apps whose audio is routed into "EasyBoard Mic".
    #[serde(default)]
    pub app_routes: Vec<AppRoute>,
    #[serde(default)]
    pub sounds: Vec<Sound>,
}

fn yes() -> bool { true }
fn manual() -> String { "manual".into() }
fn board() -> String { "board".into() }

impl Default for Config {
    fn default() -> Self {
        Self {
            setup_done: false,
            input_device: String::new(),
            mix_mic: true,
            volume_local: 1.0,
            volume_virtual: 1.0,
            volume_mic: 1.0,
            hotkey_stop_all: String::new(),
            hotkey_loop_all: String::new(),
            hidden_colors: Vec::new(),
            hotkey_mute_personal: String::new(),
            hotkey_mute_sink: String::new(),
            hotkey_mute_mic: String::new(),
            virtual_device: String::new(),
            sort_mode: "manual".into(),
            launch_on_startup: false,
            start_minimized: false,
            close_to_tray: true,
            check_updates: true,
            theme_follow: true,
            theme_dark: true,
            tray_follow: true,
            tray_dark: true,
            tint: false,
            show_ids: true,
            theme: String::new(),
            wallpaper: None,
            wallpaper_on: false,
            wallpaper_mode: "board".into(),
            wallpaper_whole: false,
            wallpaper_blur: 0.0,
            wallpaper_opacity: 1.0,
            wallpaper_brightness: 1.0,
            wallpaper_text_shadow: false,
            sidebar_expanded: false,
            app_routes: Vec::new(),
            sounds: Vec::new(),
        }
    }
}

pub fn config_dir() -> PathBuf {
    // Windows: %LOCALAPPDATA%\EasyBoard
    #[cfg(windows)]
    {
        if let Some(b) = directories::BaseDirs::new() {
            return b.data_local_dir().join("EasyBoard");
        }
    }
    ProjectDirs::from("com", "MrRedstonia", "EasyBoard")
        .map(|d| d.config_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".easyboard"))
}

pub fn images_dir() -> PathBuf { config_dir().join("images") }
/// Where sounds downloaded from the Sound Library are stored.
pub fn library_dir() -> PathBuf { config_dir().join("sounds") }
fn config_file() -> PathBuf { config_dir().join("config.json") }

const OLD_BLUE: &str = "#0090ff";
pub const NEW_BLUE: &str = "#0b74d1";

impl Config {
    pub fn load() -> Self {
        let mut cfg: Self = fs::read_to_string(config_file())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        // the "blue" tile color became a little darker
        for s in cfg.sounds.iter_mut() {
            if s.color.as_deref().map(|c| c.eq_ignore_ascii_case(OLD_BLUE)).unwrap_or(false) {
                s.color = Some(NEW_BLUE.into());
            }
        }
        for c in cfg.hidden_colors.iter_mut().filter(|c| c.eq_ignore_ascii_case(OLD_BLUE)) {
            *c = NEW_BLUE.into();
        }
        if cfg.wallpaper_whole {
            cfg.wallpaper_mode = "all".into();
            cfg.wallpaper_whole = false;
        }
        if !matches!(cfg.wallpaper_mode.as_str(), "board" | "behind" | "all") {
            cfg.wallpaper_mode = "board".into();
        }
        cfg
    }

    pub fn save(&self) -> io::Result<()> {
        fs::create_dir_all(config_dir())?;
        let tmp = config_dir().join("config.json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(self).unwrap())?;
        fs::rename(tmp, config_file())
    }

    /// True when at least one routed app is switched on (Linux: the mic feed then has to run).
    #[cfg(target_os = "linux")]
    pub fn routes_active(&self) -> bool {
        self.app_routes.iter().any(|r| r.enabled)
    }

    pub fn find(&self, id: &str) -> Option<&Sound> {
        let id = normalize_id(id);
        self.sounds.iter().find(|s| s.id == id)
    }

    pub fn find_mut(&mut self, id: &str) -> Option<&mut Sound> {
        let id = normalize_id(id);
        self.sounds.iter_mut().find(|s| s.id == id)
    }

    /// Lowest unused numeric id, zero padded to two digits ("00", "01", ...).
    pub fn next_id(&self) -> String {
        (0u32..)
            .map(|n| format!("{n:02}"))
            .find(|id| !self.sounds.iter().any(|s| &s.id == id))
            .unwrap()
    }
}

/// "1" -> "01", " 07 " -> "07"; non numeric ids are returned trimmed.
pub fn normalize_id(id: &str) -> String {
    let t = id.trim();
    match t.parse::<u32>() {
        Ok(n) => format!("{n:02}"),
        Err(_) => t.to_string(),
    }
}

/// Copies a picture into the config folder under a random unique name and
/// returns the new file name.
pub fn import_image(src: &Path) -> io::Result<String> {
    fs::create_dir_all(images_dir())?;
    let ext = src
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_else(|| "png".into());
    loop {
        let stem: String = rand::thread_rng()
            .sample_iter(&Alphanumeric)
            .take(16)
            .map(char::from)
            .collect();
        let name = format!("{stem}.{ext}");
        let dest = images_dir().join(&name);
        if !dest.exists() {
            fs::copy(src, &dest)?;
            return Ok(name);
        }
    }
}

/// Copies a picture to `images/wallpaper.<ext>` and removes any earlier wallpaper file.
/// Returns the new file name.
pub fn import_wallpaper(src: &Path) -> io::Result<String> {
    fs::create_dir_all(images_dir())?;
    let ext = src
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_else(|| "png".into());
    let name = format!("wallpaper.{ext}");
    let dest = images_dir().join(&name);
    let same = fs::canonicalize(src).ok().zip(fs::canonicalize(&dest).ok()).map(|(a, b)| a == b).unwrap_or(false);
    if !same {
        // through a temporary file, so a failed copy never leaves half a picture behind
        let tmp = images_dir().join(format!(".wallpaper-new.{ext}"));
        fs::copy(src, &tmp)?;
        fs::rename(&tmp, &dest)?;
    }
    // the replaced wallpaper (it may have had another extension)
    if let Ok(rd) = fs::read_dir(images_dir()) {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if n.starts_with("wallpaper.") && n != name {
                let _ = fs::remove_file(e.path());
            }
        }
    }
    Ok(name)
}

pub fn delete_image(name: &str) {
    let _ = fs::remove_file(images_dir().join(name));
}
