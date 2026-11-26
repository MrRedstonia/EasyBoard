import QtQuick
import QtQuick.Effects

// The glass itself (see GlassBackdrop.qml, which creates this only when a theme uses glass).
// Two looks, both from the theme's <glass .../> settings:
// * clear (Apple's "Clear" Liquid Glass: blur 0, no tint): the background shows through sharp, and only
//   along the edge it is bent like light through the rim of a lens: a soft band where what's behind is
//   pulled in from just outside, a little brighter and more colorful. No white border line.
// * frosted (blur > 0, a tint): the background blurred under a frost color, the older glassmorphism look.
//
// The window draws its background into one texture per frame (Main.qml, glassTexture); each glass
// surface only cuts out its own piece of it, at half resolution, so this stays cheap.
Item {
    id: root
    property real radius: 0
    readonly property var w: Window.window
    readonly property var glass: w && w.glassOn ? w.theme.glass : null
    readonly property bool on: glass !== null
    readonly property real pad: 48              // extra background around the piece (for the blur and the bending)
    // the bending band; on small controls it stays a fraction of their size, or it would smear the middle too
    readonly property real band: glass ? Math.min(glass.refraction, Math.min(width, height) * 0.2) : 0

    // Where this item is in the window, and how big it is there (it may be scaled, e.g. a button growing
    // under the mouse). Followed every frame, so glass that moves or grows never lags behind.
    property rect at: Qt.rect(0, 0, 1, 1)
    function place() {
        if (!on) return
        var a = root.mapToItem(null, 0, 0)
        var b = root.mapToItem(null, root.width, root.height)
        var r = Qt.rect(a.x, a.y, Math.max(1, b.x - a.x), Math.max(1, b.y - a.y))
        if (r.x !== at.x || r.y !== at.y || r.width !== at.width || r.height !== at.height) at = r
    }
    onOnChanged: place()
    Component.onCompleted: place()
    // Newly made glass (a tile after the board is rebuilt, a menu that opens) shows nothing until its
    // place in the window is known (the next frame): before that it would draw a wrong piece of the
    // background for a moment, which flickers.
    property bool placed: false
    visible: placed
    // (after that only while it can be seen: glass on a page that is not open does nothing)
    FrameAnimation { running: root.on && (!root.placed || root.visible); onTriggered: { root.place(); root.placed = true } }
    // the scale between this item and the window (1 unless it is growing / shrinking)
    readonly property real sx: at.width / Math.max(1, root.width)
    readonly property real sy: at.height / Math.max(1, root.height)

    Item {
        id: content
        anchors.fill: parent
        clip: true
        layer.enabled: root.on && root.radius > 0
        layer.effect: MultiEffect { maskEnabled: true; maskSource: mask }

        ShaderEffectSource {
            id: piece
            x: -root.pad
            y: -root.pad
            width: root.width + 2 * root.pad
            height: root.height + 2 * root.pad
            visible: false
            live: true
            sourceItem: root.on ? root.w.glassTexture : null
            // the glass texture is larger than the window by glassMargin on every side
            sourceRect: root.on ? Qt.rect(root.at.x + root.w.glassMargin - root.pad * root.sx, root.at.y + root.w.glassMargin - root.pad * root.sy,
                                          width * root.sx, height * root.sy)
                                : Qt.rect(0, 0, 1, 1)
            textureSize: Qt.size(Math.max(1, Math.round(width / 2)), Math.max(1, Math.round(height / 2)))
        }
        // what's behind: sharp when clear (blur 0), blurred when frosted
        MultiEffect {
            x: piece.x
            y: piece.y
            width: piece.width
            height: piece.height
            source: piece
            autoPaddingEnabled: false
            blurEnabled: root.glass !== null && root.glass.blur > 0
            blur: root.glass ? root.glass.blur : 0
            blurMax: 64
            saturation: root.glass ? root.glass.saturation : 0
            brightness: root.glass ? root.glass.brightness : 0
            // "lens": what is behind is shown a little bigger, like through thick glass
            transform: Scale {
                origin.x: root.pad + root.width / 2
                origin.y: root.pad + root.height / 2
                xScale: root.glass ? root.glass.lens : 1
                yScale: root.glass ? root.glass.lens : 1
            }
        }
        // frost (transparent for clear glass)
        Rectangle { anchors.fill: parent; color: root.glass ? root.glass.tint : "transparent" }
        // a faint light from above, a soft reflection below
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: root.glass ? root.glass.highlight : "transparent" }
                GradientStop { position: 0.45; color: "transparent" }
                GradientStop { position: 1.0; color: root.glass ? root.glass.shade : "transparent" }
            }
        }
        // The bending along the edge: near the rim you see what is just outside, pulled in (the background
        // read from a larger area into the same space), a little brighter and more colorful, through a
        // soft band that is strongest right at the edge and fades out inwards. This is clear glass's only "border".
        ShaderEffectSource {
            id: bentPiece
            x: piece.x
            y: piece.y
            width: piece.width
            height: piece.height
            visible: false
            live: true
            // How far the edge bends: the same few pixels on every side, whatever the size of the surface
            // (scaling the whole background around the middle bent the far ends of wide surfaces much
            // more, which showed as bars along their top and bottom).
            readonly property real bend: root.glass ? root.band * Math.max(0, 1 / Math.max(0.5, root.glass.edgeScale) - 1) * 2 : 0
            readonly property real kx: 1 + 2 * bend / Math.max(1, root.width)
            readonly property real ky: 1 + 2 * bend / Math.max(1, root.height)
            sourceItem: root.on && root.band > 0 ? root.w.glassTexture : null
            sourceRect: root.on ? Qt.rect(root.at.x + root.w.glassMargin + root.at.width / 2 - (width * root.sx * kx) / 2,
                                          root.at.y + root.w.glassMargin + root.at.height / 2 - (height * root.sy * ky) / 2,
                                          width * root.sx * kx, height * root.sy * ky)
                                : Qt.rect(0, 0, 1, 1)
            textureSize: Qt.size(Math.max(1, Math.round(width / 2)), Math.max(1, Math.round(height / 2)))
        }
        MultiEffect {
            visible: root.band > 0
            x: piece.x
            y: piece.y
            width: piece.width
            height: piece.height
            source: bentPiece
            autoPaddingEnabled: false
            brightness: root.glass ? root.glass.edgeBrightness : 0
            saturation: root.glass ? root.glass.edgeSaturation : 0
            maskEnabled: true
            maskSource: bandMask
            // threshold 0.5 with full softness passes the band's alpha straight through (0 → hidden, 1 → shown)
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }
    }

    // The soft band along the edge, laid out like `piece` (the effect's source): rings of different
    // widths stacked on each other, so it is strongest at the edge and fades out inwards.
    Item {
        id: bandMask
        x: -root.pad
        y: -root.pad
        width: root.width + 2 * root.pad
        height: root.height + 2 * root.pad
        visible: false
        layer.enabled: root.on && root.band > 0
        Repeater {
            // many thin steps, the widest the faintest: no visible inner edge
            model: [1.0, 0.86, 0.72, 0.59, 0.47, 0.36, 0.26, 0.17, 0.09]
            Rim {
                required property real modelData
                x: root.pad
                y: root.pad
                width: root.width
                height: root.height
                radius: root.radius
                thickness: Math.max(1, root.band * modelData)
                solid: true
                uniform: true
                strength: 0.2
            }
        }
    }

    Item {
        id: mask
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle { anchors.fill: parent; radius: root.radius; color: "black" }
    }
}
