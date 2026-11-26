//! "Launch on startup" for each platform. Best effort: failures are reported to the UI.

#[cfg(any(target_os = "linux", target_os = "macos"))]
use std::fs;
use std::path::PathBuf;

fn exe() -> Result<PathBuf, String> {
    std::env::current_exe().map_err(|e| e.to_string())
}

#[cfg(target_os = "linux")]
pub fn set(enabled: bool) -> Result<(), String> {
    let dir = directories::BaseDirs::new()
        .map(|d| d.config_dir().join("autostart"))
        .ok_or("no config directory")?;
    let file = dir.join("easyboard.desktop");
    if !enabled {
        let _ = fs::remove_file(file);
        return Ok(());
    }
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let text = format!(
        "[Desktop Entry]\nType=Application\nName=EasyBoard\nComment=Soundboard with a virtual microphone input\n\
         Exec=\"{}\"\nIcon=easyboard\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
        exe()?.display()
    );
    fs::write(file, text).map_err(|e| e.to_string())
}

#[cfg(target_os = "windows")]
pub fn set(enabled: bool) -> Result<(), String> {
    extern "C" {
        fn easyboard_run_at_login(enabled: bool, exe: *const std::os::raw::c_char) -> bool;
    }
    let exe = std::ffi::CString::new(exe()?.to_string_lossy().as_bytes()).map_err(|e| e.to_string())?;
    if unsafe { easyboard_run_at_login(enabled, exe.as_ptr()) } {
        Ok(())
    } else {
        Err("could not write to the registry".into())
    }
}

#[cfg(target_os = "macos")]
pub fn set(enabled: bool) -> Result<(), String> {
    let dir = directories::BaseDirs::new()
        .map(|d| d.home_dir().join("Library/LaunchAgents"))
        .ok_or("no home directory")?;
    let file = dir.join("com.mrredstonia.easyboard.plist");
    // "launchctl enable/disable" updates the system's own list of login items too (just deleting the
    // file can leave the entry showing up in System Settings). They never start or stop the app.
    let uid = std::process::Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|u| !u.is_empty());
    let launchctl = |verb: &str| {
        if let Some(uid) = &uid {
            let _ = std::process::Command::new("launchctl")
                .arg(verb)
                .arg(format!("gui/{uid}/com.mrredstonia.easyboard"))
                .output();
        }
    };
    if !enabled {
        launchctl("disable");
        let _ = fs::remove_file(file);
        return Ok(());
    }
    launchctl("enable");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let text = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n\
         <key>Label</key><string>com.mrredstonia.easyboard</string>\n\
         <key>ProgramArguments</key><array><string>{}</string></array>\n\
         <key>RunAtLoad</key><true/>\n</dict></plist>\n",
        exe()?.display()
    );
    fs::write(file, text).map_err(|e| e.to_string())
}
