import QtQuick

// A tooltip on glass: the glass themes' tooltip. (A theme can draw its own: <replace part="tooltip">.
// Main.qml puts it into Qt's shared tooltip, so every tooltip in the app uses it.)
Rectangle {
    id: root
    property string text: ""
    readonly property var w: Window.window
    implicitWidth: label.implicitWidth + 22
    implicitHeight: label.implicitHeight + 12
    radius: Math.min(height / 2, 12)
    color: w && w.themeColor ? w.themeColor("menu", palette.toolTipBase) : palette.toolTipBase
    GlassBackdrop { anchors.fill: parent; z: -1; radius: root.radius }
    Shadow { z: -2 }
    Text {
        id: label
        anchors.centerIn: parent
        text: root.text
        color: palette.toolTipText
        font.pixelSize: 12
    }
}
