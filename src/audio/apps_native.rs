//! App routing on Windows and macOS. The capture itself is native code (cpp/apptap_win.cpp:
//! WASAPI process loopback; cpp/apptap_mac.mm: Core Audio process taps) behind a small C API.

use super::{AudioApp, RateQueue, Target};
use std::{
    ffi::{c_char, c_void, CStr},
    sync::Arc,
};

type AppCb = extern "C" fn(ctx: *mut c_void, id: u64, pid: i32, active: i32, key: *const c_char, name: *const c_char, icon: *const c_char);
type AudioCb = extern "C" fn(ctx: *mut c_void, data: *const f32, frames: u32, rate: u32);

extern "C" {
    fn eb_apps_supported() -> i32;
    fn eb_apps_list(cb: AppCb, ctx: *mut c_void);
    fn eb_tap_start(id: u64, cb: AudioCb, ctx: *mut c_void, err: *mut c_char, errcap: i32) -> *mut c_void;
    fn eb_tap_alive(h: *mut c_void) -> i32;
    /// Stops the capture; no callback runs after it returns.
    fn eb_tap_stop(h: *mut c_void);
}

pub fn supported() -> bool {
    unsafe { eb_apps_supported() != 0 }
}

fn text(p: *const c_char) -> String {
    if p.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
    }
}

extern "C" fn collect(ctx: *mut c_void, id: u64, pid: i32, active: i32, key: *const c_char, name: *const c_char, icon: *const c_char) {
    let out = unsafe { &mut *(ctx as *mut Vec<Target>) };
    if pid as u32 == std::process::id() {
        return;
    }
    let (key, name, icon) = (text(key), text(name), text(icon));
    if key.is_empty() || name.to_lowercase().starts_with("easyboard") {
        return;
    }
    out.push(Target {
        id,
        app: AudioApp { key, name, icon: if icon.is_empty() { String::new() } else { format!("file:{icon}") } },
        active: active != 0,
    });
}

pub fn targets() -> Vec<Target> {
    if !supported() {
        return Vec::new();
    }
    let mut out: Vec<Target> = Vec::new();
    unsafe { eb_apps_list(collect, &mut out as *mut Vec<Target> as *mut c_void) };
    out
}

extern "C" fn on_audio(ctx: *mut c_void, data: *const f32, frames: u32, rate: u32) {
    if data.is_null() || frames == 0 {
        return;
    }
    let q = unsafe { &*(ctx as *const RateQueue) };
    let s = unsafe { std::slice::from_raw_parts(data, frames as usize * 2) };
    q.push(s, rate);
}

pub struct Capture {
    handle: *mut c_void,
    /// Kept alive for the native side, which holds a raw pointer to it.
    _queue: Arc<RateQueue>,
}

// The handle is only used through the thread-safe C API.
unsafe impl Send for Capture {}

impl Capture {
    pub fn start(id: u64, queue: Arc<RateQueue>) -> Result<Self, String> {
        let mut err = [0 as c_char; 256];
        let ctx = Arc::as_ptr(&queue) as *mut c_void;
        let handle = unsafe { eb_tap_start(id, on_audio, ctx, err.as_mut_ptr(), err.len() as i32) };
        if handle.is_null() {
            let e = text(err.as_ptr());
            return Err(if e.is_empty() { "capture failed".into() } else { e });
        }
        Ok(Capture { handle, _queue: queue })
    }

    pub fn alive(&self) -> bool {
        unsafe { eb_tap_alive(self.handle) != 0 }
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        unsafe { eb_tap_stop(self.handle) };
    }
}
