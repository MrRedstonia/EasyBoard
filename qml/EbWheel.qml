import QtQuick

// Browser-style smooth scrolling for a Flickable/GridView: every wheel notch moves a target
// position and the view glides towards it continuously (clamped, no overshoot).
// Place it next to the flickable; it ignores clicks and only takes the wheel.
MouseArea {
    id: root
    property Flickable flick
    property real rowHeight: 282      // height of one "row" (one board tile row), so every page scrolls the same distance
    property real rowsPerNotch: 0.3   // one wheel notch scrolls this many rows
    readonly property real speed: rowsPerNotch * rowHeight / 120   // pixels per wheel-angle unit
    property real smoothing: 0.09     // seconds; larger = floatier
    property real target: 0
    // middle click: scroll by moving the mouse up/down from where you clicked; click again to stop
    property bool autoScroll: false
    property real anchorX: 0
    property real anchorY: 0
    property real pressedAt: 0
    property bool dragged: false      // moved away from where it started while the button was held
    acceptedButtons: autoScroll ? Qt.AllButtons : Qt.MiddleButton
    hoverEnabled: autoScroll        // (only then: otherwise this area would hide the hover of what is below)
    cursorShape: autoScroll ? Qt.SizeVerCursor : Qt.ArrowCursor
    z: 100

    function minY() { return flick.originY - flick.topMargin }
    function maxY() { return Math.max(minY(), flick.originY + flick.contentHeight - flick.height + flick.bottomMargin) }

    FrameAnimation {
        id: glide
        running: false
        onTriggered: {
            if (!root.flick) { stop(); return }
            var d = root.target - root.flick.contentY
            if (Math.abs(d) < 0.4) {
                root.flick.contentY = root.target
                stop()
            } else {
                root.flick.contentY += d * (1 - Math.exp(-frameTime / root.smoothing))
            }
        }
    }

    onPressed: function (m) {
        if (m.button === Qt.MiddleButton && !autoScroll && flick) {
            glide.stop()
            anchorX = m.x
            anchorY = m.y
            pressedAt = Date.now()
            dragged = false
            autoScroll = true
            m.accepted = true
        } else {
            autoScroll = false
            m.accepted = (m.button === Qt.MiddleButton)   // other buttons only stop it and go on to what is below
        }
    }
    // letting go of the middle button: a quick click keeps scrolling until the next click; holding
    // it, or moving the mouse while holding, ends when it is let go
    onReleased: function (m) {
        if (m.button === Qt.MiddleButton && autoScroll && (dragged || Date.now() - pressedAt > 350))
            autoScroll = false
    }
    onPositionChanged: function (m) {
        if (autoScroll && (m.buttons & Qt.MiddleButton) && Math.abs(m.y - anchorY) > 10)
            dragged = true
    }
    FrameAnimation {
        running: root.autoScroll
        onTriggered: {
            if (!root.flick) { root.autoScroll = false; return }
            var d = root.mouseY - root.anchorY
            var dead = 10
            if (Math.abs(d) <= dead) return
            var v = (Math.abs(d) - dead) * (d < 0 ? -1 : 1) * 7      // px per second
            root.flick.contentY = Math.max(root.minY(), Math.min(root.maxY(), root.flick.contentY + v * frameTime))
        }
    }
    // marker where the middle click happened
    Rectangle {
        visible: root.autoScroll
        x: root.anchorX - 14
        y: root.anchorY - 14
        width: 28; height: 28; radius: 14
        color: palette.window
        border.width: 1
        border.color: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.5)
        Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; anchors.centerIn: parent; text: "↕"; font.pixelSize: 16; color: palette.windowText }
    }
    onWheel: function (w) {
        autoScroll = false
        if (!flick) { w.accepted = false; return }
        flick.cancelFlick()
        if (!glide.running) target = flick.contentY
        var dy = w.angleDelta.y * speed   // same distance on every platform
        target = Math.max(minY(), Math.min(maxY(), target - dy))
        glide.start()
        w.accepted = true
    }
}
