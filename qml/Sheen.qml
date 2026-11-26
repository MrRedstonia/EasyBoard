import QtQuick

// The light on top of a raised surface (themes with <depth sheen="..."/>): bright along the top,
// fading out, with a thin bright inner edge. Put it inside the surface, over its color.
Item {
    id: root
    property real radius: 0
    property real amount: 1               // per surface: how much of the theme's sheen it gets
    readonly property var w: Window.window
    readonly property real strength: (w && w.themed ? w.theme.depth.sheen : 0) * amount
    visible: strength > 0
    // created only while the theme has a sheen (many surfaces carry one)
    Loader {
        anchors.fill: parent
        active: root.strength > 0
        sourceComponent: Item {
            // light from above, and a soft reflection along the bottom (not a dark shade: that grays glass)
            Rectangle {
                anchors.fill: parent
                radius: root.radius
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.5 * root.strength) }
                    GradientStop { position: 0.45; color: Qt.rgba(1, 1, 1, 0.05 * root.strength) }
                    GradientStop { position: 0.8; color: Qt.rgba(1, 1, 1, 0.0) }
                    GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.18 * root.strength) }
                }
            }
            Rim { anchors.fill: parent; radius: root.radius; strength: root.strength }
        }
    }
}
