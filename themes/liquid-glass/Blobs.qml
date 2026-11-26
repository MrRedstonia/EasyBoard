import QtQuick
import QtQuick.Shapes
import QtQuick.Effects

// Liquid Glass background: soft blobs of white, gray and (very faintly) your accent color drifting
// slowly and melting into each other like drops of liquid: where two come close they pull together
// with a liquid neck, and part again as they drift on. No outlines and no rings: the clear glass on
// top bends gentle light, not edges.
Item {
    id: root
    readonly property real speed: Window.window && Window.window.animSpeed > 0 ? Window.window.animSpeed : 1
    readonly property real m: Math.max(width, height)
    // your system's accent color (not the theme's): used very lightly
    readonly property color accent: Window.window && Window.window.systemAccent ? Window.window.systemAccent : "#3daee9"

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#e3e6eb" }
            GradientStop { position: 1.0; color: Qt.tint("#c9cdd5", Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.05)) }
        }
    }

    // the drops: soft round glows (solid in the middle, fading out), so overlapping ones mix their
    // colors instead of drawing an edge
    Item {
        id: drops
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Repeater {
            // color ("a" = your accent at that strength), size (fraction of the window), path (x0,y0) → (x1,y1)
            model: [
                { c: "#ffffff", s: 0.46, x0: -0.06, y0: -0.10, x1: 0.16, y1: 0.06, d: 23000 },
                { c: "#b9bfca", s: 0.40, x0: 0.58, y0: 0.00, x1: 0.38, y1: 0.20, d: 27000 },
                { a: 0.15,      s: 0.44, x0: 0.12, y0: 0.52, x1: 0.40, y1: 0.40, d: 25000 },
                { c: "#cfd4dc", s: 0.36, x0: 0.70, y0: 0.58, x1: 0.54, y1: 0.70, d: 30000 },
                { c: "#ffffff", s: 0.30, x0: 0.40, y0: 0.16, x1: 0.14, y1: 0.34, d: 21000 },
                { c: "#aeb4bf", s: 0.28, x0: 0.80, y0: 0.22, x1: 0.62, y1: 0.46, d: 26000 },
                { a: 0.11,      s: 0.32, x0: 0.48, y0: 0.78, x1: 0.68, y1: 0.62, d: 28000 },
                { c: "#ffffff", s: 0.26, x0: 0.04, y0: 0.30, x1: 0.24, y1: 0.18, d: 24000 }
            ]
            Shape {
                id: drop
                required property var modelData
                readonly property real d: root.m * modelData.s
                // the accent drops are gray with only a wash of the accent in them
                readonly property color tone: modelData.a !== undefined
                    ? Qt.tint("#cfd4dc", Qt.rgba(root.accent.r, root.accent.g, root.accent.b, modelData.a)) : modelData.c
                readonly property real strength: 1
                width: d
                height: d
                x: modelData.x0 * root.width
                y: modelData.y0 * root.height
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: -1
                    fillGradient: RadialGradient {
                        centerX: drop.d / 2; centerY: drop.d / 2; centerRadius: drop.d / 2
                        focalX: drop.d / 2; focalY: drop.d / 2
                        GradientStop { position: 0.0; color: Qt.alpha(drop.tone, Math.min(1, drop.strength)) }
                        GradientStop { position: 0.55; color: Qt.alpha(drop.tone, Math.min(1, 0.85 * drop.strength)) }
                        GradientStop { position: 1.0; color: Qt.alpha(drop.tone, 0) }
                    }
                    PathAngleArc { centerX: drop.d / 2; centerY: drop.d / 2; radiusX: drop.d / 2; radiusY: drop.d / 2; startAngle: 0; sweepAngle: 360 }
                }
                SequentialAnimation on x {
                    loops: Animation.Infinite
                    NumberAnimation { to: drop.modelData.x1 * root.width; duration: drop.modelData.d / root.speed; easing.type: Easing.InOutSine }
                    NumberAnimation { to: drop.modelData.x0 * root.width; duration: drop.modelData.d / root.speed; easing.type: Easing.InOutSine }
                }
                SequentialAnimation on y {
                    loops: Animation.Infinite
                    NumberAnimation { to: drop.modelData.y1 * root.height; duration: drop.modelData.d * 1.3 / root.speed; easing.type: Easing.InOutSine }
                    NumberAnimation { to: drop.modelData.y0 * root.height; duration: drop.modelData.d * 1.3 / root.speed; easing.type: Easing.InOutSine }
                }
            }
        }
    }
    // blur them into each other...
    Item {
        id: melted
        anchors.fill: parent
        visible: false
        layer.enabled: true
        MultiEffect { anchors.fill: parent; source: drops; autoPaddingEnabled: false; blurEnabled: true; blur: 0.7; blurMax: 48 }
    }
    // ...and keep only where they are dense enough: one liquid shape with soft edges, pulling together
    // where drops meet
    MultiEffect {
        anchors.fill: parent
        source: melted
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: melted
        maskThresholdMin: 0.42
        maskSpreadAtMin: 0.12
    }
}
