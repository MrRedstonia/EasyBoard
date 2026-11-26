import QtQuick

// Kitty: a sound's ID on a little dark-pink heart.
Item {
    id: root
    property string text: ""
    implicitWidth: Math.max(30, label.implicitWidth + 16)
    implicitHeight: 27

    Canvas {
        anchors.fill: parent
        onWidthChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var w = width, h = height
            ctx.fillStyle = "#c2407a"
            ctx.strokeStyle = "#ffffff"
            ctx.lineWidth = 1.5
            ctx.beginPath()
            ctx.moveTo(w / 2, h - 1.5)
            ctx.bezierCurveTo(w * 0.12, h * 0.68, 1, h * 0.42, w * 0.08, h * 0.2)
            ctx.bezierCurveTo(w * 0.2, 0.5, w * 0.44, 1, w / 2, h * 0.24)
            ctx.bezierCurveTo(w * 0.56, 1, w * 0.8, 0.5, w * 0.92, h * 0.2)
            ctx.bezierCurveTo(w - 1, h * 0.42, w * 0.88, h * 0.68, w / 2, h - 1.5)
            ctx.closePath()
            ctx.fill()
            ctx.stroke()
        }
    }
    Text {
        id: label
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.18)
        text: root.text
        color: "white"
        font.pixelSize: 10
        font.bold: true
    }
}
