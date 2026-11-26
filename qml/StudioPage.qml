import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Effects
import QtQuick.Layouts

// Sound editor: pick, drop or record audio, cut / copy / paste / delete parts, add pauses, then crop and
// change speed / pitch / volume (dB) / fades / reverse / compressor (only on the selection when there is one).
Item {
    id: root
    property var backend
    property var progressMap: ({})

    property string filePath: ""
    property string fileName: ""
    property var peaks: []
    property real duration: 0
    property real startFrac: 0
    property real endFrac: 1
    property string status: ""
    property bool statusError: false

    // selection (fractions of the whole audio, -1 = none) and the click-set playback position
    property real selA: -1
    property real selB: -1
    property real playFrac: -1
    property real ctxFrac: 0          // where the right-click menu was opened
    readonly property bool hasSel: selA >= 0 && selB > selA
    // One undo history for everything: edits of the audio ("e", kept by the core) and changes of the
    // crop and effect sliders ("p", kept here).
    property var hist: []
    property var redoHist: []
    readonly property bool canUndo: hist.length > 0
    readonly property bool canRedo: redoHist.length > 0
    property bool loaded: false            // an audio buffer exists (it may be empty)
    property int suppress: 0
    property bool settling: false
    property var stableP: null
    property bool hasClip: false
    property bool reverseOn: false
    property bool compressOn: false
    property bool recording: false
    property real recSeconds: 0

    readonly property real speed: speedParam.value
    readonly property real pitch: pitchParam.value
    readonly property real gainDb: gainParam.value
    readonly property real fadeIn: fadeInParam.value
    readonly property real fadeOut: fadeOutParam.value
    readonly property real balance: balanceParam.value
    property bool loopOn: false
    readonly property real cropLen: Math.max(0.001, (endFrac - startFrac) * duration)
    readonly property real selInCropLen: hasSel ? Math.max(0, Math.min(selB, endFrac) - Math.max(selA, startFrac)) * duration : 0
    // track-wide effects, saved while a selection has effects of its own (null = no selection mode)
    property var globalFx: null
    readonly property real gSpeed: (hasSel && globalFx) ? globalFx.speed : 1
    onGlobalFxChanged: { wave.requestPaint(); liveTimer.start() }
    readonly property real resultLen: (hasSel ? (cropLen - selInCropLen + selInCropLen / speed) : cropLen / speed) / gSpeed
    readonly property bool previewing: progressMap["_preview"] !== undefined
    readonly property bool hasFile: duration > 0

    // crop + position the running preview was started with (the playhead lives in file coordinates)
    property real pvStart: 0
    property real pvEnd: 1
    property real pvOffset: 0
    property bool dragPlay: false
    property bool keepHead: false          // the preview was paused with Space: keep the playhead where it is
    onPreviewingChanged: {
        if (previewing) return
        if (keepHead) { keepHead = false; return }
        // The whole track played out while a part was selected meanwhile: now that part plays, once.
        if (playingFull && hasSel && !pvLoop && smoothPr >= 0.999) { playFrac = regStart; preview(0); return }
        playFrac = regStart
    }
    property string pendingOpen: ""        // file waiting for an answer to "save the changes?"
    property string afterSave: ""
    property bool clipHasFile: false       // a file was copied in a file manager
    readonly property bool dirty: hasFile && (canUndo || filePath === "" || effectsPending || compressOn || globalFx !== null
                                              || startFrac > 0.0005 || endFrac < 0.9995)
    property var recPeaks: []              // live levels while recording          // the playhead itself is being dragged

    // the part Preview plays: the selection (inside the crop) if there is one, otherwise the crop
    readonly property real regStart: hasSel ? Math.max(selA, startFrac) : startFrac
    readonly property real regEnd: hasSel ? Math.min(selB, endFrac) : endFrac
    // where the playhead is, as a fraction of the file (-1 = not placed yet)
    readonly property real headFrac: previewing ? playAbs() : playFrac

    onSpeedChanged: { wave.requestPaint(); liveTimer.start(); root.paramChanged() }
    onPitchChanged: { liveTimer.start(); root.paramChanged() }
    onGainDbChanged: { wave.requestPaint(); liveTimer.start(); root.paramChanged() }
    onFadeInChanged: { wave.requestPaint(); liveTimer.start(); root.paramChanged() }
    onBalanceChanged: { liveTimer.start(); root.paramChanged() }
    onFadeOutChanged: { wave.requestPaint(); liveTimer.start(); root.paramChanged() }
    onStartFracChanged: { wave.requestPaint(); liveTimer.start(); root.keepHeadInCrop(); root.paramChanged() }
    onEndFracChanged: { wave.requestPaint(); liveTimer.start(); root.keepHeadInCrop(); root.paramChanged() }
    onPeaksChanged: wave.requestPaint()
    onSelAChanged: { wave.requestPaint(); liveTimer.start() }
    onSelBChanged: { wave.requestPaint(); liveTimer.start() }
    onReverseOnChanged: { wave.requestPaint(); liveTimer.start(); root.paramChanged() }
    onCompressOnChanged: { wave.requestPaint(); liveTimer.start(); root.paramChanged() }
    onPaletteChanged: { wave.requestPaint(); repaintLater.restart() }
    // The accent color can arrive a moment after the window regains focus; repaint again then.
    Timer { id: repaintLater; interval: 250; onTriggered: wave.requestPaint() }
    Connections {
        target: root.Window.window
        function onActiveChanged() { repaintLater.restart() }
    }
    Connections {
        target: Application.styleHints
        function onColorSchemeChanged() { repaintLater.restart() }
    }

    // The playhead is driven by the wall clock (the preview's length is known exactly), so it
    // moves smoothly even in very short clips.
    property real smoothPr: 0
    property real pvT0: 0
    property real pvLen: 0
    Timer {
        interval: 8
        repeat: true
        running: root.previewing && root.pvLen > 0
        onTriggered: {
            // position in the rendered preview (0..1); a looping preview wraps round to the start
            var t = (pvOffset * root.pvLen) + (Date.now() - root.pvT0) / 1000
            root.smoothPr = root.pvLoop ? (t / root.pvLen) % 1 : Math.min(1, t / root.pvLen)
        }
    }
    property bool pvLoop: false
    function playAbs() {
        return pvStart + smoothPr * (pvEnd - pvStart)
    }
    // Settings changed while previewing: carry on from the same spot with the new settings.
    // If the playhead is outside the new crop, snap to the crop start.
    readonly property bool dragging: wmouse.mode === 1 || speedParam.pressed || pitchParam.pressed
                                     || gainParam.pressed || fadeInParam.pressed || fadeOutParam.pressed || balanceParam.pressed
    onDraggingChanged: {
        if (dragging) {
            if (settling) { settling = false; settleTimer.stop(); stableP = curParams() }
        } else {
            commitDrag()
            liveTimer.start()      // changes reach the sound when the mouse is released
        }
    }
    function liveUpdate() {
        if (!previewing || wmouse.mode === 1) return   // slider changes are heard at once; crop handles on release
        var pa = playAbs()
        // a track that is playing keeps playing as a whole when a part gets selected (no jump)
        var a = playingFull ? startFrac : regStart, b = playingFull ? endFrac : regEnd
        var o = (pa >= a && pa <= b) ? (pa - a) / Math.max(1e-6, b - a) : 0
        preview(o, playingFull)
    }
    // changes reach the running preview at most every 40 ms (start() does nothing while it runs, so a
    // moving slider is heard continuously instead of only after it stops)
    Timer { id: liveTimer; interval: 40; onTriggered: root.liveUpdate() }

    component Param: RowLayout {
        id: prm
        property string title
        property string valueText
        property alias from: sl.from
        property alias to: sl.to
        property alias value: sl.value
        property alias stepSize: sl.stepSize
        property alias pressed: sl.pressed
        Layout.fillWidth: true
        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: prm.title; Layout.preferredWidth: 110; opacity: prm.enabled ? 1 : 0.4 }
        EbSlider { id: sl; Layout.fillWidth: true }
        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: prm.valueText; Layout.preferredWidth: 80; horizontalAlignment: Text.AlignRight; opacity: prm.enabled ? 1 : 0.4 }
    }

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }
    function fmt(t) {
        var m = Math.floor(t / 60), s = t - m * 60
        return m + ":" + (s < 10 ? "0" : "") + s.toFixed(2)
    }
    function isAudioFile(p) { return /\.(mp3|wav|flac|ogg|oga|opus|m4a|aac|mp4|mkv|webm|aif|aiff|caf)$/i.test(p) }

    function curParams() { return { start: startFrac, end: endFrac, fx: curFx(), g: globalFx, comp: compressOn } }
    function keepHeadInCrop() {
        if (playFrac >= 0 && (playFrac < startFrac - 1e-6 || playFrac > endFrac + 1e-6) && !previewing) playFrac = startFrac
    }
    function fxDiffer(a, b) {
        var k = ["speed", "pitch", "gainDb", "fadeIn", "fadeOut", "balance"]
        for (var i = 0; i < k.length; i++) if (a[k[i]] !== b[k[i]]) return true
        return a.reverse !== b.reverse
    }
    function paramsDiffer(a, b) {
        if (a.start !== b.start || a.end !== b.end || a.comp !== b.comp) return true
        if (fxDiffer(a.fx, b.fx)) return true
        var ag = a.g !== null && a.g !== undefined, bg = b.g !== null && b.g !== undefined
        if (ag !== bg) return true
        return ag ? fxDiffer(a.g, b.g) : false
    }
    // While the mouse button is down nothing is recorded; on release it only counts as an edit if
    // the crop / sliders ended up somewhere else than where they started.
    function commitDrag() {
        if (suppress > 0 || !stableP || !hasFile) return
        var now = curParams()
        if (paramsDiffer(stableP, now)) {
            hist = hist.concat([{ k: "p", p: stableP }])
            redoHist = []
        }
        stableP = now
    }
    function paramChanged() {
        if (suppress > 0 || !hasFile || recording) return
        if (dragging) return
        if (!settling) {
            hist = hist.concat([{ k: "p", p: stableP || curParams() }])
            redoHist = []
            settling = true
        }
        settleTimer.restart()
    }
    Timer { id: settleTimer; interval: 700; onTriggered: { root.settling = false; root.stableP = root.curParams() } }
    function quiet(fn) {
        suppress++
        try { fn() } finally { suppress-- }
        settling = false; settleTimer.stop()
        stableP = curParams()
    }
    function pushEdit() { hist = hist.concat([{ k: "e" }]); redoHist = [] }
    function restoreParams(p) {
        quiet(function () {
            startFrac = p.start; endFrac = p.end; compressOn = p.comp
            var has = p.g !== null && p.g !== undefined
            var glob = has ? p.g : p.fx
            if (hasSel) { globalFx = glob; setFx(has ? p.fx : noFx) }
            else { globalFx = null; setFx(glob) }
        })
    }
    function resetParams() {
        quiet(function () {
            startFrac = 0; endFrac = 1
            speedParam.value = 1; pitchParam.value = 0; gainParam.value = 0
            fadeInParam.value = 0; fadeOutParam.value = 0; balanceParam.value = 0
            reverseOn = false; compressOn = false
            globalFx = null
            selA = -1; selB = -1
        })
        hist = []; redoHist = []
    }
    function curFx() {
        return { speed: speed, pitch: pitch, gainDb: gainDb, fadeIn: fadeIn, fadeOut: fadeOut, balance: balance, reverse: reverseOn }
    }
    function setFx(o) {
        suppress++
        speedParam.value = o.speed; pitchParam.value = o.pitch; gainParam.value = o.gainDb
        fadeInParam.value = o.fadeIn; fadeOutParam.value = o.fadeOut; balanceParam.value = o.balance
        reverseOn = o.reverse
        suppress--
        stableP = curParams()
    }
    readonly property var noFx: ({ speed: 1, pitch: 0, gainDb: 0, fadeIn: 0, fadeOut: 0, balance: 0, reverse: false })
    // The sliders edit the track-wide effects, or (while a part is selected) that part's own effects.
    function beginSelFx() {
        if (globalFx !== null) return
        globalFx = curFx()
        setFx(noFx)
    }
    function endSelFx() {            // the selection is gone: its unbaked effects are dropped, the track's come back
        if (globalFx === null) return
        var g = globalFx
        globalFx = null
        setFx(g)
    }
    readonly property bool effectsPending: Math.abs(speed - 1) > 0.001 || Math.abs(pitch) > 0.001 || Math.abs(gainDb) > 0.001
                                           || fadeIn > 0.001 || fadeOut > 0.001 || Math.abs(balance) > 0.001 || reverseOn
    // The effects of a selected part become part of the audio before another part gets selected (or
    // the selection is dropped). The track-wide effects are not touched. `anchor` is a fraction in
    // the old coordinates that is carried over to the new ones (the length can change, e.g. Speed).
    function bakeSelFx(anchor) {
        if (!hasSel || !effectsPending || !hasFile) return anchor
        backend.editorStopPreview()
        var oldDur = duration
        var ra = Math.max(selA, startFrac)
        var rb = Math.min(selB, endFrac)
        var d = JSON.parse(backend.editorApplyFx(paramsJson()))
        if (d.error) { setStatus(d.error, true); return anchor }
        var regNew = (rb - ra) * oldDur + (d.duration - oldDur)
        function mapOld(f) {
            if (f < 0) return f
            var t = f * oldDur, a = ra * oldDur, b = rb * oldDur
            var nt = t <= a ? t : (t >= b ? t + (d.duration - oldDur) : a + (t - a) / Math.max(1e-6, b - a) * regNew)
            return Math.max(0, Math.min(1, nt / Math.max(1e-6, d.duration)))
        }
        var mappedAnchor = mapOld(anchor), mappedHead = mapOld(playFrac)
        setFx(noFx)
        pushEdit()
        applyState(d, true)
        selA = -1; selB = -1
        playFrac = mappedHead
        return mappedAnchor
    }
    // Reset: back to the file as it is on disk (or, for a recording, all the way back through the undo history)
    function fullReset() {
        if (!backend || !hasFile || recording) return
        backend.editorStopPreview()
        if (filePath !== "") { load(filePath); playFrac = startFrac; return }
        var edits = 0
        for (var h = 0; h < hist.length; h++) if (hist[h].k === "e") edits++
        var guard = 0
        while (edits-- > 0 && guard++ < 200) {
            var d = JSON.parse(backend.editorEdit("undo", 0, 0, 0, startFrac, endFrac))
            if (d.error) break
            applyState(d, false)
        }
        resetParams()
        playFrac = startFrac        // the playhead stays visible, back at 0.0 s
        setStatus("", false)
    }
    function setStatus(t, err) { status = t; statusError = err }

    // takes the editor state from the backend (peaks, duration, undo state, crop)
    function applyState(d, keepSel) {
        peaks = d.peaks
        duration = d.duration
        filePath = d.path
        fileName = d.name
        hasClip = d.hasClip
        loaded = d.loaded
        suppress++
        startFrac = d.start; endFrac = d.end
        suppress--
        if (!keepSel) { endSelFx(); selA = -1; selB = -1; playFrac = -1 }
        stableP = curParams()
        wave.requestPaint()
    }
    function paramsJson() {
        var g = (hasSel && globalFx) ? globalFx : curFx()
        var o = { start: startFrac, end: endFrac, speed: g.speed, gainDb: g.gainDb, fadeIn: g.fadeIn, fadeOut: g.fadeOut, balance: g.balance,
                  pitch: g.pitch, reverse: g.reverse, compress: compressOn }
        if (hasSel) {
            var f = curFx()
            o.sel = { a: selA, b: selB, speed: f.speed, gainDb: f.gainDb, fadeIn: f.fadeIn, fadeOut: f.fadeOut, balance: f.balance,
                      pitch: f.pitch, reverse: f.reverse, compress: false }
        }
        return JSON.stringify(o)
    }

    // opens a file; asks first when the current audio has changes that would be lost
    function requestOpen(path) {
        if (!path || !backend) return
        if (!dirty) { load(path); return }
        backend.editorStopPreview()
        pendingOpen = path
        leavePopup.open()
    }
    function load(path) {
        if (!backend || path === "") return
        backend.editorStopPreview()
        var d = JSON.parse(backend.editorLoad(path))
        if (d.error) { setStatus(d.error, true); return }
        resetParams()
        applyState(d, false)
        playFrac = startFrac        // show the playhead at 0.0 s
        var m = /\.([^.]+)$/.exec(path)
        var idx = m ? formatExts.indexOf(m[1].toLowerCase()) : -1
        formatBox.currentIndex = idx >= 0 ? idx : 0
        setStatus("", false)
    }

    onVisibleChanged: {
        if (!visible && backend) {
            backend.editorStopPreview()
            if (recording) toggleRecording()
        }
    }

    // empties the editor (right-click on the path box)
    function clearFile() {
        if (!backend) return
        backend.editorStopPreview()
        if (recording) { backend.editorRecordDiscard(); recording = false }
        resetParams()
        applyState(JSON.parse(backend.editorNew()), false)
        setStatus("", false)
    }

    // ---- structural edits: delete / cut / copy / paste / pause / undo / redo
    function applyEdit(op, a, b, arg) {
        if (!backend || recording) return
        backend.editorStopPreview()
        var d = JSON.parse(backend.editorEdit(op, a, b, arg, startFrac, endFrac))
        if (d.error) { setStatus(d.error, true); return }
        if (op !== "copy" && hasFile) pushEdit()
        applyState(d, op === "copy")
        setStatus(op === "copy" ? qsTr("Copied") : "", false)
    }
    function doDelete() { if (hasSel) applyEdit("delete", selA, selB, 0) }
    function doCut() { if (hasSel) { backend.clearClipboard(); applyEdit("cut", selA, selB, 0) } }
    function doCopy() { if (hasSel) { backend.clearClipboard(); applyEdit("copy", selA, selB, 0) } }
    function selectAll() {
        if (!hasFile || recording) return
        if (hasSel) bakeSelFx(0)
        beginSelFx()
        selA = startFrac; selB = endFrac      // everything that is left after cropping, not the cut-away parts
    }
    // a file copied in a file manager opens in the editor; otherwise the copied part is pasted
    function doPaste(at) {
        var f = backend.clipboardFile()
        if (f !== "" && isAudioFile(f)) { requestOpen(f); return }
        if (!hasClip) return
        applyEdit("paste", at === undefined ? (playFrac >= 0 ? playFrac : 1.0) : at, 0, 0)
    }
    function doUndo() {
        if (!backend || recording || hist.length === 0) return
        backend.editorStopPreview()
        settling = false; settleTimer.stop()
        var e = hist[hist.length - 1]
        hist = hist.slice(0, hist.length - 1)
        if (e.k === "p") {
            redoHist = redoHist.concat([{ k: "p", p: curParams() }])
            restoreParams(e.p)
        } else {
            var d = JSON.parse(backend.editorEdit("undo", 0, 0, 0, startFrac, endFrac))
            if (d.error) { setStatus(d.error, true); return }
            redoHist = redoHist.concat([{ k: "e" }])
            applyState(d, false)
        }
        setStatus("", false)
    }
    function doRedo() {
        if (!backend || recording || redoHist.length === 0) return
        backend.editorStopPreview()
        settling = false; settleTimer.stop()
        var e = redoHist[redoHist.length - 1]
        redoHist = redoHist.slice(0, redoHist.length - 1)
        if (e.k === "p") {
            hist = hist.concat([{ k: "p", p: curParams() }])
            restoreParams(e.p)
        } else {
            var d = JSON.parse(backend.editorEdit("redo", 0, 0, 0, startFrac, endFrac))
            if (d.error) { setStatus(d.error, true); return }
            hist = hist.concat([{ k: "e" }])
            applyState(d, false)
        }
        setStatus("", false)
    }

    // ---- recording from the microphone chosen in Settings
    function toggleRecording() {
        if (!backend) return
        if (!recording) {
            backend.editorStopPreview()
            recording = true; recSeconds = 0
            var err = backend.editorRecordStart()
            if (err !== "") { recording = false; setStatus(err, true); return }
            setStatus("", false)
        } else {
            recording = false
            recPeaks = []
            recSeconds = 0
            var d = JSON.parse(backend.editorRecordStop(playFrac >= 0 ? playFrac : 1.0, startFrac, endFrac))
            if (d.error) { setStatus(d.error, true); return }
            if (hasFile) pushEdit()
            applyState(d, false)
            if (!/\.[^./\\]+$/.test(filePath)) formatBox.currentIndex = 0
        }
    }
    Timer {
        interval: 100
        repeat: true
        running: root.recording
        onTriggered: {
            var i = JSON.parse(root.backend.editorRecordInfo())
            root.recSeconds = i.seconds
            root.recPeaks = i.peaks || []
            wave.requestPaint()
            if (i.error !== "" || !i.recording) {
                if (i.error !== "") root.setStatus(i.error, true)
                if (i.recording) root.toggleRecording(); else root.recording = false
            }
        }
    }

    function offsetFromPlayhead() {
        if (playFrac < regStart || playFrac >= regEnd) return 0
        return (playFrac - regStart) / Math.max(1e-6, regEnd - regStart)
    }
    // Space: pause (remember where) / play (continue from there)
    function togglePlay() {
        if (!hasFile || recording) return
        if (previewing) {
            playFrac = playAbs()
            keepHead = true
            backend.editorStopPreview()
        } else preview()
    }
    // forget the selection (its own unbaked effects are baked first, the track's come back)
    function dropSelection() {
        if (hasSel) bakeSelFx(0)
        endSelFx()
        selA = -1; selB = -1
    }
    function cropToSelection() {
        if (!hasSel) return
        var a = Math.max(selA, startFrac), b = Math.min(selB, endFrac)
        if (b - a < 0.002) return
        startFrac = a; endFrac = b      // first, so any effects on the selection are baked with the new crop
        dropSelection()
    }
    function startAtPlayhead() {
        if (headFrac < 0) return
        dropSelection()
        startFrac = Math.min(headFrac, endFrac - 0.002)
    }
    function endAtPlayhead() {
        if (headFrac < 0) return
        dropSelection()
        endFrac = Math.max(headFrac, startFrac + 0.002)
    }
    // a click on the waveform: move the playback position (and carry on playing from there)
    function setPlayhead(f) {
        playFrac = f
        if (previewing) preview(offsetFromPlayhead())
    }

    property bool playingFull: false       // the running preview is the whole crop (not just a selection)
    function preview(offset, forceWhole) {
        var whole = forceWhole === true || !hasSel
        var o = offset === undefined ? offsetFromPlayhead() : offset
        wmouse.headMoved = false
        var err = backend.editorPreview(paramsJson(), o, loopOn, whole)
        if (err === "") {
            pvStart = whole ? startFrac : regStart; pvEnd = whole ? endFrac : regEnd; pvOffset = o; pvLoop = loopOn; playingFull = whole
            pvLen = backend.editorPreviewLen(); pvT0 = Date.now(); smoothPr = o
        }
        setStatus(err, err !== "")
    }
    readonly property var formatLabels: ["WAV", "MP3", "OGG", "FLAC", "Opus", "M4A"]
    readonly property var formatExts: ["wav", "mp3", "ogg", "flac", "opus", "m4a"]

    // "dest" empty = overwrite the original; otherwise save a copy there.
    function save(dest) {
        if (dest === "" && filePath === "") { askCopy(); return false }   // nothing to overwrite yet
        var r = backend.editorSave(paramsJson(), dest, formatExts[formatBox.currentIndex])
        if (r.indexOf("ok:") === 0) {
            setStatus(qsTr("Saved: %1").arg(r.substring(3)), false)
            if (dest === "") load(r.substring(3))
            return true
        }
        setStatus(r, true)
        return false
    }
    function extOf(p) { var m = /\.([^.\/\\]+)$/.exec(p); return m ? m[1].toLowerCase() : "" }
    // "Save" with another format selected changes the file's format: ask first
    function trySave() {
        if (filePath !== "" && extOf(filePath) !== formatExts[formatBox.currentIndex]) formatPopup.open()
        else save("")
    }
    function samePath(a, b) { return a.replace(/\\/g, "/") === b.replace(/\\/g, "/") }
    // Where "Save as Copy" starts: next to the original, but never inside the app's sounds folder
    // (that folder is managed by the Sound library); recordings start in the Music folder.
    function defaultCopyPath() {
        var ext = formatExts[formatBox.currentIndex]
        var inLibrary = false
        if (filePath !== "") {
            var lib = JSON.parse(backend.librarySounds())
            for (var i = 0; i < lib.length; i++) if (samePath(lib[i].path, filePath)) inLibrary = true
        }
        if (filePath !== "" && !inLibrary)
            return filePath.replace(/\.[^./\\]+$/, "") + "-easyboard." + ext
        var name = fileName !== "" ? fileName.replace(/\.[^.]+$/, "") : qsTr("recording")
        var dir = backend.urlToPath(StandardPaths.writableLocation(StandardPaths.MusicLocation).toString())
        return dir + "/" + name + (filePath !== "" ? "-easyboard" : "") + "." + ext
    }
    function askCopy() {
        var ext = formatExts[formatBox.currentIndex]
        copyDialog.title = filePath === "" ? qsTr("Save audio") : qsTr("Save as copy")
        copyDialog.nameFilters = [formatLabels[formatBox.currentIndex] + " (*." + ext + ")", qsTr("All files (*)")]
        copyDialog.defaultSuffix = ext
        var p = defaultCopyPath().replace(/\\/g, "/")
        copyDialog.currentFile = "file://" + (p.charAt(0) === "/" ? p : "/" + p)
        copyDialog.openDialog()
    }

    EbFileDialog {
        backend: root.backend
        id: fileDialog
        title: qsTr("Choose an audio file")
        nameFilters: [qsTr("Audio files (*.mp3 *.wav *.flac *.ogg *.oga *.opus *.m4a *.aac *.mp4 *.mkv *.webm *.aif *.aiff *.caf)"),
                      qsTr("All files (*)")]
        onAccepted: root.load(backend.urlToPath(selectedFile.toString()))
    }

    EbFileDialog {
        backend: root.backend
        id: copyDialog
        title: qsTr("Save as copy")
        fileMode: FileDialog.SaveFile
        onAccepted: {
            var ok = root.save(backend.urlToPath(selectedFile.toString()))
            var next = root.afterSave
            root.afterSave = ""
            if (ok && next !== "") root.load(next)
        }
        onRejected: root.afterSave = ""
    }

    Popup {
        id: formatPopup
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        focus: true
        width: 480
        padding: 22
        closePolicy: Popup.CloseOnEscape
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.5) }
        enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 } }
        background: Rectangle {
            radius: 18
            color: Window.window && Window.window.popupFill ? Window.window.popupFill(Qt.tint(Window.window.opaqueWindow, root.ink(0.05))) : Qt.tint(palette.window, root.ink(0.05))
            border.width: 1
            border.color: root.ink(0.16)
        }
        contentItem: ColumnLayout {
            spacing: 14
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Change the format?"); font.pixelSize: 20; font.weight: Font.DemiBold }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.7
                text: qsTr("Saving will change this file to %1. Every sound that uses it will be updated to use the new file.").arg(root.formatLabels[formatBox.currentIndex])
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 8
                EbButton { text: qsTr("Cancel"); onClicked: formatPopup.close() }
                Item { Layout.fillWidth: true }
                EbButton { text: qsTr("Save as Copy"); onClicked: { formatPopup.close(); root.askCopy() } }
                EbButton { text: qsTr("Proceed"); accent: true; onClicked: { formatPopup.close(); root.save("") } }
            }
        }
    }

    // "Save the changes?" when another file is opened over unsaved work
    Popup {
        id: leavePopup
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        focus: true
        width: 480
        padding: 22
        closePolicy: Popup.CloseOnEscape
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.5) }
        enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 } }
        background: Rectangle {
            radius: 18
            color: Window.window && Window.window.popupFill ? Window.window.popupFill(Qt.tint(Window.window.opaqueWindow, root.ink(0.05))) : Qt.tint(palette.window, root.ink(0.05))
            border.width: 1
            border.color: root.ink(0.16)
        }
        contentItem: ColumnLayout {
            spacing: 14
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Save your changes?"); font.pixelSize: 20; font.weight: Font.DemiBold }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.7
                text: qsTr("The sound you are editing has changes that have not been saved.")
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 8
                EbButton { text: qsTr("Cancel"); onClicked: leavePopup.close() }
                Item { Layout.fillWidth: true }
                EbButton {
                    text: qsTr("Discard")
                    danger: true
                    onClicked: { leavePopup.close(); root.load(root.pendingOpen) }
                }
                EbButton {
                    visible: root.filePath !== ""
                    text: qsTr("Save as Copy")
                    onClicked: { leavePopup.close(); root.afterSave = root.pendingOpen; root.askCopy() }
                }
                EbButton {
                    text: qsTr("Save")
                    accent: true
                    onClicked: {
                        leavePopup.close()
                        if (root.filePath === "") { root.afterSave = root.pendingOpen; root.askCopy() }
                        else if (root.save("")) root.load(root.pendingOpen)
                    }
                }
            }
        }
    }

    // ---- keyboard: Delete / Backspace remove the selection, Ctrl+Z / Ctrl+Y, Ctrl+C / X / V
    readonly property bool keysActive: visible && !pausePopup.opened && !leavePopup.opened
    // a text field has the keyboard: Ctrl+A / C / X / V / Z, Delete and Space belong to it
    readonly property bool typing: !!Window.activeFocusItem && Window.activeFocusItem.cursorPosition !== undefined
    readonly property bool editKeys: keysActive && !typing
    Shortcut {
        enabled: root.keysActive && root.hasSel && !ctxMenu.opened && !selectBtn.menuOpen
        sequences: ["Escape"]
        onActivated: root.dropSelection()
    }
    Shortcut { enabled: root.editKeys; sequences: ["Space"]; onActivated: root.togglePlay() }
    Shortcut { enabled: root.editKeys; sequences: [StandardKey.Undo]; onActivated: root.doUndo() }
    Shortcut { enabled: root.editKeys; sequences: [StandardKey.Redo, "Ctrl+Y"]; onActivated: root.doRedo() }
    Shortcut { enabled: root.editKeys; sequences: [StandardKey.Delete, "Backspace"]; onActivated: root.doDelete() }
    Shortcut { enabled: root.editKeys; sequences: [StandardKey.Copy]; onActivated: root.doCopy() }
    Shortcut { enabled: root.editKeys; sequences: [StandardKey.Cut]; onActivated: root.doCut() }
    Shortcut { enabled: root.editKeys; sequences: [StandardKey.SelectAll]; onActivated: root.selectAll() }
    Shortcut { enabled: root.editKeys; sequences: [StandardKey.Paste]; onActivated: root.doPaste() }

    // ---- "Add pause": silence of N milliseconds at the spot that was right-clicked
    Popup {
        id: pausePopup
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        focus: true
        width: 340
        padding: 22
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.5) }
        enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 } }
        onOpened: { pauseField.text = "500"; pauseField.forceActiveFocus(); pauseField.selectAll() }
        background: Rectangle {
            radius: 18
            color: Window.window && Window.window.popupFill ? Window.window.popupFill(Qt.tint(Window.window.opaqueWindow, root.ink(0.05))) : Qt.tint(palette.window, root.ink(0.05))
            border.width: 1
            border.color: root.ink(0.16)
        }
        function commit() {
            var ms = parseInt(pauseField.text)
            if (!(ms > 0)) return
            pausePopup.close()
            root.applyEdit("silence", root.ctxFrac, 0, ms)
        }
        contentItem: ColumnLayout {
            spacing: 14
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Add silence"); font.pixelSize: 20; font.weight: Font.DemiBold }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.7
                text: qsTr("How long should the silence be, in milliseconds?")
            }
            EbField {
                id: pauseField
                Layout.fillWidth: true
                placeholderText: qsTr("Milliseconds")
                inputMethodHints: Qt.ImhDigitsOnly
                validator: IntValidator { bottom: 1; top: 600000 }
                onAccepted: pausePopup.commit()
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 8
                Item { Layout.fillWidth: true }
                EbButton { text: qsTr("Cancel"); onClicked: pausePopup.close() }
                EbButton { text: qsTr("Add"); accent: true; onClicked: pausePopup.commit() }
            }
        }
    }

    // Drop an audio file anywhere on the page
    DropArea {
        id: pageDrop
        anchors.fill: parent
        onEntered: function (drag) {
            var ok = false
            if (drag.hasUrls && drag.urls.length === 1)
                for (var i = 0; i < drag.urls.length; i++)
                    if (root.isAudioFile(root.backend.urlToPath(drag.urls[i].toString()))) ok = true
            drag.accepted = ok
        }
        onDropped: function (drop) {
            if (!drop.hasUrls || drop.urls.length !== 1) return
            for (var i = 0; i < drop.urls.length; i++) {
                var f = root.backend.urlToPath(drop.urls[i].toString())
                if (root.isAudioFile(f)) { root.requestOpen(f); break }
            }
        }
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: 8
        visible: pageDrop.containsDrag
        z: 20
        radius: 16
        color: Qt.rgba(palette.highlight.r, palette.highlight.g, palette.highlight.b, 0.12)
        border.width: 3
        border.color: palette.highlight
        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; anchors.centerIn: parent; text: qsTr("Drop an audio file to edit it"); font.pixelSize: 20 }
    }

    EbWheel { anchors.fill: parent; flick: scroll }

    Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        interactive: false          // wheel + scroll bar only, no click-and-drag scrolling
        boundsBehavior: Flickable.StopAtBounds
        boundsMovement: Flickable.StopAtBounds
        rebound: Transition { NumberAnimation { properties: "x,y"; duration: 0 } }
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: EbScrollBar {}

        // a theme's <depth shadow> under the whole waveform box: next to it, because the box clips its contents
        Shadow {
            anchors.fill: undefined
            x: col.x + waveBox.x
            y: col.y + waveBox.y
            width: waveBox.width
            height: waveBox.height
            radius: waveBox.radius
        }
        ColumnLayout {
            id: col
            // at most 920 px from the left, unless the theme says otherwise (<layout pageWidth pageAlign>)
            width: Window.window && Window.window.pageWidth ? Window.window.pageWidth(scroll.width - 64) : Math.min(scroll.width - 64, 920)
            x: 32 + (Window.window && Window.window.pageOffset ? Window.window.pageOffset(scroll.width - 64, width) : 0)
            spacing: 14

            Item { Layout.preferredHeight: 14 }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Sound editor"); font.pixelSize: 30; font.weight: Font.Light }

            // undo / redo, then the file box with "Select File" inside
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
            EbButton {
                implicitWidth: 48
                implicitHeight: 44
                Image {
                    anchors.centerIn: parent
                    width: 20; height: 20
                    sourceSize: Qt.size(48, 48)
                    opacity: parent.enabled ? 1 : 0.3
                    source: Window.window ? Window.window.iconFor("undo", palette.windowText) : ""
                    fillMode: Image.PreserveAspectFit
                }
                enabled: root.canUndo && !root.recording
                onClicked: root.doUndo()
                ToolTip.visible: hovered && enabled; ToolTip.delay: 500; ToolTip.text: qsTr("Undo (Ctrl+Z)")
            }
            EbButton {
                implicitWidth: 48
                implicitHeight: 44
                Image {
                    anchors.centerIn: parent
                    width: 20; height: 20
                    sourceSize: Qt.size(48, 48)
                    opacity: parent.enabled ? 1 : 0.3
                    source: Window.window ? Window.window.iconFor("redo", palette.windowText) : ""
                    fillMode: Image.PreserveAspectFit
                }
                enabled: root.canRedo && !root.recording
                onClicked: root.doRedo()
                ToolTip.visible: hovered && enabled; ToolTip.delay: 500; ToolTip.text: qsTr("Redo (Ctrl+Y)")
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                radius: 10
                color: Window.window && Window.window.solid ? Window.window.solid(((Window.window && Window.window.tintOn) ? Window.window.tintFill(0) : root.ink(0.06))) : root.ink(0.06)
                border.width: 1
                border.color: root.ink(0.14)
                // button that clears the chosen file (a backspace key)
                EbButton {
                    id: clearBtn
                    visible: root.filePath !== "" || root.hasFile
                    anchors.right: selectBtn.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: 34
                    implicitHeight: 34
                    leftPadding: 0; rightPadding: 0
                    onClicked: root.clearFile()
                    Image {
                        anchors.centerIn: parent
                        width: 18; height: 18
                        sourceSize: Qt.size(36, 36)
                        source: Window.window ? Window.window.iconFor("backspace", palette.windowText) : ""
                        fillMode: Image.PreserveAspectFit
                    }
                    ToolTip.visible: hovered && enabled; ToolTip.delay: 500; ToolTip.text: qsTr("Clear")
                }
                Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.right: clearBtn.visible ? clearBtn.left : selectBtn.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.filePath !== "" ? selectBtn.shownPath(root.filePath)
                        : root.hasFile ? qsTr("Unsaved audio") : qsTr("Drop an audio file here, or select one")
                    elide: Text.ElideLeft
                    font.pixelSize: 14
                    color: palette.windowText
                    opacity: (root.filePath !== "" || root.hasFile) ? 1 : 0.4
                }
                EbAudioPicker {
                    id: selectBtn
                    backend: root.backend
                    anchors.right: parent.right
                    anchors.rightMargin: 5
                    anchors.verticalCenter: parent.verticalCenter
                    implicitHeight: 34
                    onPicked: function (p) { root.requestOpen(p) }
                    onCustomRequested: fileDialog.openDialog()
                }
            }

            }

            // playhead time, floating above the waveform and following the playhead
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 14
                Layout.topMargin: -2
                Layout.bottomMargin: -8
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    visible: root.headFrac >= 0 && !root.recording
                    text: root.fmt(root.headFrac * root.duration)
                    font.pixelSize: 12
                    opacity: 0.8
                    y: parent.height - height
                    x: Math.max(0, Math.min(parent.width - width, waveBox.pad + root.headFrac * waveBox.trackW - width / 2))
                }
            }

            // ---- live waveform with crop handles
            Rectangle {
                id: waveBox
                // with shadowed crop handles, the contents are cut to the rounded corners (a plain clip is
                // square, and the handles' shadow showed in the corners)
                layer.enabled: !!(Window.window && Window.window.themed && Window.window.theme.depth.waveShadow > 0)
                layer.effect: MultiEffect { maskEnabled: true; maskSource: waveMask }
                Item {
                    id: waveMask
                    anchors.fill: parent
                    visible: false
                    layer.enabled: true
                    Rectangle { anchors.fill: parent; radius: waveBox.radius; color: "black" }
                }
                Layout.fillWidth: true
                Layout.preferredHeight: 200
                radius: 12
                color: Window.window && Window.window.solid ? Window.window.solid(((Window.window && Window.window.tintOn) ? Window.window.tintFill(0) : root.ink(0.06))) : root.ink(0.06)
                border.width: 1
                border.color: root.ink(0.14)
                clip: true

                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    anchors.centerIn: parent
                    visible: !root.loaded && !root.recording
                    text: qsTr("No audio yet. Open or drop a file, record, or paste.")
                    opacity: 0.4
                }

                readonly property real pad: 16                       // room for the bars at both ends
                readonly property real trackW: Math.max(1, width - 2 * pad)

                Canvas {
                    id: wave
                    // a theme's <depth waveShadow>: a clear drop shadow under the waveform lines, so light
                    // lines stay readable on a light background (drawn by the GPU, not by the Canvas)
                    readonly property real shadowStrength: Window.window && Window.window.themed ? Window.window.theme.depth.waveShadow : 0
                    layer.enabled: shadowStrength > 0
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: "black"
                        shadowOpacity: wave.shadowStrength
                        shadowBlur: 0.35
                        shadowVerticalOffset: 2
                        shadowHorizontalOffset: 0
                    }
                    anchors.fill: parent
                    anchors.topMargin: 1
                    anchors.bottomMargin: 1
                    anchors.leftMargin: waveBox.pad
                    anchors.rightMargin: waveBox.pad
                    property color hl: palette.highlight
                    property color ink: palette.windowText
                    onHlChanged: requestPaint()
                    onPaletteChanged: requestPaint()
                    onInkChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        if (root.recording) {
                            // live view: starts at the left and grows to the right (then scrolls)
                            var rp = root.recPeaks || []
                            var slots = 300, sw = width / slots
                            ctx.fillStyle = "#e5484d"
                            for (var j = 0; j < rp.length; j++) {
                                var ah = Math.max(1, Math.min(1, rp[j] * 1.0) * (height / 2 - 8))
                                ctx.fillRect(j * sw, height / 2 - ah, Math.max(1, sw - 0.5), ah * 2)
                            }
                            return
                        }
                        var p = root.peaks
                        if (!p || p.length === 0) return
                        var w = width, h = height, mid = h / 2, n = p.length
                        var c = palette.windowText
                        var normal = palette.highlight
                        var bw = w / n
                        var s = root.startFrac, e = root.endFrac
                        // two layers, like the real thing: the selection's own effects first, then the
                        // track-wide ones (reverse, compressor, volume, fades) over the whole crop
                        var G = (root.hasSel && root.globalFx) ? root.globalFx : root.curFx()
                        var S = root.hasSel ? root.curFx() : null
                        var ra = root.hasSel ? Math.max(root.selA, s) : 0
                        var rb = root.hasSel ? Math.min(root.selB, e) : 0
                        var sg = S ? Math.pow(10, S.gainDb / 20) : 1
                        var gg = Math.pow(10, G.gainDb / 20)
                        var selLen = Math.max(1e-6, (rb - ra) * root.duration / (S ? S.speed : 1))
                        var cropLenS = Math.max(1e-6, (e - s) * root.duration / G.speed)
                        var thr = 0.125
                        function squeeze(a) { return a > thr ? thr * Math.pow(a / thr, 0.25) : a }
                        function selLayer(tt) {     // amplitude at file position tt after the selection's effects
                            var amp = p[Math.max(0, Math.min(n - 1, Math.floor(tt * n)))]
                            if (S && tt >= ra && tt <= rb) {
                                if (S.reverse) amp = p[Math.max(0, Math.min(n - 1, Math.floor((ra + rb - tt) * n)))]
                                var pos = (tt - ra) / Math.max(1e-6, rb - ra) * selLen
                                var env = 1
                                if (S.fadeIn > 0) env = Math.min(env, pos / S.fadeIn)
                                if (S.fadeOut > 0) env = Math.min(env, (selLen - pos) / S.fadeOut)
                                amp = amp * sg * Math.max(0, env)
                            }
                            return amp
                        }
                        var nm = 1
                        if (root.compressOn && e > s) {
                            var pk = 0
                            for (var k = Math.floor(s * n); k < Math.ceil(e * n) && k < n; k++) pk = Math.max(pk, selLayer((k + 0.5) / n))
                            if (pk > 0.0001) nm = 0.97 / squeeze(pk)
                        }
                        for (var i = 0; i < n; i++) {
                            var t = (i + 0.5) / n
                            var clipped = false
                            var amp
                            if (t >= s && t <= e) {
                                amp = selLayer(G.reverse ? (s + e - t) : t)
                                if (root.compressOn) amp = squeeze(amp) * nm
                                amp = amp * gg
                                var gpos = (t - s) / Math.max(1e-6, e - s) * cropLenS
                                var genv = 1
                                if (G.fadeIn > 0) genv = Math.min(genv, gpos / G.fadeIn)
                                if (G.fadeOut > 0) genv = Math.min(genv, (cropLenS - gpos) / G.fadeOut)
                                amp = amp * Math.max(0, genv)
                            } else amp = selLayer(t)
                            if (amp > 1.0001) { amp = 1; clipped = true }
                            ctx.fillStyle = clipped ? "#e5484d" : normal
                            var a = Math.max(1, amp * (h / 2 - 8))
                            ctx.fillRect(i * bw, mid - a, Math.max(1, bw - 0.5), a * 2)
                        }
                    }
                }

                // dimmed cropped-away parts: rounded to match the box on the outer corners
                Canvas {
                    id: dimCanvas
                    anchors.fill: parent
                    anchors.margins: 1
                    visible: root.hasFile && !root.recording
                    property real sx: waveBox.pad + root.startFrac * waveBox.trackW - 1
                    property real ex: waveBox.pad + root.endFrac * waveBox.trackW - 1
                    onSxChanged: requestPaint()
                    onExChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    onVisibleChanged: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        var r = waveBox.radius - 1, w = width, h = height
                        ctx.fillStyle = "rgba(0,0,0,0.5)"
                        if (sx > 0) {
                            var x = Math.min(sx, w), rr = Math.min(r, x / 2, h / 2)
                            ctx.beginPath()
                            ctx.moveTo(rr, 0); ctx.lineTo(x, 0); ctx.lineTo(x, h); ctx.lineTo(rr, h)
                            ctx.arcTo(0, h, 0, h - rr, rr); ctx.lineTo(0, rr); ctx.arcTo(0, 0, rr, 0, rr)
                            ctx.closePath(); ctx.fill()
                        }
                        if (ex < w) {
                            var x0 = Math.max(ex, 0), rr2 = Math.min(r, (w - x0) / 2, h / 2)
                            ctx.beginPath()
                            ctx.moveTo(x0, 0); ctx.lineTo(w - rr2, 0)
                            ctx.arcTo(w, 0, w, rr2, rr2); ctx.lineTo(w, h - rr2); ctx.arcTo(w, h, w - rr2, h, rr2)
                            ctx.lineTo(x0, h); ctx.closePath(); ctx.fill()
                        }
                    }
                }

                // selection
                Rectangle {
                    visible: root.hasSel && !root.recording
                    x: waveBox.pad + root.selA * waveBox.trackW
                    width: Math.max(1, (root.selB - root.selA) * waveBox.trackW)
                    height: parent.height
                    color: Qt.rgba(palette.highlight.r, palette.highlight.g, palette.highlight.b, 0.28)
                    border.width: 1
                    border.color: palette.highlight
                }

                // playback position set by clicking
                Rectangle {
                    visible: root.hasFile && !root.recording && !root.previewing && root.playFrac >= 0
                    x: waveBox.pad + root.playFrac * waveBox.trackW - 1
                    width: 2; height: parent.height
                    color: "white"
                    opacity: 0.8
                }

                // playhead
                Rectangle {
                    visible: root.previewing && !root.recording
                    x: waveBox.pad + root.playAbs() * waveBox.trackW
                    width: 2; height: parent.height
                    color: "white"
                }

                // crop handles: a wide bar (rounded on its outer side) with a slim grip carrying three ridges
                component Grip: Item {
                    id: grip
                    property real frac: 0
                    // with a theme's <depth waveShadow> the handles get a shadow too, so light handles
                    // still stand out on a light background
                    readonly property real shadowStrength: Window.window && Window.window.themed ? Window.window.theme.depth.waveShadow : 0
                    layer.enabled: shadowStrength > 0
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: "black"
                        shadowOpacity: grip.shadowStrength * 0.8
                        shadowBlur: 0.45
                        shadowVerticalOffset: 1
                        shadowHorizontalOffset: 0
                    }
                    property int side: 1          // 1 = start handle (round on the left), -1 = end handle
                    readonly property real barW: 16
                    visible: root.loaded && !root.recording
                    readonly property color gripColor: root.hasFile ? palette.highlight : Qt.darker(palette.highlight, 2.6)
                    width: barW
                    height: parent.height
                    x: side === 1 ? waveBox.pad + frac * waveBox.trackW - barW : waveBox.pad + frac * waveBox.trackW
                    Rectangle {
                        anchors.fill: parent
                        radius: 8
                        color: parent.gripColor
                    }
                    // square off the inner side
                    Rectangle {
                        width: parent.width / 2
                        height: parent.height
                        x: side === 1 ? parent.width / 2 : 0
                        color: parent.gripColor
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 10; height: 38; radius: 5
                        color: "transparent"
                        Row {
                            anchors.centerIn: parent
                            spacing: 2
                            Repeater {
                                model: 3
                                // the theme's glyph color (gray) when it has one
                                Rectangle { width: 1.5; height: 18; radius: 1; opacity: 1
                                            readonly property color ridge: Window.window && Window.window.glyphColor ? Window.window.glyphColor(palette.highlightedText) : palette.highlightedText
                                            color: root.hasFile ? ridge : Qt.darker(ridge, 1.5) }
                            }
                        }
                    }
                }
                Grip { frac: root.startFrac; side: 1 }
                Grip { frac: root.endFrac; side: -1 }

                // left: grab a crop handle, click = move the playback position, drag = select a part
                // right: edit menu
                MouseArea {
                    id: wmouse
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    preventStealing: true
                    hoverEnabled: true
                    cursorShape: (nearHandle(mouseX) || nearHead(mouseX)) ? Qt.SizeHorCursor : (root.hasFile ? Qt.IBeamCursor : Qt.ArrowCursor)
                    property int grab: 0            // 1 = start handle, 2 = end handle
                    property int mode: 0            // 0 idle, 1 handle, 2 selecting, 3 dragging the playhead
                    property real off: 0
                    property real anchorFrac: 0
                    property real pressX: 0
                    property bool moved: false
                    property bool headMoved: false  // the mouse moved the held playhead since the preview (re)started
                    property real lastJump: 0
                    readonly property real half: 8      // half the handle bar width
                    function startC() { return waveBox.pad + root.startFrac * waveBox.trackW - half }
                    function endC() { return waveBox.pad + root.endFrac * waveBox.trackW + half }
                    function toFrac(x) { return Math.max(0, Math.min(1, (x - waveBox.pad) / waveBox.trackW)) }
                    function inCrop(x) { return Math.max(root.startFrac, Math.min(root.endFrac, toFrac(x))) }
                    function nearHandle(x) {
                        if (!root.hasFile) return false
                        return Math.abs(x - startC()) <= half + 6 || Math.abs(x - endC()) <= half + 6
                    }
                    function nearHead(x) {
                        if (!root.hasFile || root.headFrac < 0 || root.previewing) return false   // not while playing
                        return Math.abs(x - (waveBox.pad + root.headFrac * waveBox.trackW)) <= 6
                    }
                    onPressed: function (m) {
                        if (m.button === Qt.RightButton) {
                            root.ctxFrac = root.hasFile ? toFrac(m.x) : 0
                            root.clipHasFile = root.backend.clipboardFile() !== ""
                            ctxMenu.x = Math.min(m.x, waveBox.width - ctxMenu.width - 4)
                            ctxMenu.y = Math.min(m.y, waveBox.height - 4)
                            ctxMenu.open()
                            return
                        }
                        if (!root.hasFile || root.recording) return
                        pressX = m.x
                        moved = false
                        if (nearHandle(m.x)) {
                            root.dropSelection()
                            mode = 1
                            var ds = Math.abs(m.x - startC()), de = Math.abs(m.x - endC())
                            var inS = ds <= half + 6, inE = de <= half + 6
                            if (inS && !inE) grab = 1
                            else if (inE && !inS) grab = 2
                            else if (Math.abs(ds - de) < 0.5) grab = m.x < startC() ? 1 : 2
                            else grab = ds < de ? 1 : 2
                            // grab anywhere on the bar without it jumping
                            off = m.x - (grab === 1 ? startC() : endC())
                            if (Math.abs(off) > half + 6) off = 0
                            move(m.x)
                        } else if (nearHead(m.x)) {
                            mode = 3
                            root.playFrac = root.headFrac
                            root.dragPlay = true
                            root.playFrac = inCrop(m.x)
                        } else if (toFrac(m.x) < root.startFrac || toFrac(m.x) > root.endFrac) {
                            // outside the crop: that side of the crop jumps to the mouse (and follows it)
                            root.dropSelection()
                            mode = 1
                            grab = toFrac(m.x) < root.startFrac ? 1 : 2
                            off = grab === 1 ? half : -half
                            move(m.x)
                        } else {
                            mode = 2
                            anchorFrac = toFrac(m.x)
                        }
                    }
                    onPositionChanged: function (m) {
                        if (!pressed) return
                        if (mode === 1) move(m.x)
                        else if (mode === 3) {
                            headMoved = true
                            root.playFrac = inCrop(m.x)
                            // while playing, the sound carries on from where the playhead was dropped
                            if (root.previewing && Date.now() - lastJump > 50) { lastJump = Date.now(); root.preview(root.offsetFromPlayhead()); headMoved = true }
                        }
                        else if (mode === 2) {
                            if (!moved && Math.abs(m.x - pressX) < 4) return
                            if (!moved) {
                                if (root.hasSel) anchorFrac = root.bakeSelFx(anchorFrac)
                                root.beginSelFx()
                            }
                            moved = true
                            var f = Math.max(root.startFrac, Math.min(root.endFrac, toFrac(m.x)))
                            root.selA = Math.min(anchorFrac, f)
                            root.selB = Math.max(anchorFrac, f)
                        }
                    }
                    onReleased: function (m) {
                        if (mode === 3) {
                            // only a real move changes anything: a plain release keeps the playhead where it is
                            if (headMoved) {
                                root.playFrac = inCrop(m.x)
                                if (root.previewing) root.preview(root.offsetFromPlayhead())
                            }
                            root.dragPlay = false
                        }
                        if (mode === 2) {
                            if (!moved) {
                                var head = root.bakeSelFx(toFrac(m.x))
                                root.endSelFx()
                                root.selA = -1; root.selB = -1; root.setPlayhead(head)
                            }
                            else if (root.selB - root.selA < 0.002) { root.selA = -1; root.selB = -1; root.endSelFx() }
                        }
                        mode = 0
                    }
                    function move(x) {
                        var gap = 0.002
                        var c = x - off
                        if (grab === 1) root.startFrac = Math.min(toFrac(c + half), root.endFrac - gap)
                        else root.endFrac = Math.max(toFrac(c - half), root.startFrac + gap)
                    }
                }

                // right-click menu
                Popup {
                    id: ctxMenu
                    focus: true
                    width: 190
                    padding: 6
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                    background: Rectangle {
                        radius: 12
                        color: Window.window && Window.window.popupFill ? Window.window.popupFill(Qt.tint(Window.window.opaqueWindow, root.ink(0.08))) : Qt.tint(palette.window, root.ink(0.08))
                        border.width: 1
                        border.color: root.ink(0.18)
                    }
                    component Entry: Rectangle {
                        id: entry
                        property alias text: lbl.text
                        property bool active: true
                        signal triggered()
                        Layout.fillWidth: true
                        implicitHeight: 34
                        radius: 8
                        color: entryMouse.containsMouse && active ? root.ink(0.12) : "transparent"
                        Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                            id: lbl
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            font.pixelSize: 14
                            color: palette.windowText
                            opacity: entry.active ? 1 : 0.4
                        }
                        MouseArea {
                            id: entryMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: entry.active
                            onClicked: { ctxMenu.close(); entry.triggered() }
                        }
                    }
                    contentItem: ColumnLayout {
                        spacing: 2
                        Entry { text: qsTr("Add silence"); onTriggered: pausePopup.open() }
                        Entry { text: qsTr("Start crop here"); active: root.hasFile; onTriggered: { root.dropSelection(); root.startFrac = Math.min(root.ctxFrac, root.endFrac - 0.002) } }
                        Entry { text: qsTr("End crop here"); active: root.hasFile; onTriggered: { root.dropSelection(); root.endFrac = Math.max(root.ctxFrac, root.startFrac + 0.002) } }
                        Entry { text: qsTr("Crop to selection"); active: root.hasSel; onTriggered: root.cropToSelection() }
                        Entry { text: qsTr("Clear selection"); active: root.hasSel; onTriggered: root.dropSelection() }
                        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.ink(0.12) }
                        Entry { text: qsTr("Cut"); active: root.hasSel; onTriggered: root.doCut() }
                        Entry { text: qsTr("Copy"); active: root.hasSel; onTriggered: root.doCopy() }
                        Entry { text: qsTr("Paste"); active: root.hasClip || root.clipHasFile; onTriggered: root.doPaste(root.ctxFrac) }
                        Entry { text: qsTr("Delete"); active: root.hasSel; onTriggered: root.doDelete() }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Start %1").arg(root.fmt(root.startFrac * root.duration)); opacity: 0.7 }
                Item { Layout.fillWidth: true }
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Result length %1").arg(root.fmt(root.resultLen)); opacity: 0.7 }
                Item { Layout.fillWidth: true }
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("End %1").arg(root.fmt(root.endFrac * root.duration)); opacity: 0.7 }
            }

            // record / reverse / compressor
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                EbButton {
                    accent: root.recording
                    text: root.recording ? qsTr("Stop  %1").arg(root.fmt(root.recSeconds)) : qsTr("Record")
                    onClicked: root.toggleRecording()
                    ToolTip.visible: hovered && enabled; ToolTip.delay: 500
                    ToolTip.text: root.recording ? qsTr("Stop recording") : qsTr("Record from your microphone")
                }
                EbButton {
                    text: qsTr("Reverse")
                    enabled: root.hasFile && !root.recording
                    accent: root.reverseOn
                    onClicked: root.reverseOn = !root.reverseOn
                    ToolTip.visible: hovered && enabled; ToolTip.delay: 500
                    ToolTip.text: root.hasSel ? qsTr("Play the selected part backwards") : qsTr("Play backwards")
                }
                EbButton {
                    text: qsTr("Compressor")
                    enabled: root.hasFile && !root.recording
                    accent: root.compressOn
                    onClicked: root.compressOn = !root.compressOn
                    ToolTip.visible: hovered && enabled; ToolTip.delay: 500
                    ToolTip.text: qsTr("Make the quiet parts louder and the loud parts quieter")
                }
                Item { Layout.fillWidth: true }
                EbButton {
                    implicitWidth: 44
                    implicitHeight: 44
                    leftPadding: 0; rightPadding: 0
                    Image {
                        anchors.centerIn: parent
                        width: 22; height: 22
                        sourceSize: Qt.size(52, 52)
                        opacity: parent.enabled ? 1 : 0.3
                        source: Window.window ? Window.window.iconFor("braceopen", palette.windowText) : ""
                        fillMode: Image.PreserveAspectFit
                    }
                    enabled: root.hasFile && !root.recording && root.headFrac >= 0
                    onClicked: root.startAtPlayhead()
                    ToolTip.visible: hovered && enabled; ToolTip.delay: 500; ToolTip.text: qsTr("Make the crop start where the playhead is")
                }
                EbButton {
                    implicitWidth: 44
                    implicitHeight: 44
                    leftPadding: 0; rightPadding: 0
                    Image {
                        anchors.centerIn: parent
                        width: 22; height: 22
                        sourceSize: Qt.size(52, 52)
                        opacity: parent.enabled ? 1 : 0.3
                        source: Window.window ? Window.window.iconFor("braceclose", palette.windowText) : ""
                        fillMode: Image.PreserveAspectFit
                    }
                    enabled: root.hasFile && !root.recording && root.headFrac >= 0
                    onClicked: root.endAtPlayhead()
                    ToolTip.visible: hovered && enabled; ToolTip.delay: 500; ToolTip.text: qsTr("Make the crop end where the playhead is")
                }
            }

            Param {
                id: speedParam
                enabled: root.hasFile && !root.recording
                title: qsTr("Speed")
                from: 0.25; to: 4; value: 1
                valueText: "×" + value.toFixed(2)
            }
            Param {
                id: pitchParam
                enabled: root.hasFile && !root.recording
                title: qsTr("Pitch")
                from: -12; to: 12; value: 0; stepSize: 1
                valueText: (value > 0 ? "+" : "") + Math.round(value) + " st"
            }
            Param {
                id: gainParam
                enabled: root.hasFile && !root.recording
                title: qsTr("Volume")
                from: -30; to: 20; value: 0; stepSize: 0.1
                // rounded to the shown precision first, so it never reads "-0.0" or "+0.0"
                valueText: { var r = Math.round(value * 10) / 10; return (r === 0 ? "0.0" : (r > 0 ? "+" : "") + r.toFixed(1)) + " dB" }
            }
            Param {
                id: balanceParam
                enabled: root.hasFile && !root.recording
                title: qsTr("Balance")
                from: -1; to: 1; value: 0; stepSize: 0.01
                valueText: { var r = Math.round(value * 100); return r === 0 ? qsTr("Center") : (r < 0 ? qsTr("L %1%").arg(-r) : qsTr("R %1%").arg(r)) }
            }
            Param {
                id: fadeInParam
                enabled: root.hasFile && !root.recording
                title: qsTr("Fade in")
                from: 0; to: Math.max(0.1, root.resultLen / 2); value: 0
                valueText: value.toFixed(2) + " s"
            }
            Param {
                id: fadeOutParam
                enabled: root.hasFile && !root.recording
                title: qsTr("Fade out")
                from: 0; to: Math.max(0.1, root.resultLen / 2); value: 0
                valueText: value.toFixed(2) + " s"
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: -4
                spacing: 8
                EbButton {
                    enabled: root.hasFile && !root.recording
                    accent: root.previewing
                    text: root.previewing ? qsTr("Stop") : qsTr("Preview")
                    onClicked: root.previewing ? root.togglePlay() : root.preview()   // Stop = pause at the playhead
                }
                EbButton { text: qsTr("Reset"); enabled: root.hasFile; onClicked: root.fullReset() }
                EbButton {
                    text: qsTr("Loop")
                    enabled: root.hasFile && !root.recording
                    accent: root.loopOn
                    onClicked: {
                        root.loopOn = !root.loopOn
                        if (root.previewing) root.liveUpdate()   // carry on from here, looping or not
                    }
                    ToolTip.visible: hovered && enabled; ToolTip.delay: 500; ToolTip.text: qsTr("Repeat the preview until you stop it")
                }
                Item { Layout.fillWidth: true }
                EbCombo {
                    id: formatBox
                    Layout.preferredWidth: 100
                    model: root.formatLabels
                    enabled: root.hasFile
                    ToolTip.visible: hovered && enabled
                    ToolTip.delay: 500
                    ToolTip.text: qsTr("Format")
                }
                EbButton { text: qsTr("Save as Copy"); enabled: root.hasFile && !root.recording && root.filePath !== ""; onClicked: root.askCopy() }
                EbButton { text: qsTr("Save"); accent: true; enabled: root.hasFile && !root.recording; onClicked: root.trySave() }
            }

            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                visible: root.status !== ""
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: root.status
                color: root.statusError ? "#e5484d" : palette.windowText
                opacity: root.statusError ? 1 : 0.7
            }

            // room under the last row: 16 px (2 + the column's 14 px spacing), so the whole editor fits the
            // smallest window without scrolling
            Item { Layout.preferredHeight: 2 }
        }
    }
}
