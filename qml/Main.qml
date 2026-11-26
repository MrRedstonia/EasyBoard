import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Qt.labs.platform as Platform
import EasyBoard

ApplicationWindow {
    id: win
    width: 1190
    height: 810
    // Logical pixels: Qt scales them with the display's zoom, so this feels the same on every screen.
    // 810 is the whole window including its title bar. On a screen too short for that (high zoom on a
    // small display) it still fits.
    minimumWidth: 600
    minimumHeight: Math.min(810, Screen.desktopAvailableHeight > 0 ? Screen.desktopAvailableHeight : 810) - frameH
    title: "EasyBoard"
    visible: !backend.startHidden()
    // Theme: EasyBoard defines its own neutral palette for light/dark (so "follow system" looks exactly
    // like picking dark/light by hand) and only takes the accent color from the system. The optional
    // tint mixes that accent into the surfaces.
    SystemPalette { id: sys; colorGroup: SystemPalette.Active }
    property bool themeFollow: true
    property bool themeDark: true
    property var muted: [false, false, false]
    property bool trayFollow: true
    property bool trayThemeDark: true
    property bool sysDark: true
    property bool tintSetting: false
    // a theme replaces the accent tint, the system light/dark choice and the background picture
    readonly property bool tintOn: tintSetting && !themed
    property bool showIds: true

    // ---- theme (Themes page; see THEMES.md). null = EasyBoard's own look
    property var theme: null
    readonly property bool themed: theme !== null
    property int themeRev: 0               // bumped on every theme change (icons are re-read)
    function loadTheme() {
        var raw = backend.themeJson()
        var t = raw === "" ? null : JSON.parse(raw)
        // Qt's own palette first, so menus and pop-ups open in the theme's colors right away
        var spec = ""
        if (t) {
            var map = { window: "window", windowText: "text", base: "base", text: "text", button: "button",
                        buttonText: "text", highlight: "accent", highlightedText: "highlightedText",
                        toolTipBase: "tooltip", toolTipText: "text", link: "accent", linkVisited: "accent" }
            for (var role in map) if (t.colors[map[role]]) spec += role + "=" + t.colors[map[role]] + ";"
        }
        backend.applyThemePalette(spec)
        // (first: everything that changes size because of the new theme must not animate)
        themeSwitching = true
        themeSwitchTimer.restart()
        theme = t
        themeRev++
        styleToolTips()
    }
    // just after a theme is applied, layouts jump to their new size instead of animating there (the dock
    // would otherwise visibly shrink from the old sidebar's size)
    property bool themeSwitching: false
    Timer { id: themeSwitchTimer; interval: 400; onTriggered: win.themeSwitching = false }

    // ---- tooltips: every tooltip in the app is one shared ToolTip; a glass theme (or a theme's
    // <replace part="tooltip">) draws it, otherwise the normal one is used
    property var sharedTip: null
    property bool tipReplaced: false
    Item { Component.onCompleted: { win.sharedTip = ToolTip.toolTip; win.styleToolTips() } }
    Component { id: glassTipComponent; GlassTip {} }
    function styleToolTips() {
        if (!sharedTip) return
        var url = part("tooltip")
        if (url === "" && !glassOn) {
            // never replaced yet: Qt's own tooltip stays as it is
            if (!tipReplaced) return
            // after a glass / theme tooltip: a plain one like Qt's (Qt doesn't give the original back intact)
            var plain = plainTipComponent.createObject(null)
            plain.text = Qt.binding(function () { return win.sharedTip ? win.sharedTip.text : "" })
            setTip(plain)
            return
        }
        var comp = url !== "" ? Qt.createComponent(url) : glassTipComponent
        if (comp.status !== Component.Ready) { console.warn("tooltip:", comp.errorString()); return }
        var tip = comp.createObject(null)
        tip.text = Qt.binding(function () { return win.sharedTip ? win.sharedTip.text : "" })
        setTip(tip)
    }
    // the drawn tooltip is the background; an empty content item gives the tooltip its size
    function setTip(tip) {
        var holder = Qt.createQmlObject('import QtQuick; Item {}', win)
        holder.implicitWidth = Qt.binding(function () { return tip.implicitWidth })
        holder.implicitHeight = Qt.binding(function () { return tip.implicitHeight })
        sharedTip.padding = 0
        sharedTip.background = tip
        sharedTip.contentItem = holder
        tipReplaced = true
    }
    Component {
        id: plainTipComponent
        Rectangle {
            property string text: ""
            implicitWidth: plainLabel.implicitWidth + 12
            implicitHeight: plainLabel.implicitHeight + 8
            color: palette.toolTipBase
            border.color: palette.mid
            Text { id: plainLabel; anchors.centerIn: parent; text: parent.text; color: palette.toolTipText }
        }
    }
    // a color from the theme's <colors>, or the fallback
    function themeColor(key, fallback) { return themed && theme.colors[key] ? theme.colors[key] : fallback }
    // controls grow under the mouse and sink when pressed (<controls hoverScale pressScale>)
    // The theme's factor is for a small control; a wide one (a long drop-down) grows by about as many
    // pixels as a small one would, not by the same percentage, so it never visibly lurches sideways.
    function controlScale(hovered, pressed, width) {
        if (!themed) return 1
        var f = pressed ? theme.controls.pressScale : hovered ? theme.controls.hoverScale : 1
        var damp = width > 0 ? Math.min(1, 140 / width) : 1
        return 1 + (f - 1) * damp
    }
    readonly property bool menuAnimation: themed && theme.controls.menuAnimation
    // surfaces with a sheen get their edge from its rim: no extra flat border on top (one edge, not two)
    function edge(w) { return themed && (theme.depth.sheen > 0 || glassOn) ? 0 : w }
    // the width of a focus / selected / open border: none on glass themes
    function focusEdge(w) { return glassOn ? 0 : w }
    // Sound editor / App routing width (<layout pageWidth pageAlign>): usually at most 920 px from the left
    function pageWidth(avail) {
        var pw = themed ? theme.layout.pageWidth : ""
        if (pw === "full") return avail
        var n = parseInt(pw)
        return Math.min(avail, n > 0 ? n : 920)
    }
    function pageOffset(avail, w) { return themed && theme.layout.pageAlign === "center" ? Math.floor((avail - w) / 2) : 0 }
    // a soft shadow picture (Shadow.qml) and the theme's control corner radius (<controls radius>)
    readonly property string shadowUrl: backend.shadowUrl()
    function controlRadius(h, fallback) { return themed && theme.controls.radius >= 0 ? Math.min(theme.controls.radius, h / 2) : fallback }
    // a theme's replacement for one of EasyBoard's parts (<replace part="..." file="..."/>), or ""
    function part(name) { return themed && theme.parts[name] ? theme.parts[name] : "" }
    // false for elements the theme hides with <hide element="..."/>
    function shown(name) { return !themed || theme.hide.indexOf(name) < 0 }
    // theme animation speed (1 = normal, 0 = no animations); durations are divided by it
    readonly property real animSpeed: themed ? theme.animSpeed : 1
    function dur(ms) { return animSpeed <= 0 ? 0 : ms / animSpeed }
    // theme elements only run while the window can be seen (not in the tray or minimized)
    readonly property bool animate: visible && visibility !== Window.Minimized
    // QML files a theme adds to one of the slots (background, overlay, sidebarTop, sidebarBottom, boardBackground)
    function themeElements(slot) {
        if (!themed) return []
        return theme.elements.filter(function (e) { return e.slot === slot }).map(function (e) { return e.url })
    }
    FontLoader { id: themeFont; source: win.themed && win.theme.font.url !== "" ? win.theme.font.url : "" }
    // without a theme (or a theme without <font>) the system font stays exactly as it is
    font: {
        if (!themed) return Qt.application.font
        var f = { family: Qt.application.font.family, pointSize: Qt.application.font.pointSize }
        if (theme.font.url !== "" && themeFont.status === FontLoader.Ready) f.family = themeFont.name
        else if (theme.font.family !== "") f.family = theme.font.family
        if (theme.font.size > 0) { delete f.pointSize; f.pixelSize = theme.font.size }
        return Qt.font(f)
    }

    // EasyBoard's own look exactly as it will be when "Default" is picked (its card on the Themes page):
    // your settings (system / dark / light, accent tint) and the system accent, never the active theme's
    property string systemAccent: "#3daee9"
    readonly property bool plainDark: themeFollow ? (themed ? sysDark : sys.window.hslLightness < 0.5) : themeDark
    readonly property var defaultLook: {
        var a = Qt.color(systemAccent)
        var v = a.hslSaturation < 0.05 ? a : Qt.hsla(a.hslHue, Math.min(1, a.hslSaturation * 1.25 + 0.2), 0.5, 1)
        var w = Qt.color(plainDark ? "#202020" : "#f3f3f3")
        return { window: String(tintSetting ? Qt.tint(w, Qt.rgba(v.r, v.g, v.b, 0.16)) : w),
                 text: plainDark ? "#ffffff" : "#1b1b1b", accent: systemAccent }
    }
    readonly property bool isDark: themed ? theme.dark : (themeFollow ? sys.window.hslLightness < 0.5 : themeDark)
    readonly property color accent: themeColor("accent", sys.highlight)
    // tray icon: follows the system (taskbar) theme, or its own light/dark choice
    readonly property bool trayDark: trayFollow ? sysDark : trayThemeDark
    // a more saturated version of the accent, used for all tints
    readonly property color vivid: accent.hslSaturation < 0.05 ? accent
        : Qt.hsla(accent.hslHue, Math.min(1, accent.hslSaturation * 1.25 + 0.2), 0.5, 1)
    function tinted(c, a) { return Qt.tint(c, Qt.rgba(vivid.r, vivid.g, vivid.b, a)) }
    // fill for neutral buttons / boxes while tinting is on: level 0 normal, 1 hover, 2 pressed
    function tintFill(level) { return Qt.rgba(vivid.r, vivid.g, vivid.b, [0.18, 0.28, 0.36][level]) }
    // surface color helper used by the pages: base color plus (when enabled) a clear accent tint
    function surface(c, a) { return tintOn ? tinted(c, a) : c }

    palette.window: themeColor("window", surface(isDark ? "#202020" : "#f3f3f3", 0.16))
    palette.windowText: themeColor("text", isDark ? "#ffffff" : "#1b1b1b")
    palette.base: themeColor("base", surface(isDark ? "#2b2b2b" : "#ffffff", 0.12))
    palette.alternateBase: isDark ? "#323232" : "#f7f7f7"
    palette.text: themeColor("text", isDark ? "#ffffff" : "#1b1b1b")
    palette.button: themeColor("button", surface(isDark ? "#2d2d2d" : "#fbfbfb", 0.12))
    palette.buttonText: themeColor("text", isDark ? "#ffffff" : "#1b1b1b")
    palette.brightText: "#ffffff"
    palette.light: isDark ? "#404040" : "#ffffff"
    palette.midlight: isDark ? "#353535" : "#ececec"
    palette.mid: isDark ? "#4a4a4a" : "#c9c9c9"
    palette.dark: isDark ? "#151515" : "#a0a0a0"
    palette.shadow: isDark ? "#000000" : "#707070"
    palette.highlight: accent
    palette.highlightedText: themeColor("highlightedText", accent.hslLightness > 0.7 ? "#000000" : "#ffffff")
    palette.link: accent
    palette.toolTipBase: themeColor("tooltip", isDark ? "#2b2b2b" : "#ffffff")
    palette.toolTipText: themeColor("text", isDark ? "#ffffff" : "#1b1b1b")
    palette.placeholderText: isDark ? Qt.rgba(1, 1, 1, 0.43) : Qt.rgba(0, 0, 0, 0.47)
    color: themeColor("background", palette.window)

    Backend { id: backend }

    // Clicking on empty window space ends text editing in any field.
    TapHandler {
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: win.contentItem.forceActiveFocus()
    }

    // Startup update check (can be switched off in Settings > Updates).
    property int updateTries: 0
    Timer {
        interval: 4000; running: true
        onTriggered: {
            if (JSON.parse(backend.settings()).checkUpdates) { backend.startUpdateCheck(); updatePoll.start() }
        }
    }
    Timer {
        id: updatePoll
        interval: 500; repeat: true
        onTriggered: {
            var raw = backend.updateResult()
            if (raw === "" && ++win.updateTries < 40) return
            updatePoll.stop()
            if (raw === "") return
            var r = JSON.parse(raw)
            if (r.state === "available")
                win.toast(qsTr("EasyBoard %1 is available. See Settings > Updates.").arg(r.latest))
        }
    }

    // Pages get the backend through this property. Writing "backend: backend" inside a
    // page would bind the page's own (empty) property to itself.
    property var backendRef: backend

    // The title bar counts towards the 810: the window manager's frame (known after the window is
    // shown). On Wayland the compositor draws it and doesn't tell apps, so KDE's Breeze height is assumed.
    property int frameH: 0
    function measureFrame() {
        var h = backend.frameHeight()
        frameH = h > 0 ? h : (Qt.platform.pluginName.indexOf("wayland") >= 0 ? 28 : 0)
    }
    onVisibleChanged: if (visible) frameTimer.restart()
    Timer { id: frameTimer; interval: 300; running: win.visible; onTriggered: win.measureFrame() }
    Component.onCompleted: {
        sidebarExpanded = JSON.parse(backend.settings()).sidebarExpanded === true
        loadTheme()
        backend.windowReady()
    }
    // background picture (Settings > Appearance). mode: "board" = only in the Soundboard's box,
    // "behind" = behind the UI elements, "all" = also behind buttons, the sidebar and the side panel
    property var userWallpaper: ({ url: "", mode: "board", blur: 0, opacity: 1, brightness: 1 })
    property string lastWallpaper: ""
    readonly property var wallpaper: themed ? theme.background : userWallpaper
    readonly property bool wallpaperBoard: wallpaper.url !== "" && wallpaper.mode === "board"
    readonly property bool wallpaperBehind: (wallpaper.url !== "" || themeElements("background").length > 0) && wallpaper.mode !== "board"
    readonly property bool wallpaperAll: (wallpaper.url !== "" || themeElements("background").length > 0) && wallpaper.mode === "all"
    // "In the background": controls (buttons, fields, switches, sliders, file boxes, the waveform) stay
    // solid; only "Behind UI elements" lets the picture show through them, and through menus and pop-ups
    // (also with the picture only in the Soundboard: switching between those two modes changes nothing else)
    readonly property bool wallpaperOn: wallpaper.url !== "" || themeElements("background").length > 0
    readonly property bool solidControls: wallpaperOn && wallpaper.mode !== "all"
    // "Add shadows to text": a 1 px shadow under all text, for reading on top of a picture
    readonly property bool textShadow: themed ? theme.background.textShadow === true : (wallpaperOn && userWallpaper.textShadow === true)
    // a faint edge right around the letters (Text.Outline): dark around light text, light around dark text.
    // (A blurred shadow would need each text drawn into a texture first, which makes the letters themselves soft.)
    readonly property color textShadowColor: palette.windowText.hslLightness > 0.5 ? Qt.rgba(0, 0, 0, 0.4) : Qt.rgba(1, 1, 1, 0.45)
    readonly property color opaqueWindow: Qt.rgba(palette.window.r, palette.window.g, palette.window.b, 1)
    // a surface color that lets the picture show through ("all" only)
    function seeThrough(c, a) { return wallpaperAll ? Qt.rgba(c.r, c.g, c.b, a) : c }
    // a see-through control color, made solid while controls must not show the picture
    function solid(c) { return solidControls ? Qt.tint(opaqueWindow, c) : c }
    // The one fill for every button-like control (buttons, drop-downs, the Colors button, small square
    // buttons), so they all match. state: 0 normal, 1 hovered, 2 pressed. glass = never made solid.
    function controlFill(state, glass) {
        var tc = themed ? theme.colors.control : undefined
        var c = tc ? (state === 2 ? Qt.darker(tc, 1.15) : state === 1 ? Qt.lighter(tc, 1.08) : tc)
              : tintOn ? tintFill(state)
              : ink([0.08, 0.13, 0.20][state])
        return glass ? c : solid(c)
    }
    // menus and pop-ups: see-through in "Behind UI elements" mode
    function popupFill(c) { return wallpaperAll ? Qt.rgba(c.r, c.g, c.b, 0.8) : c }
    // ---- frosted glass (a theme's <glass/>): the background is drawn into one texture per frame,
    // slightly larger than the window, and every glass surface blurs its own piece of it (GlassBackdrop)
    readonly property bool glassOn: themed && theme.glass !== null && theme.glass !== undefined
    readonly property real glassMargin: 48
    property Item glassTexture: null
    background: Rectangle {
        color: win.themeColor("background", palette.window)
        clip: true
        ShaderEffectSource {
            id: glassTex
            x: -win.glassMargin
            y: -win.glassMargin
            width: parent.width + 2 * win.glassMargin
            height: parent.height + 2 * win.glassMargin
            visible: false
            // Not redrawn on every frame (180 times a second on a fast screen): the background behind the
            // glass moves slowly, so 30 updates a second look the same and cost far less. Everything that
            // cuts its piece out of this texture is redrawn only when it changes.
            live: false
            sourceItem: win.glassOn ? bgContent : null
            Timer {
                interval: 33
                repeat: true
                running: win.glassOn && win.animate
                onTriggered: glassTex.scheduleUpdate()
            }
            onSourceItemChanged: scheduleUpdate()
            textureSize: Qt.size(Math.max(1, Math.round(width / 2)), Math.max(1, Math.round(height / 2)))
            Component.onCompleted: win.glassTexture = glassTex
        }
        Item {
            id: bgContent
            // larger than the window when glass is on, so glass near the edges still has background to blur
            x: win.glassOn ? -win.glassMargin : 0
            y: win.glassOn ? -win.glassMargin : 0
            width: parent.width - 2 * x
            height: parent.height - 2 * y
            Rectangle { anchors.fill: parent; color: win.themeColor("background", palette.window) }
            Wallpaper { anchors.fill: parent; visible: win.wallpaperBehind && win.wallpaper.url !== ""; settings: win.wallpaper }
            // theme elements behind everything (animated skies, patterns, ...)
            Repeater {
                model: win.themeElements("background")
                Loader { required property string modelData; anchors.fill: parent; active: win.animate; source: modelData }
            }
        }
    }

    // left sidebar: icons only, or icons with the page names (the arrow at the top switches)
    property bool sidebarExpanded: false        // the saved setting (kept for themes that allow it)
    // What is actually shown: page names only when the theme allows them (<sidebar labels>) and shows
    // the expand button. A theme without that button is always collapsed, whatever was saved before.
    readonly property bool canExpand: shown("sidebar.toggle") && (!themed || theme.sidebar.labels)
    readonly property bool sidebarOpen: sidebarExpanded && canExpand
    function toggleSidebar() { sidebarExpanded = !sidebarExpanded; backend.setSidebarExpanded(sidebarExpanded) }

    property bool setupDone: backend.setupDone()
    property var sounds: []
    property var playing: []
    property bool loopAll: false
    property string sortMode: "manual"
    property var progress: ({})
    property bool closeToTray: true
    property string lastPlaying: ""
    property string lastProgress: ""
    property int lastRev: -1
    property int lastShow: 0
    property string page: "board"   // "board" | "studio" | "library" | "routing" | "themes" | "settings"
    onPageChanged: {
        if (page !== "board" && editor.open) editor.closeNow()
        if (!visited[page]) { var v = Object.assign({}, visited); v[page] = true; visited = v }
    }
    // pages opened so far (the others are not built yet)
    property var visited: ({ board: true })

    // Theme names of the tile colors, in the same order as tileColors (see THEMES.md, <tilecolor>)
    readonly property var tileColorNames: ["default", "red", "orange", "yellow", "green", "teal", "blue",
                                           "purple", "magenta", "pink", "lightgreen", "lightblue"]
    // How a sound tile with color `hex` ("" = default) looks: {primary, secondary, text, progress}.
    // A theme can replace any of these per color; the sound itself keeps its color.
    function tileStyle(hex) {
        // <tiles uniform="true">: every tile looks like a tile without a color
        var h = themed && theme.tiles.uniform ? "" : (hex || "").toLowerCase()
        var plain = h === ""
        var name = tileColorNames[tileColors.indexOf(h)] || ""
        var t = themed && name !== "" ? theme.tiles.colors[name] : undefined
        var primary = t && t.primary ? t.primary : (plain ? ink(0.08) : h)
        // (label: the pill behind the name; chip: the small ID / loop / hotkey pills)
        var text = t && t.text ? t.text : (plain ? palette.windowText : "#ffffff")
        return {
            primary: primary,
            secondary: t && t.secondary ? t.secondary : (plain ? ink(0.07) : Qt.rgba(0, 0, 0, 0.16)),
            text: text,
            progress: t && t.progress ? t.progress : (plain ? palette.highlight : text),
            label: t && t.label ? t.label : Qt.rgba(0, 0, 0, 0.2),
            chip: t && t.chip ? t.chip : Qt.rgba(0, 0, 0, 0.6),
            border: themeColor("border", ink(0.14))
        }
    }
    // the swatch color shown for a tile color in menus (the editor, the Colors filter)
    function tileSwatch(hex) { return hex === "" && !(themed && theme.tiles.colors["default"]) ? "" : tileStyle(hex).primary }

    // ---- reorganizing (<order area="..." items="..."/>): position of `name` in `area`.
    // Names the theme leaves out keep their usual order after the ones it lists.
    function orderOf(area, defaults) {
        var list = themed && theme.order[area] ? theme.order[area].slice() : defaults.slice()
        for (var i = 0; i < defaults.length; i++) if (list.indexOf(defaults[i]) < 0) list.push(defaults[i])
        return list
    }
    function orderIndex(area, name, defaults) { return orderOf(area, defaults).indexOf(name) }

    // Tile colors offered in the editor ("" = default)
    readonly property var tileColors: ["", "#e5484d", "#f76b15", "#f5d90a", "#30a46c",
                                       "#12a594", "#0b74d1", "#8e4ec6", "#d63cc4", "#e93d82",
                                       "#5fd08a", "#4cb8ff"]

    // Hotkeys are stored as "Ctrl+Alt+Shift+Super+Key"; on macOS they are shown with the usual symbols.
    function prettyHotkey(v) {
        if (Qt.platform.os !== "osx" || !v) return v
        var sym = { Ctrl: "⌃", Alt: "⌥", Shift: "⇧", Super: "⌘" }
        var keys = { Backspace: "⌫", Delete: "⌦", Enter: "↩", Tab: "⇥", ArrowUp: "↑", ArrowDown: "↓", ArrowLeft: "←",
                     ArrowRight: "→", Minus: "-", Equal: "=", Comma: ",", Period: ".", Slash: "/", Semicolon: ";",
                     PageUp: "Page Up", PageDown: "Page Down" }
        var out = "", key = ""
        v.split("+").forEach(function (p) { if (sym[p]) out += sym[p]; else key = keys[p] || p })
        return out + key
    }
    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    // Recolored copy of an SVG from assets/icons (currentColor -> the given color)
    // (icons asked for in the text color use the theme's <colors glyph> instead, when it has one)
    function iconFor(name, c) {
        themeRev
        var col = themed && theme.colors.glyph && Qt.colorEqual(c, palette.windowText) ? theme.colors.glyph : String(c)
        return backend.iconUrl(name, col)
    }
    function glyphColor(fallback) { return themeColor("glyph", fallback) }

    function reload() {
        sounds = JSON.parse(backend.sounds())
    }

    function toast(text) {
        toastLabel.text = text
        toastBox.opacity = 1
        toastTimer.restart()
    }

    // Poll the Rust core: hotkeys, IPC "show", playing state, messages.
    Timer {
        interval: 100
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var st = JSON.parse(backend.poll())
            if (st.quit) { backend.quit(); return }
            if (st.rev !== win.lastRev) { win.lastRev = st.rev; win.reload(); if (settingsLoader.item && settingsLoader.item.visible) settingsLoader.item.refreshVolumes() }
            if (st.show !== win.lastShow) {
                win.lastShow = st.show
                win.show(); win.raise(); win.requestActivate()
            }
            var pl = JSON.stringify(st.playing)
            if (pl !== win.lastPlaying) { win.lastPlaying = pl; win.playing = st.playing }
            var pg = JSON.stringify(st.progress)
            if (pg !== win.lastProgress) { win.lastProgress = pg; win.progress = st.progress }
            win.loopAll = st.loopAll
            win.sortMode = st.sort
            win.closeToTray = st.closeToTray
            win.tintSetting = st.tint
            var sa = backend.systemAccent()
            if (sa !== "" && sa !== win.systemAccent) win.systemAccent = sa
            win.trayFollow = st.trayFollow
            win.muted = st.muted
            win.trayThemeDark = st.trayDark
            win.sysDark = st.sysDark
            win.themeFollow = st.themeFollow
            win.themeDark = st.themeDark
            win.showIds = st.showIds
            var wp = JSON.stringify(st.wallpaper)
            if (wp !== win.lastWallpaper) { win.lastWallpaper = wp; win.userWallpaper = st.wallpaper }
            if (st.msg !== "") win.toast(st.msg)
        }
    }

    onClosing: function (close) {
        backend.libStopPreview()
        backend.editorStopPreview()
        if (trayIcon.available && setupDone && closeToTray) {
            close.accepted = false
            hide()
        } else {
            backend.quit()
        }
    }

    // ------------------------------------------------------------ tray -----
    // SVG tray icon (recolored for the theme); the PNGs are the fallback when Qt can't load SVGs.
    Image {
        id: trayProbe
        visible: false
        width: 64; height: 64
        sourceSize: Qt.size(64, 64)
        source: win.iconFor("tray", win.trayDark ? "#ededed" : "#222222")
    }
    Platform.SystemTrayIcon {
        id: trayIcon
        visible: true
        icon.source: trayProbe.status === Image.Ready
                     ? trayProbe.source
                     : backend.trayIconUrl(!win.trayDark)
        tooltip: "EasyBoard"
        onActivated: function (reason) {
            if (reason === Platform.SystemTrayIcon.Context && Qt.platform.os === "windows") {
                trayMenu.mainVisible = win.visible
                trayMenu.loopAll = win.loopAll
                var cp = backend.cursorPos().split(",")
                trayMenu.openAt(parseInt(cp[0]), parseInt(cp[1]))
            } else if (reason === Platform.SystemTrayIcon.Trigger) {
                if (win.visible) win.hide()
                else { win.show(); win.raise(); win.requestActivate() }
            }
        }
        menu: Qt.platform.os === "windows" ? null : nativeMenu
    }
    TrayMenu { id: trayMenu; mainWin: win; backend: win.backendRef }
    Platform.Menu {
        id: nativeMenu
        Platform.MenuItem {
                text: win.visible ? qsTr("Hide EasyBoard") : qsTr("Show EasyBoard")
                onTriggered: {
                    if (win.visible) win.hide()
                    else { win.show(); win.raise(); win.requestActivate() }
                }
            }
            Platform.MenuItem { text: qsTr("Stop All Sounds"); onTriggered: backend.stopAll() }
            Platform.MenuItem {
                text: qsTr("Loop Sounds")
                checkable: true
                checked: win.loopAll
                onTriggered: backend.toggleLoopAll()
            }
            Platform.MenuSeparator {}
            Platform.MenuItem { text: qsTr("Quit"); onTriggered: backend.quit() }
    }

    // the sidebar's look comes partly from the theme (<sidebar .../>)
    readonly property bool sidebarRight: themed && theme.sidebar.position === "right"
    // "bottom": no sidebar; a floating dock of round buttons along the bottom instead
    readonly property bool sidebarDock: themed && theme.sidebar.position === "bottom"
    readonly property real dockHeight: 56
    // <layout boardButtons="dock">: Loop / Stop sit in the bottom-left corner, next to the dock
    readonly property bool boardButtonsInDock: sidebarDock && themed && theme.layout.boardButtons === "dock"
    function sideColor(key, fallback) { return themed && theme.sidebar[key] ? theme.sidebar[key] : fallback }
    readonly property var sidebarDefaultOrder: ["@top", "toggle", "board", "studio", "library", "routing", "themes", "|", "@bottom", "settings"]
    // what each sidebar entry is: icon, text fallback, tooltip / label, the page it opens, its <hide> name
    function navInfo(name) {
        var n = {
            toggle:   { icon: "chevron",  glyph: "›", tip: sidebarOpen ? qsTr("Collapse sidebar") : qsTr("Expand sidebar"), page: "", iconSize: 18 },
            board:    { icon: "home",     glyph: "⌂", tip: qsTr("Soundboard"),    page: "board" },
            studio:   { icon: "studio",   glyph: "♫", tip: qsTr("Sound editor"),  page: "studio" },
            library:  { icon: "library",  glyph: "☰", tip: qsTr("Sound library"), page: "library" },
            routing:  { icon: "routing",  glyph: "⇉", tip: qsTr("App routing"),   page: "routing" },
            themes:   { icon: "themes",   glyph: "◐", tip: qsTr("Themes"),        page: "themes" },
            settings: { icon: "settings", glyph: "⚙", tip: qsTr("Settings"),      page: "settings" }
        }[name]
        if (!n) return null
        n.hide = "sidebar." + (name === "toggle" ? "toggle" : n.page)
        return n
    }
    readonly property real sidebarWidth: themed ? theme.sidebar.width : 50
    readonly property real sidebarExpandedWidth: themed ? theme.sidebar.expandedWidth : 190
    Component {
        id: sidebarComponent
        Rectangle {
            height: parent ? parent.height : 0
            width: win.sidebarOpen ? win.sidebarExpandedWidth : win.sidebarWidth
            Behavior on width { enabled: !win.themeSwitching; NumberAnimation { duration: win.dur(140); easing.type: Easing.OutCubic } }
            color: win.themeColor("sidebar", win.seeThrough(win.surface(Qt.tint(palette.window, win.ink(0.08)), 0.14), 0.55))
            clip: true
            GlassBackdrop { anchors.fill: parent; z: -1 }

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: 10
                anchors.bottomMargin: 10
                anchors.leftMargin: 0
                anchors.rightMargin: 0
                spacing: 8

                // The sidebar's contents in order: a theme can reorder them with <order area="sidebar">.
                // "|" is the stretchy gap; "@top" / "@bottom" are the theme's sidebarTop / sidebarBottom elements.
                Repeater {
                    model: win.orderOf("sidebar", win.sidebarDefaultOrder)
                    Item {
                        id: slot
                        required property string modelData
                        readonly property bool gap: modelData === "|"
                        readonly property bool elements: modelData === "@top" || modelData === "@bottom"
                        readonly property var info: win.navInfo(modelData)
                        visible: gap || (elements ? extra.count > 0 : (info !== null && win.shown(info.hide)))
                        Layout.fillWidth: true
                        Layout.fillHeight: gap
                        Layout.preferredHeight: gap ? 0 : elements ? extraCol.implicitHeight : 40

                        Column {
                            id: extraCol
                            width: parent.width
                            visible: slot.elements
                            Repeater {
                                id: extra
                                model: slot.elements ? win.themeElements(slot.modelData === "@top" ? "sidebarTop" : "sidebarBottom") : []
                                Loader { required property string modelData; width: extraCol.width; source: modelData }
                            }
                        }
                        SidebarButton {
                            visible: slot.info !== null
                            x: Math.round((win.sidebarWidth - 40) / 2)
                            width: wide ? slot.width - 2 * x : 40
                            height: 40
                            iconName: slot.info ? slot.info.icon : ""
                            glyph: slot.info ? slot.info.glyph : ""
                            iconSize: slot.info && slot.info.iconSize ? slot.info.iconSize : (win.themed ? win.theme.sidebar.iconSize : 26)
                            iconRotation: slot.modelData === "toggle" && win.sidebarOpen ? 180 : 0
                            tip: slot.info ? slot.info.tip : ""
                            label: slot.modelData === "toggle" ? "" : tip
                            active: slot.info !== null && slot.info.page !== "" && win.page === slot.info.page
                            onClicked: { if (slot.modelData === "toggle") win.toggleSidebar(); else win.page = slot.info.page }
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------- content ----
    Loader {
        anchors.fill: parent
        active: !win.setupDone
        visible: active
        sourceComponent: SetupWizard {
            backend: win.backendRef
            onFinished: {
                win.setupDone = true
                win.reload()
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        visible: win.setupDone

        // ---- sidebar (left, or right when the theme says so)
        Loader {
            Layout.fillHeight: true
            Layout.preferredWidth: item ? item.width : 0
            active: !win.sidebarRight && !win.sidebarDock
            visible: active
            sourceComponent: sidebarComponent
        }

        // ---- center: page + bottom-left action buttons
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // the dock floats below the pages: keep that strip free
            Layout.bottomMargin: win.sidebarDock ? win.dockHeight + 22 : 0
            spacing: 0

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: ["board", "studio", "library", "routing", "themes", "settings"].indexOf(win.page)

                BoardPage {
                    id: board
                    backend: win.backendRef
                    sounds: win.sounds
                    playing: win.playing
                    sortMode: win.sortMode
                    showIds: win.showIds
                    tileColors: win.tileColors
                    progressMap: win.progress
                    onAddRequested: { win.page = "board"; editor.openNew() }
                    onDeleteRequested: function (ids) { win.askDelete(ids) }
                    onEditRequested: function (sound) { editor.openEdit(sound) }
                    onFilesAdded: function (n) { win.toast(n === 1 ? qsTr("Added 1 sound") : qsTr("Added %1 sounds").arg(n)) }
                    onAddFailed: function (m) { win.toast(m) }
                }
                // The other pages are made the first time they are opened (and then kept, so whatever you were
                // doing there is still there): nothing is built for pages you never visit.
                Loader {
                    active: win.visited.studio === true
                    sourceComponent: StudioPage {
                        backend: win.backendRef
                        progressMap: win.progress
                    }
                }
                Loader {
                    active: win.visited.library === true
                    sourceComponent: LibraryPage {
                        backend: win.backendRef
                        onDeleteRequested: function (path, name) { win.askDeleteFile(path, name) }
                        onRevertRequested: function (path, name) { win.pendingRevert = { path: path, name: name }; revertDialog.open() }
                    }
                }
                Loader {
                    active: win.visited.routing === true
                    sourceComponent: AppRoutingPage { backend: win.backendRef }
                }
                Loader {
                    active: win.visited.themes === true
                    sourceComponent: ThemesPage {
                        backend: win.backendRef
                        onThemeChanged: win.loadTheme()
                    }
                }
                Loader {
                    id: settingsLoader
                    active: win.visited.settings === true
                    sourceComponent: SettingsPage {
                        backend: win.backendRef
                        onVisibleChanged: if (visible) refresh()
                    }
                }
            }

            // Loop / Stop under the board; a theme can reorder them (and the "|" gap) with <order area="boardButtons">
            GridLayout {
                visible: win.page === "board" && !win.boardButtonsInDock
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.topMargin: 10
                Layout.bottomMargin: 18
                rows: 1
                columnSpacing: 10

                EbButton {
                    Layout.column: win.orderIndex("boardButtons", "loop", ["loop", "stop", "|"])
                    visible: win.shown("board.loop")
                    text: qsTr("Loop Sounds")
                    accent: win.loopAll
                    implicitWidth: 140
                    // switches at once (the next poll confirms it), so it never shows the old state first
                    onClicked: { win.loopAll = !win.loopAll; backend.toggleLoopAll() }
                }
                EbButton {
                    Layout.column: win.orderIndex("boardButtons", "stop", ["loop", "stop", "|"])
                    visible: win.shown("board.stop")
                    text: qsTr("Stop All Sounds")
                    implicitWidth: 160
                    onClicked: backend.stopAll()
                }
                Item { Layout.column: win.orderIndex("boardButtons", "|", ["loop", "stop", "|"]); Layout.fillWidth: true }
            }
        }

        Loader {
            Layout.fillHeight: true
            Layout.preferredWidth: item ? item.width : 0
            active: win.sidebarRight
            visible: active
            sourceComponent: sidebarComponent
        }

        // ---- add / edit sound panel
        EditorPanel {
            id: editor
            backend: win.backendRef
            colors: win.tileColors
            onDeleteRequested: function (id) { win.askDelete([id]) }
        }
    }

    // Soundboard scroll bar: full window height, at the right edge of the content area
    // (just left of the key editor when that is open).
    EbScrollBar {
        id: boardBar
        visible: win.setupDone && win.page === "board"
        orientation: Qt.Vertical
        x: (editor.visible ? editor.x : win.width) - width
        y: 0
        width: 12
        height: parent.height
        z: 50
        size: board.flick.visibleArea.heightRatio
        position: board.flick.visibleArea.yPosition
        onPositionChanged: {
            if (pressed) board.flick.contentY = board.flick.originY + position * board.flick.contentHeight
        }
    }

    // ------------------------------------------------- delete confirmation ----
    property var pendingDelete: []
    property var pendingFile: ({ path: "", name: "" })      // a downloaded sound (Sound library)
    readonly property bool deletingFile: pendingFile.path !== ""
    function askDelete(ids) {
        pendingFile = { path: "", name: "" }
        pendingDelete = ids
        deleteDialog.open()
    }
    function askDeleteFile(path, name) {
        pendingDelete = []
        pendingFile = { path: path, name: name }
        deleteDialog.open()
    }
    function confirmDelete() {
        if (deletingFile) {
            var err = backend.libDelete(pendingFile.path)
            if (err !== "") toast(err)
            pendingFile = { path: "", name: "" }
            deleteDialog.close()
            return
        }
        for (var i = 0; i < pendingDelete.length; i++)
            backend.removeSound(pendingDelete[i])
        if (pendingDelete.indexOf(editor.editId) >= 0) editor.open = false
        board.clearSelection()
        pendingDelete = []
        deleteDialog.close()
    }
    Popup {
        id: deleteDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        focus: true
        width: 380
        padding: 24
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onClosed: { win.pendingDelete = []; win.pendingFile = { path: "", name: "" } }
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.5) }
        enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 } }
        background: Rectangle {
            radius: 18
            color: win.popupFill(Qt.tint(win.opaqueWindow, win.ink(0.05)))
            border.width: 1
            border.color: win.ink(0.16)
        }
        contentItem: ColumnLayout {
            spacing: 14
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                text: win.deletingFile ? qsTr("Delete downloaded sound?")
                      : win.pendingDelete.length > 1
                      ? qsTr("Delete %1 sounds?").arg(win.pendingDelete.length)
                      : qsTr("Delete sound?")
                font.pixelSize: 20
                font.weight: Font.DemiBold
            }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.7
                text: win.deletingFile
                      ? qsTr("“%1” will be deleted from your computer. Sounds on your board that use it will stop working.").arg(win.pendingFile.name)
                      : win.pendingDelete.length > 1
                      ? qsTr("They will be removed from the board. The audio files themselves are not touched.")
                      : qsTr("It will be removed from the board. The audio file itself is not touched.")
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 8
                Item { Layout.fillWidth: true }
                EbButton { text: qsTr("Cancel"); onClicked: deleteDialog.close() }
                EbButton { text: qsTr("Delete"); danger: true; accent: false; onClicked: win.confirmDelete() }
            }
        }
    }

    // ----------------------------------------------- revert confirmation ----
    property var pendingRevert: ({ path: "", name: "" })
    Popup {
        id: revertDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        focus: true
        width: 400
        padding: 24
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.5) }
        enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 } }
        background: Rectangle {
            radius: 18
            color: win.popupFill(Qt.tint(win.opaqueWindow, win.ink(0.05)))
            border.width: 1
            border.color: win.ink(0.16)
        }
        contentItem: ColumnLayout {
            spacing: 14
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                text: qsTr("Revert sound?")
                font.pixelSize: 20
                font.weight: Font.DemiBold
            }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.7
                text: qsTr("“%1” will be downloaded again and replace your edited version. Your edits will be lost.").arg(win.pendingRevert.name)
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 8
                Item { Layout.fillWidth: true }
                EbButton { text: qsTr("Cancel"); onClicked: revertDialog.close() }
                EbButton {
                    text: qsTr("Revert")
                    accent: true
                    onClicked: {
                        backend.libRevert(win.pendingRevert.path)
                        revertDialog.close()
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ toast ----
    Rectangle {
        id: toastBox
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        radius: 12
        opacity: 0
        color: palette.toolTipBase
        border.color: palette.mid
        width: Math.min(parent.width - 40, toastLabel.implicitWidth + 32)
        height: toastLabel.implicitHeight + 22
        Behavior on opacity { NumberAnimation { duration: 200 } }
        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
            id: toastLabel
            anchors.centerIn: parent
            width: parent.width - 32
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            color: palette.toolTipText
        }
        Timer { id: toastTimer; interval: 3000; onTriggered: toastBox.opacity = 0 }
    }

    // ---- the dock (<sidebar position="bottom">): the pages in one round glass pill, the expand button
    // as its own round button beside it, floating at the bottom in the middle of the window
    Row {
        id: dock
        visible: win.setupDone && win.sidebarDock
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14
        anchors.horizontalCenter: parent.horizontalCenter
        // in a narrow window the dock moves right rather than covering Loop / Stop
        anchors.horizontalCenterOffset: dockButtons.visible ? Math.max(0, dockButtons.x + dockButtons.width + 16 - (parent.width - width) / 2) : 0
        spacing: 10
        z: 40
        readonly property var pages: win.orderOf("sidebar", win.sidebarDefaultOrder).filter(function (n) {
            var i = win.navInfo(n)
            return i !== null && n !== "toggle" && win.shown(i.hide)
        })

        Rectangle {
            id: pill
            height: win.dockHeight
            width: pageRow.width + 16
            radius: height / 2
            color: win.themeColor("sidebar", Qt.rgba(1, 1, 1, 0.2))
            border.width: 1
            border.color: win.themeColor("controlBorder", win.ink(0.14))
            GlassBackdrop { anchors.fill: parent; z: -1; radius: pill.radius }
            Shadow { z: -2 }
            Sheen { anchors.fill: parent; radius: pill.radius }
            Behavior on width { enabled: !win.themeSwitching; NumberAnimation { duration: win.dur(160); easing.type: Easing.OutCubic } }
            // <sidebar slide="true">: one circle marks the open page and slides (and stretches, like a
            // drop of liquid) over to the next page when you click it
            Rectangle {
                id: blob
                readonly property bool on: win.themed && win.theme.sidebar.slide
                readonly property int index: dock.pages.findIndex(function (n) { var i = win.navInfo(n); return i && i.page === win.page })
                // (looked up again whenever the dock's buttons are created: they appear a moment after the
                // page list, and itemAt alone wouldn't notice)
                property int buttonsMade: 0
                readonly property Item target: { buttonsMade; return index >= 0 ? pageRepeater.itemAt(index) : null }
                readonly property real targetX: target ? pageRow.x + target.x : 0
                visible: on && target !== null
                y: pageRow.y
                width: target ? target.width : 40
                height: 40
                radius: 20
                color: win.sideColor("activeColor", palette.highlight)
                // Slides to the open page in about the same time however far it is, so a page next door is
                // reached a little more slowly than a far one (that trip takes just slightly longer).
                Component.onCompleted: { x = targetX; slidPage = win.page }
                // It only slides when you open another page. Anything else that moves it (applying a theme,
                // the dock or window changing size) puts it straight in its place.
                property string slidPage: ""
                function snap() { slide.stop(); x = targetX; slidPage = win.page }
                onVisibleChanged: snap()
                onOnChanged: snap()
                onTargetXChanged: {
                    if (!on || !visible || win.page === slidPage) { slide.stop(); x = targetX; slidPage = win.page; return }
                    slidPage = win.page
                    var near = 1 - Math.min(1, Math.abs(targetX - x) / Math.max(1, pageRow.width - 40))
                    slide.from = x
                    slide.to = targetX
                    slide.duration = win.dur(300 * (1 + 0.12 * near))
                    slide.restart()
                }
                NumberAnimation { id: slide; target: blob; property: "x"; easing.type: Easing.InOutCubic }
                Behavior on width { enabled: blob.on && !win.themeSwitching; NumberAnimation { duration: win.dur(220); easing.type: Easing.OutCubic } }
                // stretched while it travels, round again when it arrives; grows with the button under it
                // (gentle: next door it barely stretches, a long jump stretches more)
                readonly property real stretch: Math.min(0.32, Math.abs(targetX - x) / 320)
                transform: Scale {
                    origin.x: blob.width / 2
                    origin.y: blob.height / 2
                    xScale: (1 + blob.stretch) * (blob.target ? blob.target.scale : 1)
                    yScale: (1 - blob.stretch * 0.3) * (blob.target ? blob.target.scale : 1)
                }
            }
            Row {
                id: pageRow
                anchors.centerIn: parent
                spacing: 6
                Repeater {
                    id: pageRepeater
                    model: dock.pages
                    onItemAdded: blob.buttonsMade++
                    SidebarButton {
                        required property string modelData
                        readonly property var info: win.navInfo(modelData)
                        width: wide ? 40 + labelWidth + 14 : 40
                        height: 40
                        readonly property real labelWidth: labelMetrics.advanceWidth
                        TextMetrics { id: labelMetrics; font.pixelSize: 14; text: info.tip }
                        iconName: info.icon
                        glyph: info.glyph
                        iconSize: 22
                        tip: info.tip
                        active: win.page === info.page
                        drawActive: !blob.on            // the sliding circle shows the open page instead
                        onClicked: win.page = info.page
                    }
                }
            }
        }
        // expand: separate, round
        Rectangle {
            visible: win.shown("sidebar.toggle")
            width: win.dockHeight
            height: win.dockHeight
            radius: height / 2
            color: win.themeColor("sidebar", Qt.rgba(1, 1, 1, 0.2))
            border.width: 1
            border.color: win.themeColor("controlBorder", win.ink(0.14))
            GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius }
            Shadow { z: -2 }
            Sheen { anchors.fill: parent; radius: parent.radius }
            SidebarButton {
                anchors.centerIn: parent
                width: 40
                height: 40
                iconName: "chevron"
                glyph: "›"
                iconSize: 18
                iconRotation: win.sidebarOpen ? 180 : 0
                tip: win.sidebarOpen ? qsTr("Hide page names") : qsTr("Show page names")
                label: ""
                onClicked: win.toggleSidebar()
            }
        }
    }

    // Loop / Stop next to the dock (<layout boardButtons="dock">): two separate round glass buttons with
    // a glyph each, made like the dock
    component DockRound: Item {
        id: dr
        property string icon: ""
        property string tip: ""
        property bool active: false
        signal clicked()
        // keeps the dock's size (so nothing moves); the button itself is the smaller round glass inside
        width: win.dockHeight
        height: win.dockHeight
        Rectangle {
            id: drButton
            anchors.centerIn: parent
            width: 46
            height: 46
            radius: height / 2
            color: dr.active ? win.sideColor("activeColor", palette.highlight)
                 : drMouse.containsMouse ? win.sideColor("hoverColor", win.ink(0.12))
                 : win.themeColor("control", win.ink(0.08))
            border.width: win.edge(1)
            border.color: win.themeColor("controlBorder", win.ink(0.14))
            GlassBackdrop { anchors.fill: parent; z: -1; radius: drButton.radius }
            Shadow { z: -2 }
            Sheen { anchors.fill: parent; radius: drButton.radius }
            scale: drMouse.pressed ? 0.94 : drMouse.containsMouse ? (win.themed ? win.theme.sidebar.hoverScale : 1.06) : 1
            Behavior on scale { NumberAnimation { duration: win.dur(160); easing.type: Easing.OutCubic } }
            // the glyph, in the exact middle
            Image {
                anchors.centerIn: parent
                width: 26
                height: 26
                sourceSize: Qt.size(52, 52)
                source: win.iconFor(dr.icon, win.sideColor("iconColor", palette.windowText))
                fillMode: Image.PreserveAspectFit
                smooth: true
            }
            MouseArea {
                id: drMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: dr.clicked()
            }
            ToolTip.visible: drMouse.containsMouse && !(win.themed && !win.theme.sidebar.tooltips)
            ToolTip.text: dr.tip
            ToolTip.delay: 400
        }
    }
    Row {
        id: dockButtons
        visible: win.setupDone && win.boardButtonsInDock && win.page === "board"
        anchors.left: parent.left
        anchors.leftMargin: 20
        anchors.verticalCenter: dock.verticalCenter
        spacing: 10
        z: 40
        DockRound {
            visible: win.shown("board.loop")
            icon: "loop"
            tip: win.loopAll ? qsTr("Stop looping sounds") : qsTr("Loop sounds")
            active: win.loopAll
            onClicked: { win.loopAll = !win.loopAll; backend.toggleLoopAll() }
        }
        DockRound {
            visible: win.shown("board.stop")
            icon: "stop"
            tip: qsTr("Stop all sounds")
            onClicked: backend.stopAll()
        }
    }

    // theme decorations above everything; they can't be clicked, so the app stays usable
    Item {
        anchors.fill: parent
        z: 50
        enabled: false
        visible: win.setupDone
        Repeater {
            model: win.themeElements("overlay")
            Loader { required property string modelData; anchors.fill: parent; active: win.animate; source: modelData }
        }
    }

    component SidebarButton: AbstractButton {
        id: sb
        property string iconName        // name of an SVG in assets/icons
        property string glyph           // text fallback if the SVG can't be shown
        property int iconSize: 26
        property real iconRotation: 0
        property string tip
        property string label: tip      // shown next to the icon when the sidebar is expanded
        property bool active: false
        property bool drawActive: true  // false: the open page's fill is drawn by someone else (the dock's sliding circle)
        // the theme can set the icon color and the active / hover fills (<sidebar iconColor activeColor hoverColor>)
        readonly property color inkColor: win.sideColor("iconColor", palette.windowText)
        readonly property bool wide: win.sidebarOpen && label !== ""
        padding: 0
        hoverEnabled: true
        // grows a little under the mouse when the theme asks for it (<sidebar hoverScale="1.15">)
        scale: hovered ? (win.themed ? win.theme.sidebar.hoverScale : 1) : 1
        // no overshoot: what you see while it grows is what it looks like when it's grown
        Behavior on scale { NumberAnimation { duration: win.dur(160); easing.type: Easing.OutCubic } }
        // Buttons that grow are drawn as one picture (at twice the size, so it stays sharp). Otherwise Qt
        // draws a moving item a little differently from a still one, and the icon visibly jumps when the
        // growing stops.
        layer.enabled: win.themed && win.theme.sidebar.hoverScale > 1
        layer.smooth: true
        layer.mipmap: true
        layer.textureSize: Qt.size(width * 2, height * 2)
        ToolTip.visible: hovered && !wide && !(win.themed && !win.theme.sidebar.tooltips)
        ToolTip.text: tip
        ToolTip.delay: 400
        Accessible.name: tip
        background: Rectangle {
            radius: win.sidebarDock ? height / 2 : (win.themed ? win.theme.sidebar.radius : 12)
            color: sb.active ? (sb.drawActive ? win.sideColor("activeColor", palette.highlight) : "transparent")
                 : sb.hovered ? win.sideColor("hoverColor", win.ink(0.12))
                 : "transparent"
        }
        contentItem: Item {
            // the icon keeps its place in the 40 px column, so it doesn't move when the sidebar opens
            Item {
                id: iconBox
                width: 40
                height: 40
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                Image {
                    id: svg
                    anchors.centerIn: parent
                    width: sb.iconSize
                    height: sb.iconSize
                    sourceSize: Qt.size(sb.iconSize * 2, sb.iconSize * 2)
                    source: sb.iconName !== "" ? win.iconFor(sb.iconName, sb.inkColor) : ""
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    rotation: sb.iconRotation
                    Behavior on rotation { NumberAnimation { duration: 140 } }
                }
                Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    anchors.centerIn: parent
                    visible: svg.status !== Image.Ready
                    text: sb.glyph
                    font.pixelSize: sb.iconSize
                    color: sb.inkColor
                }
            }
            Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                anchors.left: iconBox.right
                anchors.leftMargin: 2
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                visible: sb.wide
                text: sb.label
                elide: Text.ElideRight
                font.pixelSize: 14
                color: sb.inkColor
            }
        }
    }
}
