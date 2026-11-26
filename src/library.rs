//! Sound library: search sounds on MyInstants (its official API) and download them into the `sounds` folder.
//! Everything runs on background threads; the UI polls `state()`.

use crate::config;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Read;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

// MyInstants' own API (https://www.myinstants.com/api/v1/, 10 requests/minute without a token).
const SITE: &str = "https://www.myinstants.com";
const MAX_BYTES: u64 = 25 * 1024 * 1024;

#[derive(Clone, Default)]
struct Item {
    id: String,
    title: String,
    url: String,
    mp3: String,
    description: String,
}

#[derive(Default)]
struct View {
    state: &'static str, // "idle" | "loading" | "done" | "error"
    kind: &'static str,  // "search" | "trending"
    query: String,
    message: String,
    items: Vec<Item>,
    path: String, // request path without the page number
    page: u32,
    has_next: bool,
    loading_more: bool,
}

static VIEW: Mutex<Option<View>> = Mutex::new(None);
static DOWNLOADS: Mutex<Option<HashMap<String, String>>> = Mutex::new(None); // id -> "loading" | "error: ..."
static CACHE: Mutex<Option<HashMap<String, (Vec<Item>, u32, bool)>>> = Mutex::new(None); // items, page, has_next
static PROGRESS: Mutex<Option<HashMap<String, (u64, u64)>>> = Mutex::new(None); // id -> (bytes done, total)
static META_LOCK: Mutex<()> = Mutex::new(());
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// When the 10-per-minute limit is hit, until when requests are being held back (for the UI message).
static RATE_UNTIL: Mutex<Option<Instant>> = Mutex::new(None);

/// Be polite: at most one request every 400 ms and at most 10 per minute (the anonymous limit).
fn throttle() {
    static WINDOW: Mutex<Vec<Instant>> = Mutex::new(Vec::new());
    let mut w = WINDOW.lock();
    let now = Instant::now();
    w.retain(|t| now.duration_since(*t) < Duration::from_secs(60));
    let mut wait = Duration::ZERO;
    if let Some(t) = w.last() {
        wait = wait.max(Duration::from_millis(400).saturating_sub(now.duration_since(*t)));
    }
    if w.len() >= 10 {
        let limit = Duration::from_secs(60).saturating_sub(now.duration_since(w[0])) + Duration::from_millis(200);
        *RATE_UNTIL.lock() = Some(now + limit);
        wait = wait.max(limit);
    }
    if !wait.is_zero() {
        std::thread::sleep(wait);
    }
    w.push(Instant::now());
}

/// "Rate limit" note for the UI while requests are being held back.
fn rate_note() -> String {
    let until = *RATE_UNTIL.lock();
    match until.and_then(|u| u.checked_duration_since(Instant::now())) {
        Some(left) => format!("Rate limit reached (10 requests per minute). Continuing in {} s.", left.as_secs() + 1),
        None => String::new(),
    }
}

fn str_of(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

fn first(o: &Value, keys: &[&str]) -> String {
    keys.iter().map(|k| str_of(&o[*k])).find(|v| !v.is_empty()).unwrap_or_default()
}

/// Reads the official API's answer (`results: [{...}]`; field names are matched loosely).
fn parse_items(body: &Value) -> Vec<Item> {
    let arr = body["results"].as_array().cloned().unwrap_or_default();
    arr.iter()
        .map(|o| {
            let id = first(o, &["slug", "id"]);
            let url = first(o, &["url", "page", "link"]);
            Item {
                url: if url.is_empty() { format!("{SITE}/en/instant/{id}/") } else { url },
                title: first(o, &["title", "name"]),
                mp3: first(o, &["mp3", "sound", "file", "audio", "sound_url"]),
                description: first(o, &["description"]).trim().to_string(),
                id,
            }
        })
        .filter(|i| !i.id.is_empty() && !i.mp3.is_empty())
        .collect()
}

fn absolute(u: &str) -> String {
    if u.starts_with("http://") || u.starts_with("https://") {
        u.to_string()
    } else if u.starts_with("//") {
        format!("https:{u}")
    } else {
        format!("{SITE}/{}", u.trim_start_matches('/'))
    }
}

fn user_agent() -> String {
    format!("EasyBoard/{}", env!("CARGO_PKG_VERSION"))
}

fn fetch(path_and_query: &str) -> Result<(Vec<Item>, bool), String> {
    throttle();
    let url = format!("{SITE}{path_and_query}");
    // Without this header the official API answers with its HTML "browsable API" page.
    let r = ureq::get(&url)
        .set("User-Agent", &user_agent())
        .set("Accept", "application/json")
        .timeout(Duration::from_secs(15))
        .call();
    match r {
        Ok(resp) => {
            let text = resp.into_string().map_err(|e| format!("Could not read the sound service's answer: {e}"))?;
            let v: Value = serde_json::from_str(&text).map_err(|_| {
                if text.trim_start().starts_with('<') {
                    "The sound service returned a web page instead of data (it may be blocking apps).".to_string()
                } else {
                    "The sound service sent an answer EasyBoard could not read.".to_string()
                }
            })?;
            let has_next = v["has_next"].as_bool().unwrap_or_else(|| v["next"].as_str().map(|n| !n.is_empty()).unwrap_or(false));
            Ok((parse_items(&v), has_next))
        }
        Err(ureq::Error::Status(429, _)) => {
            *RATE_UNTIL.lock() = Some(Instant::now() + Duration::from_secs(30));
            Err("Rate limit reached: the sound service is getting too many requests. Wait a moment and try again.".into())
        }
        Err(ureq::Error::Status(c, _)) => Err(format!("The sound service answered with status {c}.")),
        Err(e) => Err(format!("Could not reach the sound service: {e}")),
    }
}

fn encode(q: &str) -> String {
    let mut out = String::new();
    for b in q.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn run(kind: &'static str, query: String, path: String) {
    let gen = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    let key = format!("{kind}:{query}");
    if let Some((items, page, has_next)) = CACHE.lock().as_ref().and_then(|c| c.get(&key)).cloned() {
        *VIEW.lock() = Some(View { state: "done", kind, query, items, path, page, has_next, ..Default::default() });
        return;
    }
    *VIEW.lock() = Some(View { state: "loading", kind, query: query.clone(), path: path.clone(), ..Default::default() });
    std::thread::spawn(move || {
        let r = fetch(&path);
        if GENERATION.load(Ordering::SeqCst) != gen {
            return; // a newer search replaced this one
        }
        let view = match r {
            Ok((items, has_next)) => {
                CACHE.lock().get_or_insert_with(HashMap::new).insert(key, (items.clone(), 1, has_next));
                View { state: "done", kind, query, items, path, page: 1, has_next, ..Default::default() }
            }
            Err(m) => View { state: "error", kind, query, message: m, path, ..Default::default() },
        };
        let has_next = view.has_next;
        let ok = view.state == "done";
        *VIEW.lock() = Some(view);
        if ok && has_next {
            more(); // a search shows two pages right away
        }
    });
}

/// Loads the next page of the current list and appends it.
pub fn more() {
    let (gen, kind, query, path, page) = {
        let mut g = VIEW.lock();
        let Some(v) = g.as_mut() else { return };
        if v.state != "done" || !v.has_next || v.loading_more {
            return;
        }
        v.loading_more = true;
        (GENERATION.load(Ordering::SeqCst), v.kind, v.query.clone(), v.path.clone(), v.page)
    };
    std::thread::spawn(move || {
        let next = page + 1;
        let r = fetch(&format!("{path}&page={next}"));
        if GENERATION.load(Ordering::SeqCst) != gen {
            return;
        }
        let mut g = VIEW.lock();
        let Some(v) = g.as_mut() else { return };
        v.loading_more = false;
        match r {
            Ok((items, has_next)) => {
                for it in items {
                    if !v.items.iter().any(|x| x.id == it.id) {
                        v.items.push(it);
                    }
                }
                v.page = next;
                v.has_next = has_next;
                CACHE.lock().get_or_insert_with(HashMap::new).insert(format!("{kind}:{query}"), (v.items.clone(), next, has_next));
            }
            Err(m) => v.message = m, // shown under the list; the items already loaded stay
        }
    });
}

pub fn search(query: &str) {
    let q = query.trim();
    if q.is_empty() {
        trending();
    } else {
        run("search", q.to_string(), format!("/api/v1/instants/?name={}", encode(q)));
    }
}

pub fn trending() {
    run("browse", String::new(), "/api/v1/instants/?name=".to_string());
}

fn clean_title(t: &str) -> String {
    let s: String = t
        .chars()
        .map(|c| if c.is_alphanumeric() || " -_().,'!&".contains(c) { c } else { ' ' })
        .collect();
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let s: String = s.chars().take(60).collect();
    if s.is_empty() { "sound".into() } else { s }
}

fn id_suffix(id: &str) -> String {
    let tail = id.rsplit('-').next().unwrap_or(id);
    if !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit()) {
        tail.to_string()
    } else {
        id.chars().filter(|c| c.is_ascii_alphanumeric()).take(24).collect()
    }
}

// ---- what has been downloaded: files in the sounds folder + "sounds.json" next to them

/// One downloaded sound. File names are the plain sound name ("Windows XP Error.mp3"); everything
/// else we know about it lives here.
#[derive(Clone, Serialize, Deserialize, Default)]
struct Meta {
    /// Name of the audio file inside the sounds folder.
    filename: String,
    id: String,
    title: String,
    #[serde(default)]
    description: String,
    /// The sound's page on myinstants.com.
    #[serde(default)]
    url: String,
    /// The direct download link of the audio.
    #[serde(default)]
    file: String,
    /// The local file was changed in the Sound Editor (so it can be reverted to the original).
    #[serde(default)]
    edited: bool,
}

/// "sounds.json" lives in the main config folder, next to config.json.
fn meta_path() -> std::path::PathBuf {
    config::config_dir().join("sounds.json")
}

fn meta_load() -> Vec<Meta> {
    if let Some(v) = std::fs::read_to_string(meta_path()).ok().and_then(|t| serde_json::from_str(&t).ok()) {
        return v;
    }
    // Early builds kept "sounds.json" inside the sounds folder, with the keys "file" (local name) and "mp3" (link).
    let old = config::library_dir().join("sounds.json");
    let list: Vec<Value> = std::fs::read_to_string(&old).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    let get = |o: &Value, k: &str| o.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
    list.iter()
        .map(|o| Meta {
            filename: get(o, "file"),
            id: get(o, "id"),
            title: get(o, "title"),
            description: get(o, "description"),
            url: get(o, "url"),
            file: get(o, "mp3"),
            edited: false,
        })
        .collect()
}

fn meta_update(f: impl FnOnce(&mut Vec<Meta>)) {
    let _g = META_LOCK.lock();
    let mut v = meta_load();
    f(&mut v);
    let _ = std::fs::create_dir_all(config::config_dir());
    let tmp = meta_path().with_extension("json.part");
    if let Ok(t) = serde_json::to_string_pretty(&v) {
        if std::fs::write(&tmp, t).is_ok() {
            let _ = std::fs::rename(&tmp, meta_path());
        }
    }
}

/// Older versions named files "Title [12345].mp3": "Title [12345]" -> ("Title", Some("12345")).
fn split_stem(stem: &str) -> (String, Option<String>) {
    if stem.ends_with(']') {
        if let Some(i) = stem.rfind(" [") {
            let inner = &stem[i + 2..stem.len() - 1];
            if !inner.is_empty() && inner.chars().all(|c| c.is_ascii_alphanumeric()) {
                return (stem[..i].to_string(), Some(inner.to_string()));
            }
        }
    }
    (stem.to_string(), None)
}

pub fn display_name(stem: &str) -> String {
    split_stem(stem).0
}

/// Name to show for a file in the sounds folder: the saved title, else the file name.
pub fn title_for(p: &std::path::Path) -> String {
    let fname = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
    if p.parent() == Some(config::library_dir().as_path()) {
        if let Some(m) = meta_load().into_iter().find(|m| m.filename == fname) {
            if !m.title.is_empty() {
                return m.title;
            }
        }
    }
    display_name(p.file_stem().and_then(|s| s.to_str()).unwrap_or(""))
}

/// Every downloaded sound (audio files in the sounds folder that are listed in "sounds.json"), sorted by name.
pub fn audio_files() -> Vec<std::path::PathBuf> {
    fn walk(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, out);
            } else if p
                .extension()
                .and_then(|x| x.to_str())
                .map(|x| ["mp3", "wav", "flac", "ogg", "oga", "opus", "m4a", "aac"].contains(&x.to_ascii_lowercase().as_str()))
                .unwrap_or(false)
            {
                out.push(p);
            }
        }
    }
    let dir = config::library_dir();
    let _ = std::fs::create_dir_all(&dir); // so the folder exists for dropping files into
    let mut v = Vec::new();
    walk(&dir, &mut v);
    let tracked: std::collections::HashSet<String> = meta_load().into_iter().map(|m| m.filename).collect();
    v.retain(|p| p.parent() == Some(dir.as_path()) && p.file_name().and_then(|f| f.to_str()).map(|f| tracked.contains(f)).unwrap_or(false));
    v.sort_by_key(|p| p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_lowercase());
    v
}

/// (sound id -> file, legacy "[id]" suffix -> file)
fn downloaded_maps() -> (HashMap<String, std::path::PathBuf>, HashMap<String, std::path::PathBuf>) {
    let dir = config::library_dir();
    let mut by_id = HashMap::new();
    for m in meta_load() {
        let p = dir.join(&m.filename);
        if p.is_file() {
            by_id.insert(m.id, p);
        }
    }
    let mut legacy = HashMap::new();
    for p in audio_files() {
        if let Some(sfx) = split_stem(p.file_stem().and_then(|s| s.to_str()).unwrap_or("")).1 {
            legacy.insert(sfx, p);
        }
    }
    (by_id, legacy)
}

fn find_downloaded(id: &str) -> Option<std::path::PathBuf> {
    let (mut by_id, mut legacy) = downloaded_maps();
    by_id.remove(id).or_else(|| legacy.remove(&id_suffix(id)))
}

fn unique_path(dir: &std::path::Path, base: &str, ext: &str) -> std::path::PathBuf {
    let first = dir.join(format!("{base}.{ext}"));
    if !first.exists() {
        return first;
    }
    for n in 2..1000 {
        let p = dir.join(format!("{base} ({n}).{ext}"));
        if !p.exists() {
            return p;
        }
    }
    first
}

fn ext_of(url: &str) -> String {
    let path = url.split(['?', '#']).next().unwrap_or("");
    let ext = path.rsplit('/').next().and_then(|f| f.rsplit_once('.')).map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    if ["mp3", "wav", "ogg", "oga", "opus", "m4a", "aac", "flac"].contains(&ext.as_str()) { ext } else { "mp3".into() }
}

/// Downloads `url` (a direct media link, not the API) to `dest` through a ".part" file.
/// `progress` is the id to report byte counts under.
fn fetch_to(url: &str, dest: &std::path::Path, progress: Option<&str>) -> Result<(), String> {
    if let Some(dir) = dest.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("Could not create the folder: {e}"))?;
    }
    let resp = ureq::get(url)
        .set("User-Agent", &user_agent())
        .timeout(Duration::from_secs(60))
        .call()
        .map_err(|e| format!("Download failed: {e}"))?;
    let total = resp.header("Content-Length").and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
    let mut reader = resp.into_reader().take(MAX_BYTES);
    let mut buf = Vec::new();
    let mut chunk = [0u8; 32 * 1024];
    loop {
        let n = reader.read(&mut chunk).map_err(|e| format!("Download failed: {e}"))?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(k) = progress {
            PROGRESS.lock().get_or_insert_with(HashMap::new).insert(k.to_string(), (buf.len() as u64, total));
        }
    }
    if buf.len() < 64 {
        return Err("The downloaded file was empty.".into());
    }
    let tmp = dest.with_extension("part");
    std::fs::write(&tmp, &buf).map_err(|e| format!("Could not save the file: {e}"))?;
    std::fs::rename(&tmp, dest).map_err(|e| format!("Could not save the file: {e}"))?;
    Ok(())
}

pub fn download(id: &str, title: &str, mp3: &str) {
    let item = VIEW.lock().as_ref().and_then(|v| v.items.iter().find(|i| i.id == id).cloned());
    let (id, title, mp3) = (id.to_string(), title.to_string(), absolute(mp3));
    {
        let mut d = DOWNLOADS.lock();
        let m = d.get_or_insert_with(HashMap::new);
        if m.get(&id).map(|s| s == "loading").unwrap_or(false) || find_downloaded(&id).is_some() {
            return;
        }
        m.insert(id.clone(), "loading".into());
    }
    std::thread::spawn(move || {
        let dest = unique_path(&config::library_dir(), &clean_title(&title), &ext_of(&mp3));
        let r = fetch_to(&mp3, &dest, Some(&id));
        PROGRESS.lock().get_or_insert_with(HashMap::new).remove(&id);
        let mut d = DOWNLOADS.lock();
        let m = d.get_or_insert_with(HashMap::new);
        match r {
            Ok(()) => {
                m.remove(&id);
                let entry = Meta {
                    filename: dest.file_name().and_then(|f| f.to_str()).unwrap_or("").to_string(),
                    id,
                    title,
                    description: item.as_ref().map(|i| i.description.clone()).unwrap_or_default(),
                    url: item.as_ref().map(|i| absolute(&i.url)).unwrap_or_default(),
                    file: mp3,
                    edited: false,
                };
                meta_update(|v| {
                    v.retain(|x| x.id != entry.id);
                    v.push(entry);
                });
            }
            Err(e) => {
                m.insert(id, format!("error: {e}"));
            }
        }
    });
}

// ---- pictures dropped onto the key editor as a web link

/// (state "" | "loading" | "done" | "error", local path, error message)
static IMAGE_FETCH: Mutex<(String, String, String)> = Mutex::new((String::new(), String::new(), String::new()));
/// Counts picture requests, so a slow earlier one never overwrites the answer to a newer one.
static IMAGE_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn image_request() -> u64 {
    let seq = IMAGE_SEQ.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
    *IMAGE_FETCH.lock() = ("loading".into(), String::new(), String::new());
    seq
}

fn image_answer(seq: u64, result: Result<String, String>) {
    let mut g = IMAGE_FETCH.lock();
    if IMAGE_SEQ.load(std::sync::atomic::Ordering::SeqCst) != seq {
        return;
    }
    *g = match result {
        Ok(p) => ("done".into(), p, String::new()),
        Err(e) => ("error".into(), String::new(), e),
    };
}

/// A picture chosen or dropped from disk: used as it is when Qt can show it, otherwise converted
/// (in the background) to a PNG copy. The answer comes through `image_fetch_state` like a download.
pub fn prepare_image(path: &str) {
    let seq = image_request();
    let path = std::path::PathBuf::from(path);
    if crate::pictures::readable(&path) {
        image_answer(seq, Ok(path.to_string_lossy().to_string()));
        return;
    }
    std::thread::spawn(move || {
        let r = crate::pictures::displayable(&path).map(|p| p.to_string_lossy().to_string());
        image_answer(seq, r);
    });
}

/// File extension for picture data, judged by its first bytes ("" = not a picture we know).
fn sniff_image(head: &[u8]) -> &'static str {
    if head.starts_with(&[0x89, b'P', b'N', b'G']) {
        "png"
    } else if head.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "jpg"
    } else if head.starts_with(b"GIF8") {
        "gif"
    } else if head.starts_with(b"BM") {
        "bmp"
    } else if head.len() >= 12 && &head[0..4] == b"RIFF" && &head[8..12] == b"WEBP" {
        "webp"
    } else if head.len() >= 12 && &head[4..8] == b"ftyp" {
        // ISO media pictures: AVIF and HEIC/HEIF (judged by the brands listed in the header)
        let size = (u32::from_be_bytes([head[0], head[1], head[2], head[3]]) as usize).clamp(12, head.len());
        let brands: Vec<&[u8]> = std::iter::once(&head[8..12]).chain(head[16.min(size)..size].chunks_exact(4)).collect();
        if brands.iter().any(|b| *b == b"avif" || *b == b"avis") {
            "avif"
        } else if brands.iter().any(|b| matches!(*b, b"heic" | b"heix" | b"heim" | b"heis" | b"hevc" | b"hevx" | b"mif1" | b"msf1")) {
            "heic"
        } else {
            ""
        }
    } else {
        let t = String::from_utf8_lossy(head);
        let t = t.trim_start();
        if t.starts_with("<svg") || (t.starts_with("<?xml") && t.contains("<svg")) { "svg" } else { "" }
    }
}

/// Downloads the picture behind `url` into a scratch folder in the background; the key editor
/// then uses it like a chosen file (it is copied into the images folder when the sound is saved).
pub fn fetch_image(url: &str) {
    let url = url.trim().to_string();
    let seq = image_request();
    std::thread::spawn(move || {
        let result = (|| -> Result<String, String> {
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                return Err("That is not a web link.".into());
            }
            use std::hash::{Hash, Hasher};
            let mut h = std::collections::hash_map::DefaultHasher::new();
            url.hash(&mut h);
            let dir = std::env::temp_dir().join("easyboard-dropped");
            let tmp = dir.join(format!("{:016x}.download", h.finish()));
            fetch_to(&url, &tmp, None)?;
            let mut head = [0u8; 512];
            let n = std::fs::File::open(&tmp).and_then(|mut f| f.read(&mut head)).unwrap_or(0);
            let ext = sniff_image(&head[..n]);
            if ext.is_empty() {
                let _ = std::fs::remove_file(&tmp);
                return Err("That link is not a picture.".into());
            }
            let dest = tmp.with_extension(ext);
            std::fs::rename(&tmp, &dest).map_err(|e| format!("Could not save the picture: {e}"))?;
            let shown = crate::pictures::displayable(&dest)?;
            Ok(shown.to_string_lossy().to_string())
        })();
        image_answer(seq, result);
    });
}

pub fn image_fetch_state() -> String {
    let g = IMAGE_FETCH.lock();
    json!({ "state": g.0, "path": g.1, "error": g.2 }).to_string()
}

// ---- preview (plays through your own output only; uses the direct media link, never the API)

/// (preview id, true while it is still being fetched). The id is a sound id from the Browse tab
/// or a file path from the Downloaded tab.
static PREVIEW: Mutex<Option<(String, bool)>> = Mutex::new(None);

fn preview_status() -> (String, &'static str) {
    let mut p = PREVIEW.lock();
    match p.clone() {
        Some((id, true)) => (id, "loading"),
        Some((id, false)) if crate::core::core().mixer.is_playing("_lib") => (id, "playing"),
        Some(_) => {
            *p = None;
            (String::new(), "")
        }
        None => (String::new(), ""),
    }
}

fn start_preview(key: String, resolve: impl FnOnce() -> Option<std::path::PathBuf> + Send + 'static) {
    let core = crate::core::core();
    {
        let mut p = PREVIEW.lock();
        if let Some((cur, loading)) = p.as_ref() {
            if *cur == key && (*loading || core.mixer.is_playing("_lib")) {
                // second click on the same sound stops it
                *p = None;
                core.stop_library_preview();
                return;
            }
        }
        *p = Some((key.clone(), true));
    }
    core.stop_library_preview();
    std::thread::spawn(move || {
        let path = resolve();
        let still = |g: &Option<(String, bool)>| g.as_ref().map(|(c, _)| *c == key).unwrap_or(false);
        let Some(path) = path else {
            let mut g = PREVIEW.lock();
            if still(&g) {
                *g = None;
            }
            return;
        };
        // decode and start playing without holding the lock (the UI polls state() under it)
        if !still(&PREVIEW.lock()) {
            return; // another sound was clicked meanwhile, or this one was stopped
        }
        let r = crate::core::core().play_library_preview(&path.to_string_lossy());
        let mut g = PREVIEW.lock();
        if still(&g) {
            match r {
                Ok(()) => *g = Some((key, false)),
                Err(e) => {
                    log::warn!("preview failed: {e}");
                    *g = None;
                }
            }
        }
    });
}

/// Stops whatever sound library preview is playing (switching tabs / pages).
pub fn stop_preview() {
    *PREVIEW.lock() = None;
    crate::core::core().stop_library_preview();
}

/// Browse tab: plays the sound from its direct media link (never the API); already downloaded
/// sounds play from disk.
pub fn preview(id: &str, mp3: &str) {
    let (id, mp3) = (id.to_string(), absolute(mp3));
    start_preview(id.clone(), move || {
        // always the original from the web, never the downloaded (and maybe edited) copy
        let p = std::env::temp_dir().join("easyboard-preview").join(format!("{}.mp3", id_suffix(&id)));
        if !p.exists() {
            if let Err(e) = fetch_to(&mp3, &p, None) {
                log::warn!("preview failed: {e}");
                return None;
            }
        }
        Some(p)
    });
}

/// Downloaded tab: plays a file from the sounds folder.
pub fn preview_file(path: &str) {
    let p = std::path::PathBuf::from(path);
    if !inside_library(&p) {
        return;
    }
    start_preview(path.to_string(), move || Some(p));
}

// ---- managing downloaded files

pub fn inside_library(p: &std::path::Path) -> bool {
    // Only sounds that were downloaded through the Sound library (listed in "sounds.json") count;
    // other files that happen to be in the folder do not. The file itself may already be gone
    // (just renamed or converted), so the folder and the name are compared, not the file.
    let Some(name) = p.file_name().and_then(|f| f.to_str()) else { return false };
    let Some(dir) = p.parent() else { return false };
    let (Ok(d), Ok(lib)) = (dir.canonicalize(), config::library_dir().canonicalize()) else { return false };
    d == lib && meta_load().iter().any(|m| m.filename == name)
}

/// Files in the sounds folder as JSON: [{name, description, file, path, preview}].
pub fn downloaded_json() -> String {
    let pv = preview_status();
    let dir = config::library_dir();
    let metas = meta_load();
    let reverting = REVERTING.lock().clone();
    let revert_errors = REVERT_ERRORS.lock().clone().unwrap_or_default();
    let items: Vec<Value> = audio_files()
        .into_iter()
        .map(|p| {
            let fname = p.file_name().and_then(|s| s.to_str()).unwrap_or("").to_string();
            let meta = if p.parent() == Some(dir.as_path()) { metas.iter().find(|m| m.filename == fname) } else { None };
            let name = match meta {
                Some(m) if !m.title.is_empty() => m.title.clone(),
                _ => display_name(p.file_stem().and_then(|s| s.to_str()).unwrap_or("")),
            };
            let path = p.to_string_lossy().to_string();
            let preview = if pv.0 == path { pv.1 } else { "" };
            json!({
                "name": name,
                "description": meta.map(|m| m.description.clone()).unwrap_or_default(),
                "file": fname,
                "path": path,
                "preview": preview,
                "edited": meta.map(|m| m.edited).unwrap_or(false),
                "reverting": reverting.contains(&fname),
                "revertError": revert_errors.get(&fname).cloned().unwrap_or_default(),
            })
        })
        .collect();
    serde_json::to_string(&items).unwrap_or_else(|_| "[]".into())
}

/// Renames a downloaded sound (file and saved title); sounds on the board that use the file follow
/// it. Returns an error message, or "" on success.
/// A downloaded sound was saved in another format: its entry in "sounds.json" follows the new file.
pub fn file_converted(old: &str, new: &str) {
    let (o, n) = (std::path::Path::new(old), std::path::Path::new(new));
    if !inside_library(o) {
        return;
    }
    let old_file = o.file_name().and_then(|f| f.to_str()).unwrap_or("").to_string();
    let new_file = n.file_name().and_then(|f| f.to_str()).unwrap_or("").to_string();
    meta_update(|v| {
        for m in v.iter_mut().filter(|m| m.filename == old_file) {
            m.filename = new_file.clone();
        }
    });
}

/// The Sound Editor saved over a downloaded sound: remember that it no longer is the original.
pub fn mark_edited(path: &str) {
    let p = std::path::Path::new(path);
    if !inside_library(p) {
        return;
    }
    let file = p.file_name().and_then(|f| f.to_str()).unwrap_or("").to_string();
    meta_update(|v| {
        for m in v.iter_mut().filter(|m| m.filename == file) {
            m.edited = true;
        }
    });
}

static REVERTING: Mutex<Vec<String>> = Mutex::new(Vec::new());
static REVERT_ERRORS: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

/// Downloads an edited sound again and replaces the local file with the original. Runs in the
/// background; `downloaded_json` reports "reverting" meanwhile.
pub fn revert(path: &str) {
    let old = std::path::PathBuf::from(path);
    if !inside_library(&old) {
        return;
    }
    let file = old.file_name().and_then(|f| f.to_str()).unwrap_or("").to_string();
    let Some(meta) = meta_load().into_iter().find(|m| m.filename == file) else { return };
    if !meta.edited || meta.file.is_empty() {
        return;
    }
    {
        let mut r = REVERTING.lock();
        if r.contains(&file) {
            return; // already running
        }
        r.push(file.clone());
    }
    REVERT_ERRORS.lock().get_or_insert_with(HashMap::new).remove(&file);
    crate::core::core().stop_library_preview();
    let path = path.to_string();
    std::thread::spawn(move || {
        let ext = ext_of(&meta.file);
        let same_ext = old.extension().and_then(|e| e.to_str()).map(|e| e.eq_ignore_ascii_case(&ext)).unwrap_or(false);
        let dest = if same_ext {
            old.clone()
        } else {
            let stem = old.file_stem().and_then(|s| s.to_str()).unwrap_or("sound").to_string();
            unique_path(&config::library_dir(), &stem, &ext)
        };
        match fetch_to(&absolute(&meta.file), &dest, None) {
            Ok(()) => {
                let new_file = dest.file_name().and_then(|f| f.to_str()).unwrap_or("").to_string();
                if dest != old {
                    crate::core::core().repoint_audio(&path, &dest.to_string_lossy());
                    let _ = std::fs::remove_file(&old);
                }
                meta_update(|v| {
                    for m in v.iter_mut().filter(|m| m.filename == file) {
                        m.filename = new_file.clone();
                        m.edited = false;
                    }
                });
                crate::core::core().audio_changed(&path);
            }
            Err(e) => {
                REVERT_ERRORS.lock().get_or_insert_with(HashMap::new).insert(file.clone(), e);
            }
        }
        REVERTING.lock().retain(|f| *f != file);
    });
}

pub fn rename(path: &str, new_name: &str) -> String {
    let old = std::path::PathBuf::from(path);
    if !inside_library(&old) {
        return "That file is not in the sounds folder.".into();
    }
    let name = new_name.trim();
    if name.is_empty() {
        return "The name can't be empty.".into();
    }
    let stem = old.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let ext = old.extension().and_then(|e| e.to_str()).unwrap_or("mp3");
    // files from older versions keep their "[id]" so they are still recognized as downloaded
    let base = match split_stem(stem).1 {
        Some(sfx) => format!("{} [{}]", clean_title(name), sfx),
        None => clean_title(name),
    };
    let new = old.with_file_name(format!("{base}.{ext}"));
    if new != old {
        if new.exists() && !new.to_string_lossy().eq_ignore_ascii_case(&old.to_string_lossy()) {
            return "A sound with that name already exists.".into();
        }
        if let Err(e) = std::fs::rename(&old, &new) {
            return format!("Could not rename: {e}");
        }
        crate::core::core().repoint_audio(path, &new.to_string_lossy());
    }
    let old_file = old.file_name().and_then(|f| f.to_str()).unwrap_or("").to_string();
    let new_file = new.file_name().and_then(|f| f.to_str()).unwrap_or("").to_string();
    meta_update(|v| {
        for m in v.iter_mut().filter(|m| m.filename == old_file) {
            m.filename = new_file.clone();
            m.title = name.to_string();
        }
    });
    String::new()
}

/// Deletes a downloaded sound. Returns an error message, or "" on success.
pub fn delete(path: &str) -> String {
    let p = std::path::PathBuf::from(path);
    if !inside_library(&p) {
        return "That file is not in the sounds folder.".into();
    }
    crate::core::core().stop_library_preview();
    match std::fs::remove_file(&p) {
        Ok(()) => {
            let file = p.file_name().and_then(|f| f.to_str()).unwrap_or("").to_string();
            meta_update(|v| v.retain(|m| m.filename != file));
            String::new()
        }
        Err(e) => format!("Could not delete: {e}"),
    }
}

/// Current page state as JSON; each item carries its download status:
/// "none" | "loading" | "done" | "error", plus `progress` (0..1, or -1 when the size is unknown).
pub fn state() -> String {
    let v = VIEW.lock();
    let Some(v) = v.as_ref() else {
        return json!({ "state": "idle", "kind": "", "query": "", "message": "", "items": [] }).to_string();
    };
    let dl = DOWNLOADS.lock();
    let pv = preview_status();
    let (by_id, legacy) = downloaded_maps();
    let prog = PROGRESS.lock().clone().unwrap_or_default();
    let items: Vec<Value> = v
        .items
        .iter()
        .map(|i| {
            let status = if by_id.contains_key(&i.id) || legacy.contains_key(&id_suffix(&i.id)) {
                "done".to_string()
            } else {
                match dl.as_ref().and_then(|m| m.get(&i.id)) {
                    Some(s) if s == "loading" => "loading".to_string(),
                    Some(_) => "error".to_string(),
                    None => "none".to_string(),
                }
            };
            let error = dl.as_ref().and_then(|m| m.get(&i.id)).filter(|s| s.starts_with("error")).cloned().unwrap_or_default();
            let preview = if i.id == pv.0 { pv.1 } else { "" };
            let progress = match prog.get(&i.id) {
                Some((d, t)) if *t > 0 => *d as f64 / *t as f64,
                _ => -1.0,
            };
            json!({ "id": i.id, "title": i.title, "description": i.description, "url": absolute(&i.url),
                    "mp3": i.mp3, "status": status, "error": error, "preview": preview, "progress": progress })
        })
        .collect();
    let message = if v.message.is_empty() { rate_note() } else { v.message.clone() };
    json!({ "state": v.state, "kind": v.kind, "query": v.query, "message": message, "items": items,
            "hasNext": v.has_next, "loadingMore": v.loading_more })
    .to_string()
}
