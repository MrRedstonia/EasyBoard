//! Pictures in formats Qt can't open by itself (WebP, AVIF, HEIC/HEIF when Qt's image-format plugins
//! are missing) are turned into PNG copies with the system's own decoder (Windows Imaging Component,
//! macOS ImageIO).

use std::ffi::CString;
use std::os::raw::c_char;
use std::path::{Path, PathBuf};

extern "C" {
    fn easyboard_image_readable(path: *const c_char) -> bool;
    fn easyboard_image_to_png(src: *const c_char, dst: *const c_char) -> bool;
}

fn c_path(p: &Path) -> Option<CString> {
    CString::new(p.to_string_lossy().as_bytes()).ok()
}

/// True when Qt can open the picture as it is.
pub fn readable(path: &Path) -> bool {
    c_path(path).map(|c| unsafe { easyboard_image_readable(c.as_ptr()) }).unwrap_or(false)
}

/// A picture EasyBoard can show: `src` itself when Qt reads it, otherwise a PNG copy of it (in the
/// temporary folder; it is copied into the images folder like any chosen picture).
pub fn displayable(src: &Path) -> Result<PathBuf, String> {
    if !src.is_file() {
        return Err("That picture could not be found.".into());
    }
    if readable(src) {
        return Ok(src.to_path_buf());
    }
    use std::hash::{Hash, Hasher};
    let meta = std::fs::metadata(src).ok();
    let mut h = std::collections::hash_map::DefaultHasher::new();
    src.hash(&mut h);
    meta.as_ref().map(|m| m.len()).hash(&mut h);
    meta.and_then(|m| m.modified().ok()).hash(&mut h);
    let dir = std::env::temp_dir().join("easyboard-pictures");
    std::fs::create_dir_all(&dir).map_err(|e| format!("Could not convert the picture: {e}"))?;
    let dst = dir.join(format!("{:016x}.png", h.finish()));
    if dst.is_file() && readable(&dst) {
        return Ok(dst);
    }
    let _ = std::fs::remove_file(&dst);

    if let (Some(s), Some(d)) = (c_path(src), c_path(&dst)) {
        if unsafe { easyboard_image_to_png(s.as_ptr(), d.as_ptr()) } && readable(&dst) {
            return Ok(dst);
        }
    }
    let _ = std::fs::remove_file(&dst);
    Err("EasyBoard can't open this kind of picture.".into())
}
