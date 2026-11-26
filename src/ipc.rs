//! Tiny single-instance IPC so `easyboard --play 01` can talk to the running
//! app. Protocol: one text line request, one text line response.

use crate::core::Core;
use interprocess::local_socket::{
    prelude::*, GenericFilePath, GenericNamespaced, ListenerOptions, Name, Stream,
};
use std::{
    io::{self, BufRead, BufReader, Write},
    sync::{atomic::Ordering, Arc},
    thread,
};

fn socket_name() -> io::Result<Name<'static>> {
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .unwrap_or_default();
    let base = format!("easyboard-{user}.sock");
    if GenericNamespaced::is_supported() {
        base.to_ns_name::<GenericNamespaced>()
    } else {
        std::env::temp_dir()
            .join(base)
            .to_string_lossy()
            .into_owned()
            .to_fs_name::<GenericFilePath>()
    }
}

/// Sends a command to a running instance. `Err` means none is running.
pub fn send(cmd: &str) -> io::Result<String> {
    let stream = Stream::connect(socket_name()?)?;
    let mut reader = BufReader::new(stream);
    reader.get_mut().write_all(format!("{cmd}\n").as_bytes())?;
    let mut resp = String::new();
    reader.read_line(&mut resp)?;
    Ok(resp.trim().to_string())
}

pub fn instance_running() -> bool {
    send("ping").is_ok()
}

/// Starts the server thread. Returns an error if another instance owns the name.
pub fn serve(core: Arc<Core>) -> io::Result<()> {
    let name = socket_name()?;
    // A stale socket file can exist on platforms using file paths.
    #[cfg(unix)]
    if !GenericNamespaced::is_supported() && !instance_running() {
        let _ = std::fs::remove_file(
            std::env::temp_dir().join(format!(
                "easyboard-{}.sock",
                std::env::var("USER").unwrap_or_default()
            )),
        );
    }
    let listener = ListenerOptions::new().name(name).create_sync()?;

    thread::Builder::new().name("easyboard-ipc".into()).spawn(move || {
        for conn in listener.incoming().filter_map(Result::ok) {
            let core = core.clone();
            thread::spawn(move || {
                let mut reader = BufReader::new(conn);
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    return;
                }
                let reply = match handle(&core, line.trim()) {
                    Ok(m) => format!("ok: {m}"),
                    Err(e) => format!("error: {e}"),
                };
                let _ = reader.get_mut().write_all(format!("{reply}\n").as_bytes());
            });
        }
    })?;
    Ok(())
}

/// Executes a textual command: `play ID`, `loop ARG`, `stop`, `show`, `quit`, `ping`.
pub fn handle(core: &Arc<Core>, line: &str) -> Result<String, String> {
    let (cmd, arg) = line.split_once(' ').unwrap_or((line, ""));
    match cmd {
        "ping" => Ok("pong".into()),
        "play" => core.trigger(arg),
        "loop" => core.set_loop(arg),
        "volume" => core.volume_cmd(arg),
        "mute" => core.mute_cmd(arg),
        "stop" => Ok(core.stop_all()),
        "show" => {
            core.show_counter.fetch_add(1, Ordering::SeqCst);
            Ok("showing window".into())
        }
        "quit" => {
            core.quit_requested.store(true, Ordering::SeqCst);
            Ok("quitting".into())
        }
        other => Err(format!("unknown command '{other}'")),
    }
}
