import QtQuick
import QtQuick.Controls

// Themed single-line text input.
TextField {
    id: control

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    implicitHeight: 42
    leftPadding: 14
    rightPadding: 14
    font.pixelSize: 14
    color: palette.windowText
    placeholderTextColor: ink(0.4)
    selectByMouse: true
    verticalAlignment: TextInput.AlignVCenter

    background: Rectangle {
        GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius; control: true }
        radius: Window.window && Window.window.controlRadius ? Window.window.controlRadius(height, 10) : 10
        color: Window.window && Window.window.solid ? Window.window.solid(control.ink(0.06)) : control.ink(0.06)
        border.width: control.activeFocus ? (Window.window && Window.window.focusEdge ? Window.window.focusEdge(2) : 2) : (Window.window && Window.window.edge ? Window.window.edge(1) : 1)
        border.color: control.activeFocus ? palette.highlight
                    : Window.window && Window.window.themeColor ? Window.window.themeColor("controlBorder", control.ink(0.14)) : control.ink(0.14)
        Shadow { z: -2; lift: 3; opacity: strength * 0.6 }
        Sheen { anchors.fill: parent; radius: parent.radius }
    }
}
