import QtQuick

// Liquid Glass: a sound's ID on a small, flat glass pill (a light see-through fill and a fine edge).
Rectangle {
    id: root
    property string text: ""
    implicitWidth: label.implicitWidth + 14
    implicitHeight: 19
    radius: height / 2
    color: "#b3ffffff"
    border.width: 1
    border.color: "#e6ffffff"
    Text {
        id: label
        anchors.centerIn: parent
        text: root.text
        color: "#3a3d44"
        font.pixelSize: 11
        font.bold: true
    }
}
