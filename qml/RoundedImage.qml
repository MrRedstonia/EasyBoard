import QtQuick
import QtQuick.Effects

// Picture cropped to fill the item, with rounded corners (needs Qt 6.5+ for MultiEffect).
Item {
    id: root
    property url source
    property real radius: 12
    readonly property bool ready: img.status === Image.Ready

    Image {
        id: img
        anchors.fill: parent
        source: root.source
        visible: false
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        // loaded at twice the size it is shown (sharp on high-DPI screens), not bigger: every picture
        // on the board is kept in memory at this size
        sourceSize.width: Math.min(512, Math.max(64, Math.ceil(root.width * 2)))
        sourceSize.height: Math.min(512, Math.max(64, Math.ceil(root.height * 2)))
        mipmap: true
    }

    Item {
        id: maskItem
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle { anchors.fill: parent; radius: root.radius; color: "black" }
    }

    MultiEffect {
        anchors.fill: parent
        visible: root.ready
        source: img
        maskEnabled: true
        maskSource: maskItem
    }
}
