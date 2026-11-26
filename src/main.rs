// No console window when the app is opened from the Start menu / a shortcut (Windows).
#![cfg_attr(windows, windows_subsystem = "windows")]
// MSVC ignores cxx-qt's "-l..." link argument and warns about it; harmless.
#![allow(linker_messages)]

mod audio;
mod autostart;
mod cli;
mod config;
mod core;
mod decode;
mod editor;
mod fx;
mod hotkeys;
mod ipc;
mod library;
mod mixer;
mod notes;
mod pictures;
mod themes;
mod ui;
mod update;

use clap::Parser;
use cxx_qt_lib::{QQmlApplicationEngine, QUrl};
use std::sync::atomic::Ordering;

extern "C" {
    fn easyboard_set_window_icon_data(data: *const u8, len: std::os::raw::c_ulong);
    fn easyboard_set_quit_on_last_window_closed(on: bool);
    fn easyboard_set_app_names();
    fn easyboard_create_app();
    fn easyboard_exec() -> i32;
    fn easyboard_install_theme();
    fn easyboard_set_theme(follow: bool, dark: bool);
    fn easyboard_apply_titlebars();
}

/// A program built for the Windows GUI has no console of its own. When it is started from a terminal
/// (for example `easyboard --help`), hook its output up to that terminal again.
#[cfg(windows)]
fn attach_console() {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    extern "system" {
        fn AttachConsole(process_id: u32) -> i32;
        fn GetStdHandle(which: u32) -> *mut c_void;
        fn SetStdHandle(which: u32, handle: *mut c_void) -> i32;
    }
    const ATTACH_PARENT_PROCESS: u32 = 0xFFFF_FFFF;
    unsafe {
        if AttachConsole(ATTACH_PARENT_PROCESS) == 0 {
            return; // not started from a terminal
        }
        for which in [(-11i32) as u32, (-12i32) as u32] {
            // stdout, stderr: only when they are not already redirected somewhere
            let h = GetStdHandle(which);
            if h.is_null() || h as isize == -1 {
                if let Ok(f) = std::fs::OpenOptions::new().write(true).open("CONOUT$") {
                    SetStdHandle(which, f.as_raw_handle() as *mut c_void);
                    std::mem::forget(f);
                }
            }
        }
    }
}

fn main() {
    #[cfg(windows)]
    attach_console();
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();
    let cli = cli::Cli::parse();
    if let Some(opts) = &cli.list {
        let mut full = false;
        let mut sort = "sort=id".to_string();
        for o in opts {
            if o.eq_ignore_ascii_case("full") {
                full = true;
            } else if o.to_ascii_lowercase().starts_with("sort=") {
                sort = o.clone();
            } else {
                eprintln!("error: unknown --list option '{o}' (use full and/or sort=KEY)");
                std::process::exit(2);
            }
        }
        let opt = sort;
        match core::core().list_text(&opt, full) {
            Ok(t) => print!("{t}"),
            Err(e) => {
                eprintln!("error: {e}");
                std::process::exit(2);
            }
        }
        return;
    }
    let commands = match cli.commands() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(2);
        }
    };

    // ---- Another instance already running: forward everything to it. ----
    if ipc::instance_running() {
        let mut cmds = commands;
        if cmds.is_empty() && !cli.no_gui {
            cmds.push("show".into());
        }
        if cmds.is_empty() {
            eprintln!("EasyBoard is already running.");
            return;
        }
        let mut failed = false;
        for c in cmds {
            match ipc::send(&c) {
                Ok(r) => {
                    println!("{r}");
                    failed |= r.starts_with("error");
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    failed = true;
                }
            }
        }
        std::process::exit(i32::from(failed));
    }

    // ---- We are the instance. ----
    if !commands.is_empty() && !cli.no_gui {
        eprintln!(
            "EasyBoard is not running. Start it first (or add --no-gui to start it in the \
             tray and run these commands)."
        );
        std::process::exit(1);
    }

    let core = core::core();
    core.start_mute_watcher();
    if let Err(e) = ipc::serve(core.clone()) {
        eprintln!("could not start IPC server: {e}");
    }

    // Ctrl+C / SIGTERM / SIGHUP: clean up (remove the
    // virtual devices) and exit, instead of being killed mid-way.
    {
        let core = core.clone();
        let _ = ctrlc::set_handler(move || {
            // Quit on the window's own thread (its poll sees the request within 100 ms): exiting from
            // this signal thread while the window is drawing crashed Qt. Only if the window doesn't
            // react (no window yet, or it's stuck) is the process ended from here.
            core.quit_requested.store(true, Ordering::SeqCst);
            std::thread::sleep(std::time::Duration::from_secs(3));
            core.shutdown();
            std::process::exit(0);
        });
    }

    ui::backend::START_HIDDEN.store(cli.no_gui, Ordering::SeqCst);
    core.start_audio();
    notes::refresh();
    themes::install_builtins();
    // activate the theme's icons before the window loads
    let theme = core.cfg.lock().theme.clone();
    if let Err(e) = themes::load(&theme) {
        log::warn!("theme '{theme}': {e}");
    }
    for c in &commands {
        match ipc::handle(&core, c) {
            Ok(m) => println!("ok: {m}"),
            Err(e) => eprintln!("error: {e}"),
        }
    }

    // Follow the system theme with a style that honors the platform palette.
    if std::env::var_os("QT_QUICK_CONTROLS_STYLE").is_none() {
        std::env::set_var("QT_QUICK_CONTROLS_STYLE", "Fusion");
    }

    // Windows: let Qt draw dark title bars when the system is in dark mode.
    #[cfg(windows)]
    if std::env::var_os("QT_QPA_PLATFORM").is_none() {
        std::env::set_var("QT_QPA_PLATFORM", "windows:darkmode=2");
    }

    // The tray menu's widget fallback makes Qt's Wayland plugin print a harmless
    // "Failed to create grabbing popup" warning; hide just that category.
    if std::env::var_os("QT_LOGGING_RULES").is_none() {
        std::env::set_var("QT_LOGGING_RULES", "qt.qpa.wayland.warning=false");
    }

    unsafe {
        easyboard_create_app();
        easyboard_set_app_names();
        easyboard_set_quit_on_last_window_closed(false);
        easyboard_install_theme();
        let (follow, dark) = {
            let c = core.cfg.lock();
            (c.theme_follow, c.theme_dark)
        };
        easyboard_set_theme(follow, dark);
    }
    // Window icon (also used by the taskbar).
    // Loaded from the bytes compiled into the binary, so it never depends on a file path.
    let icon_bytes = ui::backend::app_icon_bytes();
    unsafe { easyboard_set_window_icon_data(icon_bytes.as_ptr(), icon_bytes.len() as std::os::raw::c_ulong) };

    // If the QML UI fails to load (missing Qt QML module, bad QML...), Qt only logs a
    // warning and the app would idle invisibly, blocking later launches. Detect it.
    {
        let core = core.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(8));
            if !ui::backend::UI_READY.load(Ordering::SeqCst) {
                eprintln!(
                    "error: the EasyBoard interface failed to load. Check the Qt/QML messages \
                     printed above (a missing Qt module such as Qt.labs.platform or \
                     QtQuick.Dialogs is the usual cause)."
                );
                core.shutdown();
                std::process::exit(1);
            }
        });
    }

    let mut engine = QQmlApplicationEngine::new();
    if let Some(engine) = engine.as_mut() {
        engine.load(&QUrl::from("qrc:/qt/qml/EasyBoard/qml/Main.qml"));
    }
    unsafe {
        easyboard_apply_titlebars();
        easyboard_exec();
    }
    core.shutdown();
}
