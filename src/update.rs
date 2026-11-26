//! Update check against the GitHub Releases of the project. It never installs anything by itself:
//! it only tells the user that a newer version exists and where to download it.

use parking_lot::Mutex;
use std::time::Duration;

const REPO: &str = "MrRedstonia/EasyBoard";

static RESULT: Mutex<Option<String>> = Mutex::new(None);

/// Starts a background check; `result()` returns `None` until it finishes.
pub fn start() {
    *RESULT.lock() = None;
    std::thread::spawn(|| {
        let r = check();
        *RESULT.lock() = Some(r.to_string());
    });
}

/// The last finished check as JSON: {state: "available"|"uptodate"|"error", current, latest, url, message}.
pub fn result() -> Option<String> {
    RESULT.lock().clone()
}

fn parse(v: &str) -> Vec<u64> {
    v.trim()
        .trim_start_matches(['v', 'V'])
        .split(['.', '-', '+'])
        .map_while(|p| p.parse::<u64>().ok())
        .collect()
}

fn newer(latest: &str, current: &str) -> bool {
    let (a, b) = (parse(latest), parse(current));
    for i in 0..a.len().max(b.len()) {
        let (x, y) = (a.get(i).copied().unwrap_or(0), b.get(i).copied().unwrap_or(0));
        if x != y {
            return x > y;
        }
    }
    false
}

fn check() -> serde_json::Value {
    let current = env!("CARGO_PKG_VERSION");
    let err = |m: String| serde_json::json!({ "state": "error", "current": current, "message": m });
    let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
    let resp = ureq::get(&url)
        .set("User-Agent", &format!("EasyBoard/{current}"))
        .set("Accept", "application/vnd.github+json")
        .timeout(Duration::from_secs(10))
        .call();
    let body: serde_json::Value = match resp {
        Ok(r) => match r.into_json() {
            Ok(v) => v,
            Err(e) => return err(format!("Unexpected answer from GitHub: {e}")),
        },
        Err(ureq::Error::Status(404, _)) => {
            return serde_json::json!({ "state": "uptodate", "current": current, "message": "No releases have been published yet." })
        }
        Err(ureq::Error::Status(c, _)) => return err(format!("GitHub answered with status {c}.")),
        Err(e) => return err(format!("Could not reach GitHub: {e}")),
    };
    let latest = body["tag_name"].as_str().unwrap_or("").trim_start_matches(['v', 'V']).to_string();
    let page = body["html_url"].as_str().unwrap_or(&format!("https://github.com/{REPO}/releases")).to_string();
    if latest.is_empty() {
        return err("The latest release has no version tag.".into());
    }
    if newer(&latest, current) {
        serde_json::json!({ "state": "available", "current": current, "latest": latest, "url": page })
    } else {
        serde_json::json!({ "state": "uptodate", "current": current, "latest": latest, "url": page })
    }
}
