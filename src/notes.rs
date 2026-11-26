//! Release notes shown in Settings > About. They come from the project's GitHub Releases; the copy
//! fetched last is kept in the config folder. Until the first successful fetch (or when offline from
//! the start) the notes shipped with the app (RELEASE_NOTES.md) are shown.

use parking_lot::Mutex;
use std::time::Duration;

const REPO: &str = "MrRedstonia/EasyBoard";
static BUNDLED: &str = include_str!("../RELEASE_NOTES.md");
static FETCHING: Mutex<bool> = Mutex::new(false);

fn cache_path() -> std::path::PathBuf {
    crate::config::config_dir().join("release_notes.md")
}

/// Markdown of the newest release notes available here.
pub fn text() -> String {
    std::fs::read_to_string(cache_path())
        .ok()
        .filter(|t| !t.trim().is_empty())
        .unwrap_or_else(|| BUNDLED.to_string())
}

/// Fetches the notes in the background (at startup) and replaces the saved copy when that worked.
pub fn refresh() {
    {
        let mut f = FETCHING.lock();
        if *f {
            return;
        }
        *f = true;
    }
    std::thread::spawn(|| {
        match fetch() {
            Ok(md) => {
                let dir = crate::config::config_dir();
                let _ = std::fs::create_dir_all(&dir);
                let tmp = dir.join("release_notes.md.tmp");
                if std::fs::write(&tmp, md).is_ok() {
                    let _ = std::fs::rename(&tmp, cache_path());
                }
            }
            Err(e) => log::info!("release notes: {e}"),
        }
        *FETCHING.lock() = false;
    });
}

fn fetch() -> Result<String, String> {
    let url = format!("https://api.github.com/repos/{REPO}/releases?per_page=30");
    let body: serde_json::Value = ureq::get(&url)
        .set("User-Agent", &format!("EasyBoard/{}", env!("CARGO_PKG_VERSION")))
        .set("Accept", "application/vnd.github+json")
        .timeout(Duration::from_secs(10))
        .call()
        .map_err(|e| e.to_string())?
        .into_json()
        .map_err(|e| e.to_string())?;
    let mut md = String::new();
    for r in body.as_array().ok_or("unexpected answer")?.iter().filter(|r| r["draft"].as_bool() != Some(true)) {
        let tag = r["tag_name"].as_str().unwrap_or("");
        let name = r["name"].as_str().filter(|n| !n.trim().is_empty()).unwrap_or(tag);
        let date = r["published_at"].as_str().unwrap_or("").get(..10).unwrap_or("");
        let notes = r["body"].as_str().unwrap_or("").replace("\r\n", "\n");
        md.push_str(&format!("## {name}\n"));
        if !date.is_empty() {
            md.push_str(&format!("*{date}*\n"));
        }
        md.push('\n');
        md.push_str(if notes.trim().is_empty() { "No notes for this release." } else { notes.trim() });
        md.push_str("\n\n");
    }
    // nothing published (yet): keep what we have rather than showing an empty page
    if md.trim().is_empty() {
        return Err("no releases published".into());
    }
    Ok(md)
}
