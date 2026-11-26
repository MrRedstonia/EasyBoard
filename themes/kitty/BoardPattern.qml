import QtQuick

// Kitty: a faint, spaced-out paw-print pattern inside the Soundboard's box.
Item {
    id: root
    readonly property int step: 64
    Grid {
        x: 14
        y: 14
        columns: Math.ceil(root.width / root.step) + 1
        columnSpacing: root.step - 28
        rowSpacing: root.step - 28
        opacity: 0.13
        Repeater {
            model: (Math.ceil(root.width / root.step) + 1) * (Math.ceil(root.height / root.step) + 1)
            Image {
                required property int index
                width: 28
                height: 28
                source: Qt.resolvedUrl("paw-pink.svg")
                sourceSize: Qt.size(56, 56)
                rotation: index % 2 === 0 ? -18 : 14
            }
        }
    }
}
