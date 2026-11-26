//! Global hotkeys. Must be created and polled on the GUI (main) thread, which
//! is what Windows and macOS require.
//!
//! Note: on Linux this goes through X11 (XWayland on Wayland sessions). Pure Wayland
//! sessions without XWayland can't grab keys; bind `easyboard -p 01` there instead.

use crate::core::Core;
use global_hotkey::{hotkey::HotKey, GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};
use std::{collections::HashMap, str::FromStr, sync::atomic::Ordering, sync::Arc};

/// False where global hotkeys cannot work (no X11 / XWayland display).
pub fn available() -> bool {
    #[cfg(target_os = "linux")]
    {
        // Works through X11 / XWayland, so a DISPLAY is enough (KDE Wayland has one).
        std::env::var_os("DISPLAY").is_some()
    }
    #[cfg(not(target_os = "linux"))]
    {
        true
    }
}

#[derive(Clone)]
enum Action {
    Sound(String),
    StopAll,
    LoopAll,
    Mute(&'static str),
}

pub struct Hotkeys {
    manager: GlobalHotKeyManager,
    registered: Vec<HotKey>,
    by_id: HashMap<u32, Vec<Action>>,
    seen_revision: u64,
}

impl Hotkeys {
    pub fn new() -> Option<Self> {
        match GlobalHotKeyManager::new() {
            Ok(manager) => Some(Self {
                manager,
                registered: Vec::new(),
                by_id: HashMap::new(),
                seen_revision: 0,
            }),
            Err(e) => {
                log::warn!("global hotkeys unavailable: {e}");
                None
            }
        }
    }

    /// Re-registers every hotkey from the config when it changed.
    fn sync(&mut self, core: &Core) {
        let rev = core.revision.load(Ordering::SeqCst);
        if rev == self.seen_revision {
            return;
        }
        self.seen_revision = rev;

        if !self.registered.is_empty() {
            let _ = self.manager.unregister_all(&self.registered);
            self.registered.clear();
            self.by_id.clear();
        }

        let mut entries: Vec<(Action, String)> = Vec::new();
        {
            let cfg = core.cfg.lock();
            for snd in &cfg.sounds {
                if let Some(h) = snd.hotkey.clone().filter(|h| !h.is_empty()) {
                    entries.push((Action::Sound(snd.id.clone()), h));
                }
            }
            if !cfg.hotkey_stop_all.is_empty() {
                entries.push((Action::StopAll, cfg.hotkey_stop_all.clone()));
            }
            if !cfg.hotkey_loop_all.is_empty() {
                entries.push((Action::LoopAll, cfg.hotkey_loop_all.clone()));
            }
            for (name, key) in [
                ("personal", &cfg.hotkey_mute_personal),
                ("sink", &cfg.hotkey_mute_sink),
                ("mic", &cfg.hotkey_mute_mic),
            ] {
                if !key.is_empty() {
                    entries.push((Action::Mute(name), key.clone()));
                }
            }
        }

        for (action, text) in entries {
            match HotKey::from_str(&text) {
                // The same key may be assigned to several sounds / actions: register it once, run all.
                Ok(hk) if self.by_id.contains_key(&hk.id()) => {
                    self.by_id.get_mut(&hk.id()).unwrap().push(action);
                }
                Ok(hk) => match self.manager.register(hk) {
                    Ok(()) => {
                        self.by_id.insert(hk.id(), vec![action]);
                        self.registered.push(hk);
                    }
                    Err(e) => core.report(format!("Hotkey '{text}' could not be registered: {e}")),
                },
                Err(e) => core.report(format!("Invalid hotkey '{text}': {e}")),
            }
        }
    }

    /// Call regularly from the main thread.
    pub fn poll(&mut self, core: &Arc<Core>) {
        self.sync(core);
        while let Ok(ev) = GlobalHotKeyEvent::receiver().try_recv() {
            if ev.state == HotKeyState::Pressed {
                for action in self.by_id.get(&ev.id).cloned().unwrap_or_default() {
                    match action {
                        Action::Sound(id) => {
                            if let Err(e) = core.trigger(&id) {
                                core.report(e);
                            }
                        }
                        Action::StopAll => {
                            core.stop_all();
                        }
                        Action::LoopAll => {
                            let _ = core.set_loop("toggle");
                        }
                        Action::Mute(t) => match core.mute_cmd(t) {
                            Ok(m) => core.report(m),
                            Err(e) => core.report(e),
                        },
                    }
                }
            }
        }
    }
}
