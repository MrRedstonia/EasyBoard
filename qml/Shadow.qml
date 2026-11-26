import QtQuick

// A soft drop shadow around a surface, for themes with <depth shadow="..."/>. Put it inside the surface
// with `z: -2` (under a GlassBackdrop, which uses -1). A blurred picture stretched around the edges, so
// it costs nothing per frame. The surface's own area is cut out of it, so see-through surfaces stay
// clear, and it follows the surface's corner rounding (`radius`, taken from the parent by default).
Item {
    id: root
    readonly property var w: Window.window
    readonly property real strength: w && w.themed ? w.theme.depth.shadow : 0
    property real radius: parent && parent.radius !== undefined ? parent.radius : 20
    property real lift: 5            // (kept for compatibility; the drop is part of the picture)
    visible: strength > 0 && w.shadowUrl !== ""
    anchors.fill: parent
    opacity: strength
    // the picture's corners are drawn with a radius of 20: drawn at 1/s and scaled by s, they get the
    // surface's radius (s = radius / 20)
    readonly property real s: Math.max(0.3, Math.min(3, (radius > 0 ? radius : 6) / 20))
    BorderImage {
        source: root.visible ? root.w.shadowUrl : ""
        x: -40 * root.s
        y: -40 * root.s
        width: root.width / root.s + 80
        height: root.height / root.s + 80
        transformOrigin: Item.TopLeft
        scale: root.s
        smooth: true
        // corners of up to 60 px, but never more than half the size (small buttons)
        readonly property int bw: Math.min(60, Math.floor(width / 2))
        readonly property int bh: Math.min(60, Math.floor(height / 2))
        border { left: bw; top: bh; right: bw; bottom: bh }
    }
}
