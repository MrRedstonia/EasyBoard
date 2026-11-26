import QtQuick
import QtQuick.Controls

// Themed slider.
Slider {
    id: control

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    implicitHeight: 30

    background: Rectangle {
        x: control.leftPadding
        y: control.topPadding + control.availableHeight / 2 - height / 2
        width: control.availableWidth
        height: 6
        radius: 3
        readonly property color plain: control.enabled ? control.ink(0.16) : control.ink(0.08)
        color: Window.window && Window.window.solid ? Window.window.solid(plain) : plain

        Rectangle {
            width: control.visualPosition * parent.width
            height: parent.height
            radius: 3
            // a very light accent (a white theme accent) would vanish on a light page: soft gray then
            color: !control.enabled ? Qt.tint(palette.window, control.ink(0.28))
                 : palette.highlight.hslLightness > 0.85 ? control.ink(0.38) : palette.highlight
        }
    }

    handle: Rectangle {
        x: control.leftPadding + control.visualPosition * (control.availableWidth - width)
        y: control.topPadding + control.availableHeight / 2 - height / 2
        width: 20
        height: 20
        radius: 10
        color: control.enabled ? "white" : Qt.tint(palette.window, control.ink(0.35))
        border.width: 2
        // a very light accent (a white theme accent) would leave the handle without an edge: gray then
        readonly property color edge: palette.highlight.hslLightness > 0.85 ? control.ink(0.3) : palette.highlight
        border.color: !control.enabled ? Qt.tint(palette.window, control.ink(0.28)) : (control.pressed ? Qt.darker(edge, 1.2) : edge)
    }
}
