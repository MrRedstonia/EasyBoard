//! Themes: folders in `<config>/themes/`, each with a `theme.xml` (see THEMES.md) and any pictures,
//! fonts, icons and QML/JavaScript files it uses. The built-in themes are written there on startup.

use parking_lot::Mutex;
use serde_json::{json, Map, Value};
use std::{
    collections::HashMap,
    fs,
    io::Read,
    path::{Component, Path, PathBuf},
};

pub fn themes_dir() -> PathBuf {
    crate::config::config_dir().join("themes")
}

/// Marks a built-in theme folder that EasyBoard manages. Delete it to keep your own edits: the
/// folder is then never touched again.
const MARKER: &str = ".builtin";

macro_rules! files {
    ($dir:literal: $($f:literal),* $(,)?) => {
        &[$(($f, include_bytes!(concat!("../themes/", $dir, "/", $f)) as &[u8])),*]
    };
}

/// (folder, [(file, contents)])
const BUILTIN: &[(&str, &[(&str, &[u8])])] = &[
    ("kitty", files!("kitty": "theme.xml", "Background.qml", "BoardPattern.qml", "paw.svg", "bow.svg", "cat.svg", "bow-pink.svg", "paw-pink.svg", "HeartSpinner.qml", "HeartId.qml")),
    ("liquid-glass", files!("liquid-glass": "theme.xml", "Blobs.qml", "GlassId.qml")),
    ("oled", files!("oled": "theme.xml")),
    ("starry-night", files!("starry-night": "theme.xml", "Sky.qml", "moon.svg")),
];

/// Writes the built-in themes into the themes folder: new ones, and changed versions of ones that
/// still carry the marker (so an app update brings theme fixes along).
pub fn install_builtins() {
    // built-in themes this version no longer ships (still carrying the marker, so never edited by the
    // user) are taken away
    if let Ok(rd) = fs::read_dir(themes_dir()) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if e.path().join(MARKER).exists() && !BUILTIN.iter().any(|(f, _)| *f == name) {
                let _ = fs::remove_dir_all(e.path());
            }
        }
    }
    for (folder, files) in BUILTIN {
        // the marker holds a fingerprint of the theme's files, so any change in them is installed
        let version = format!(
            "{:016x}",
            files.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, (name, bytes)| {
                name.bytes().chain(bytes.iter().copied()).fold(h, |h, b| (h ^ b as u64).wrapping_mul(0x0100_0000_01b3))
            })
        );
        let dir = themes_dir().join(folder);
        let marker = dir.join(MARKER);
        let write = if !dir.exists() {
            true
        } else {
            match fs::read_to_string(&marker) {
                Ok(v) => v.trim() != version,
                Err(_) => false, // marker removed: the user owns this folder now
            }
        };
        if !write {
            continue;
        }
        // an update starts from an empty folder, so files a newer version dropped don't linger
        // (the folder still carries the marker, so it was never edited by hand)
        if dir.exists() {
            let _ = fs::remove_dir_all(&dir);
        }
        for (name, bytes) in files.iter() {
            let path = dir.join(name);
            if let Some(p) = path.parent() {
                let _ = fs::create_dir_all(p);
            }
            let _ = fs::write(&path, bytes);
        }
        let _ = fs::write(&marker, &version);
    }
}

fn is_builtin(dir: &Path) -> bool {
    dir.join(MARKER).exists()
}

fn file_url(p: &Path) -> String {
    let s = p.to_string_lossy().replace('\\', "/");
    if s.starts_with('/') { format!("file://{s}") } else { format!("file:///{s}") }
}

/// A file inside the theme folder (never outside it), as a path.
fn inside(dir: &Path, rel: &str) -> Option<PathBuf> {
    let rel = Path::new(rel.trim());
    if rel.as_os_str().is_empty() || rel.components().any(|c| !matches!(c, Component::Normal(_))) {
        return None;
    }
    let p = dir.join(rel);
    p.exists().then_some(p)
}

fn read_xml(dir: &Path) -> Result<String, String> {
    fs::read_to_string(dir.join("theme.xml")).map_err(|e| format!("theme.xml: {e}"))
}

/// Themes in the themes folder: [{id, name, author, description, version, builtin, window, accent,
/// text, preview}], sorted by name.
pub fn list() -> Vec<Value> {
    let mut out = Vec::new();
    let Ok(rd) = fs::read_dir(themes_dir()) else { return out };
    for e in rd.flatten() {
        let dir = e.path();
        if !dir.is_dir() {
            continue;
        }
        let Ok(text) = read_xml(&dir) else { continue };
        let Ok(doc) = roxmltree::Document::parse(&text) else { continue };
        let root = doc.root_element();
        if root.tag_name().name() != "theme" {
            continue;
        }
        let id = e.file_name().to_string_lossy().into_owned();
        let colors = root.children().find(|n| n.has_tag_name("colors"));
        let c = |k: &str| colors.and_then(|n| n.attribute(k)).unwrap_or("").to_string();
        let preview = root
            .attribute("thumbnail")
            .or(root.attribute("preview"))
            .and_then(|p| inside(&dir, p))
            .map(|p| file_url(&p))
            .unwrap_or_default();
        out.push(json!({
            "id": id,
            "name": root.attribute("name").unwrap_or(&id),
            "author": root.attribute("author").unwrap_or(""),
            "description": root.attribute("description").unwrap_or(""),
            "version": root.attribute("version").unwrap_or(""),
            "builtin": is_builtin(&dir),
            "window": c("window"),
            "accent": c("accent"),
            "text": c("text"),
            "preview": preview,
        }));
    }
    out.sort_by_key(|v| v["name"].as_str().unwrap_or("").to_lowercase());
    out
}

/// Icons the active theme replaces: icon name -> file.
static ICONS: Mutex<Option<(String, HashMap<String, PathBuf>)>> = Mutex::new(None);

/// The active theme's replacement for one of EasyBoard's icons: (theme id, file).
pub fn icon_override(name: &str) -> Option<(String, PathBuf)> {
    let g = ICONS.lock();
    let (id, map) = g.as_ref()?;
    map.get(name).map(|p| (id.clone(), p.clone()))
}

/// Reads a theme for the UI (see THEMES.md for every key). Also activates its icons.
/// `id` "" = the default look: returns Null.
pub fn load(id: &str) -> Result<Value, String> {
    *ICONS.lock() = None;
    if id.is_empty() {
        return Ok(Value::Null);
    }
    let dir = themes_dir().join(id);
    let text = read_xml(&dir)?;
    let doc = roxmltree::Document::parse(&text).map_err(|e| format!("theme.xml: {e}"))?;
    let root = doc.root_element();
    if root.tag_name().name() != "theme" {
        return Err("theme.xml: the outer element must be <theme>".into());
    }
    let child = |tag: &str| root.children().find(|n| n.has_tag_name(tag));
    // all attributes of an element as strings
    let attrs = |tag: &str| -> Map<String, Value> {
        child(tag)
            .map(|n| n.attributes().map(|a| (a.name().to_string(), Value::String(a.value().to_string()))).collect())
            .unwrap_or_default()
    };
    let num = |m: &Map<String, Value>, k: &str, d: f64| -> f64 {
        m.get(k).and_then(|v| v.as_str()).and_then(|s| s.trim().parse().ok()).unwrap_or(d)
    };
    let url_of = |rel: Option<&str>| rel.and_then(|r| inside(&dir, r)).map(|p| file_url(&p)).unwrap_or_default();

    let mut colors = attrs("colors");
    let dark = colors.remove("dark").and_then(|v| v.as_str().map(|s| s != "false")).unwrap_or(true);

    let font = attrs("font");
    let bg = attrs("background");
    let side = attrs("sidebar");
    let layout = attrs("layout");
    let anim = attrs("animations");

    let mut icons = HashMap::new();
    let mut icon_json = Map::new();
    for n in root.children().filter(|n| n.has_tag_name("icon")) {
        if let (Some(name), Some(p)) = (n.attribute("name"), n.attribute("file").and_then(|f| inside(&dir, f))) {
            icon_json.insert(name.to_string(), Value::String(file_url(&p)));
            icons.insert(name.to_string(), p);
        }
    }
    *ICONS.lock() = Some((id.to_string(), icons));

    let hide: Vec<Value> = root
        .children()
        .filter(|n| n.has_tag_name("hide"))
        .filter_map(|n| n.attribute("element").map(|e| Value::String(e.to_string())))
        .collect();
    // <replace part="spinner" file="Heart.qml"/>: a QML file drawn instead of one of EasyBoard's parts
    let mut parts = Map::new();
    for n in root.children().filter(|n| n.has_tag_name("replace")) {
        if let Some(part) = n.attribute("part") {
            let url = url_of(n.attribute("file"));
            if !url.is_empty() {
                parts.insert(part.trim().to_string(), Value::String(url));
            }
        }
    }
    let elements: Vec<Value> = root
        .children()
        .filter(|n| n.has_tag_name("element"))
        .filter_map(|n| {
            let url = url_of(n.attribute("file"));
            (!url.is_empty()).then(|| json!({ "slot": n.attribute("slot").unwrap_or("overlay"), "url": url }))
        })
        .collect();

    // sound tiles: <tiles .../> and one <tilecolor name="red" primary=".." secondary=".." .../> per color
    let tiles = attrs("tiles");
    let tile_glyph_url = url_of(tiles.get("glyphFile").and_then(|v| v.as_str()));
    let mut tile_colors = Map::new();
    for n in root.children().filter(|n| n.has_tag_name("tilecolor")) {
        if let Some(name) = n.attribute("name") {
            let m: Map<String, Value> = n
                .attributes()
                .filter(|a| a.name() != "name")
                .map(|a| (a.name().to_string(), Value::String(a.value().to_string())))
                .collect();
            tile_colors.insert(name.trim().to_lowercase().replace([' ', '_'], ""), Value::Object(m));
        }
    }
    // <order area="sidebar" items="board, studio, |, settings"/>
    let mut order = Map::new();
    for n in root.children().filter(|n| n.has_tag_name("order")) {
        if let (Some(area), Some(items)) = (n.attribute("area"), n.attribute("items")) {
            let list: Vec<Value> = items
                .split(',')
                .map(|i| i.trim())
                .filter(|i| !i.is_empty())
                .map(|i| Value::String(i.to_string()))
                .collect();
            order.insert(area.trim().to_string(), Value::Array(list));
        }
    }

    // <glass blur=".." tint=".." rim=".." highlight=".." saturation=".." brightness=".."/>
    let glass = child("glass").map(|_| {
        let g = attrs("glass");
        let gs = |k: &str, d: &str| g.get(k).and_then(|v| v.as_str()).unwrap_or(d).to_string();
        json!({
            "blur": num(&g, "blur", 0.8).clamp(0.0, 1.0),
            "tint": gs("tint", "#26ffffff"),
            "rim": gs("rim", "#80ffffff"),
            "highlight": gs("highlight", "#33ffffff"),
            "saturation": num(&g, "saturation", 0.3).clamp(-1.0, 1.0),
            "brightness": num(&g, "brightness", 0.0).clamp(-1.0, 1.0),
            "lens": num(&g, "lens", 1.0).clamp(1.0, 1.5),
            // clear glass: a band this wide (px) along the edge bends what's behind (0 = none)
            "refraction": num(&g, "refraction", 0.0).clamp(0.0, 60.0),
            // how far it bends (what is read into the band, relative to its size: < 1 pulls in from outside)
            "edgeScale": num(&g, "edgeScale", 0.85).clamp(0.5, 1.0),
            "edgeBrightness": num(&g, "edgeBrightness", 0.08).clamp(-1.0, 1.0),
            "edgeSaturation": num(&g, "edgeSaturation", 0.5).clamp(-1.0, 1.0),
            "shade": gs("shade", "#00000000"),
        })
    });

    let bg_s = |k: &str| bg.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let side_s = |k: &str, d: &str| side.get(k).and_then(|v| v.as_str()).unwrap_or(d).to_string();
    Ok(json!({
        "id": id,
        "name": root.attribute("name").unwrap_or(id),
        "dir": file_url(&dir),
        "dark": dark,
        "colors": colors,
        "font": {
            "family": font.get("family").and_then(|v| v.as_str()).unwrap_or(""),
            "url": url_of(font.get("file").and_then(|v| v.as_str())),
            "size": num(&font, "size", 0.0),
        },
        "background": {
            "color": bg_s("color"),
            "url": url_of(bg.get("image").and_then(|v| v.as_str())),
            "mode": match bg_s("mode").as_str() { m @ ("board" | "behind" | "all") => m.to_string(), _ => "behind".into() },
            "blur": num(&bg, "blur", 0.0).clamp(0.0, 1.0),
            "opacity": num(&bg, "opacity", 1.0).clamp(0.0, 1.0),
            "brightness": num(&bg, "brightness", 1.0).clamp(0.0, 2.0),
            "textShadow": bg_s("textShadow") == "true",
        },
        "sidebar": {
            // "left", "right", or "bottom": a floating dock of round buttons along the bottom
            "position": match side_s("position", "left").as_str() { "right" => "right", "bottom" => "bottom", _ => "left" },
            "activeColor": side_s("activeColor", ""),
            "hoverColor": side_s("hoverColor", ""),
            "iconColor": side_s("iconColor", ""),
            "hoverScale": num(&side, "hoverScale", 1.0).clamp(1.0, 1.5),
            "tooltips": side_s("tooltips", "true") != "false",
            // false: never page names next to the icons (the sidebar / dock stays collapsed)
            "labels": side_s("labels", "true") != "false",
            // dock: the open page's circle slides over to the clicked one, like a drop of liquid
            "slide": side_s("slide", "false") == "true",
            "width": num(&side, "width", 50.0).clamp(40.0, 120.0),
            "expandedWidth": num(&side, "expandedWidth", 190.0).clamp(120.0, 400.0),
            "radius": num(&side, "radius", 12.0).clamp(0.0, 20.0),
            "iconSize": num(&side, "iconSize", 26.0).clamp(12.0, 36.0),
        },
        "layout": {
            "radius": num(&layout, "radius", -1.0),
            // "center": the Soundboard's search field sits in the middle of the header
            "search": layout.get("search").and_then(|v| v.as_str()).unwrap_or(""),
            // "dock": Loop / Stop sit in the bottom-left corner, next to the dock
            "boardButtons": layout.get("boardButtons").and_then(|v| v.as_str()).unwrap_or(""),
            // Sound editor / App routing: "full" width (or a maximum in pixels; default 920), and
            // "left" (default) or "center" when narrower than the page
            "pageWidth": layout.get("pageWidth").and_then(|v| v.as_str()).unwrap_or(""),
            "pageAlign": layout.get("pageAlign").and_then(|v| v.as_str()).unwrap_or(""),
        },
        // <controls radius="..."/>: corner radius of buttons, drop-downs and fields (999 = fully round)
        "controls": {
            "radius": num(&attrs("controls"), "radius", -1.0),
            // frosted glass under buttons, drop-downs and fields (needs <glass>)
            "glass": attrs("controls").get("glass").and_then(|v| v.as_str()) == Some("true"),
            // grow under the mouse / sink when pressed (1 = off)
            "hoverScale": num(&attrs("controls"), "hoverScale", 1.0).clamp(1.0, 1.2),
            "pressScale": num(&attrs("controls"), "pressScale", 1.0).clamp(0.8, 1.0),
            // menus fade and scale in when they open
            "menuAnimation": attrs("controls").get("menuAnimation").and_then(|v| v.as_str()) == Some("true"),
            // tooltips on small icon buttons (App routing's + and ✕)
            "tooltips": attrs("controls").get("tooltips").and_then(|v| v.as_str()) != Some("false"),
        },
        // <depth shadow="0.3" sheen="0.3"/>: soft shadows under tiles, boxes, buttons and the dock, and a
        // light sheen on top of them, for a raised, 3D look
        "depth": {
            "shadow": num(&attrs("depth"), "shadow", 0.0).clamp(0.0, 1.0),
            "sheen": num(&attrs("depth"), "sheen", 0.0).clamp(0.0, 1.0),
            // a shadow under the sound editor's waveform lines (for light backgrounds)
            "waveShadow": num(&attrs("depth"), "waveShadow", 0.0).clamp(0.0, 1.0),
        },
        "tiles": {
            "radius": num(&tiles, "radius", -1.0),
            "glyph": tiles.get("glyph").and_then(|v| v.as_str()).unwrap_or(""),
            "glyphUrl": tile_glyph_url,
            "glyphSize": num(&tiles, "glyphSize", 0.0),
            "glyphOpacity": num(&tiles, "glyphOpacity", -1.0),
            // every tile in the theme's "default" tile color, whatever color the sound has
            "uniform": tiles.get("uniform").and_then(|v| v.as_str()) == Some("true"),
            // glass under each tile too (needs <glass>)
            "glass": tiles.get("glass").and_then(|v| v.as_str()) == Some("true"),
            // "left" (default) or "center": where the columns of tiles sit in the Soundboard's box
            // tile width in pixels (0 = the usual 190); pictures="false": no picture square, just the name;
            // ids="false": never show the sound IDs on tiles
            "width": num(&tiles, "width", 0.0).clamp(0.0, 360.0),
            "pictures": tiles.get("pictures").and_then(|v| v.as_str()) != Some("false"),
            "ids": tiles.get("ids").and_then(|v| v.as_str()) != Some("false"),
            "align": if tiles.get("align").and_then(|v| v.as_str()) == Some("center") { "center" } else { "left" },
            "hoverScale": num(&tiles, "hoverScale", 1.0).clamp(1.0, 1.3),
            "editButton": tiles.get("editButton").and_then(|v| v.as_str()) != Some("false"),
            // the round select button in the corner shows on hover (it still shows while selecting)
            "selectButton": tiles.get("selectButton").and_then(|v| v.as_str()) != Some("false"),
            "colors": tile_colors,
        },
        "order": order,
        "animSpeed": num(&anim, "speed", 1.0).clamp(0.0, 10.0),
        "icons": icon_json,
        "hide": hide,
        "elements": elements,
        "parts": parts,
        "glass": glass,
    }))
}

/// Installs a theme from a zip file (theme.xml at the top, or inside one folder). A theme with the
/// same folder name is replaced. Returns the theme's id.
pub fn install_zip(path: &Path) -> Result<String, String> {
    let file = fs::File::open(path).map_err(|e| format!("Could not open the zip file: {e}"))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|_| "That is not a zip file.".to_string())?;

    // where theme.xml is: "" (top level) or "folder/"
    let mut prefix = None;
    for i in 0..zip.len() {
        let f = zip.by_index(i).map_err(|e| e.to_string())?;
        let Some(name) = f.enclosed_name() else { continue };
        if name.file_name().map(|n| n == "theme.xml").unwrap_or(false) && name.components().count() <= 2 {
            let p = name.parent().map(|p| p.to_path_buf()).unwrap_or_default();
            if prefix.as_ref().map(|q: &PathBuf| p.components().count() < q.components().count()).unwrap_or(true) {
                prefix = Some(p);
            }
        }
    }
    let prefix = prefix.ok_or("The zip file has no theme.xml.")?;
    let id = prefix
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .or_else(|| path.file_stem().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "theme".into());
    let id: String = id.chars().map(|c| if c.is_alphanumeric() || c == '-' || c == '_' || c == ' ' { c } else { '-' }).collect();
    let id = id.trim().to_string();
    if id.is_empty() || id.starts_with('.') {
        return Err("The theme folder name is not usable.".into());
    }

    // unpack next to the themes, then swap it in
    let base = themes_dir();
    fs::create_dir_all(&base).map_err(|e| e.to_string())?;
    let tmp = base.join(format!(".installing-{id}"));
    let _ = fs::remove_dir_all(&tmp);
    let result = (|| -> Result<(), String> {
        for i in 0..zip.len() {
            let mut f = zip.by_index(i).map_err(|e| e.to_string())?;
            // enclosed_name refuses "../" and absolute paths, so nothing lands outside the folder
            let Some(name) = f.enclosed_name() else { continue };
            let Ok(rel) = name.strip_prefix(&prefix) else { continue };
            if rel.as_os_str().is_empty() {
                continue;
            }
            let out = tmp.join(rel);
            if f.is_dir() {
                fs::create_dir_all(&out).map_err(|e| e.to_string())?;
            } else {
                if let Some(p) = out.parent() {
                    fs::create_dir_all(p).map_err(|e| e.to_string())?;
                }
                let mut buf = Vec::new();
                f.read_to_end(&mut buf).map_err(|e| e.to_string())?;
                fs::write(&out, buf).map_err(|e| e.to_string())?;
            }
        }
        let text = read_xml(&tmp)?;
        roxmltree::Document::parse(&text).map_err(|e| format!("theme.xml: {e}"))?;
        Ok(())
    })();
    if let Err(e) = result {
        let _ = fs::remove_dir_all(&tmp);
        return Err(e);
    }
    let dest = base.join(&id);
    let _ = fs::remove_dir_all(&dest);
    fs::rename(&tmp, &dest).map_err(|e| format!("Could not install the theme: {e}"))?;
    Ok(id)
}

/// Deletes an installed theme folder.
pub fn remove(id: &str) -> Result<(), String> {
    if id.is_empty() || id.contains(['/', '\\']) || id.starts_with('.') {
        return Err("Unknown theme.".into());
    }
    let dir = themes_dir().join(id);
    if is_builtin(&dir) {
        return Err("Built-in themes can't be removed.".into());
    }
    fs::remove_dir_all(dir).map_err(|e| e.to_string())
}

