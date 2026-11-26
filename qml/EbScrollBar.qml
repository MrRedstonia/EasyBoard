import QtQuick
import QtQuick.Controls

// Scroll bar that stays visible against the window background.
ScrollBar {
    id: bar
    implicitWidth: 12
    padding: 2
    minimumSize: 0.08
    property real cornerRadius: 0      // > 0: track is the right strip of a rounded section
    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    // glass themes: no track, and the handle is a small pill of glass
    readonly property bool glass: !!(Window.window && Window.window.glassOn)
    contentItem: Rectangle {
        implicitWidth: 8
        radius: 4
        color: bar.glass ? Qt.rgba(1, 1, 1, bar.pressed ? 0.55 : bar.hovered ? 0.42 : 0.3)
             : bar.pressed ? bar.ink(0.65) : (bar.hovered ? bar.ink(0.55) : bar.ink(0.42))
        opacity: bar.size < 1 ? 1 : 0
        GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius }
        Shadow { z: -2; opacity: strength * 0.8 }
        Behavior on color { ColorAnimation { duration: 120 } }
    }
    background: Item {
        opacity: bar.size < 1 && !bar.glass ? 1 : 0
        clip: bar.cornerRadius > 0
        Rectangle {
            x: bar.cornerRadius > 0 ? -bar.cornerRadius * 2 : 0
            width: parent.width + (bar.cornerRadius > 0 ? bar.cornerRadius * 2 : 0)
            height: parent.height
            radius: bar.cornerRadius > 0 ? bar.cornerRadius : 4
            color: bar.ink(0.07)
        }
    }
}
