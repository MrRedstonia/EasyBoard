import QtQuick

// Kitty: loading as a stroke running round and round a heart outline.
Canvas {
    id: c
    property real phase: 0
    readonly property color ink: "#ff5fa2"
    NumberAnimation on phase { from: 0; to: 1; duration: 1300; loops: Animation.Infinite }
    onPhaseChanged: requestPaint()
    onWidthChanged: requestPaint()

    // a point on the heart curve (t = 0..2π), fitted into the canvas
    function pt(t) {
        var s = Math.min(width, height) / 36
        var x = 16 * Math.pow(Math.sin(t), 3)
        var y = -(13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t) - Math.cos(4 * t))
        return [width / 2 + x * s, height / 2 + (y + 1.5) * s]
    }
    function trace(ctx, from, to) {
        var steps = 60
        for (var i = 0; i <= steps; i++) {
            var p = pt(from + (to - from) * i / steps)
            if (i === 0) ctx.moveTo(p[0], p[1]); else ctx.lineTo(p[0], p[1])
        }
    }
    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.lineCap = "round"
        ctx.lineJoin = "round"
        ctx.lineWidth = Math.max(1.5, width / 11)
        // the whole heart, faint
        ctx.strokeStyle = Qt.rgba(ink.r, ink.g, ink.b, 0.25)
        ctx.beginPath(); trace(ctx, 0, Math.PI * 2); ctx.stroke()
        // the running stroke: a third of the way round
        var start = phase * Math.PI * 2
        ctx.strokeStyle = ink
        ctx.beginPath(); trace(ctx, start, start + Math.PI * 0.7); ctx.stroke()
    }
}
