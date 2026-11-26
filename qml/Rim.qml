import QtQuick
import QtQuick.Shapes

// The light edge of a glass surface: a thin ring, bright along the top, almost gone on the sides and
// catching a soft reflection again along the bottom, so it blends into the surface instead of being a
// flat white line. Also used (fully opaque) as the mask for GlassBackdrop's reflecting rim.
Shape {
    id: root
    property real radius: 0
    property real strength: 1
    property real thickness: 1.5
    property bool solid: false            // true: the same shape at full strength (for masks)
    property bool uniform: false          // true: the same strength all the way round (for masks)
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
        strokeWidth: -1
        strokeColor: "transparent"
        fillRule: ShapePath.OddEvenFill
        fillGradient: LinearGradient {
            x1: 0; y1: 0; x2: 0; y2: root.height
            GradientStop { position: 0.0;  color: Qt.rgba(1, 1, 1, (root.uniform ? 1 : root.solid ? 1 : 0.75) * root.strength) }
            GradientStop { position: 0.35; color: Qt.rgba(1, 1, 1, (root.uniform ? 1 : root.solid ? 0.35 : 0.12) * root.strength) }
            GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, (root.uniform ? 1 : root.solid ? 0.3 : 0.08) * root.strength) }
            GradientStop { position: 1.0;  color: Qt.rgba(1, 1, 1, (root.uniform ? 1 : root.solid ? 0.85 : 0.45) * root.strength) }
        }
        PathRectangle { x: 0; y: 0; width: root.width; height: root.height; radius: root.radius }
        PathRectangle {
            x: root.thickness; y: root.thickness
            width: Math.max(0, root.width - 2 * root.thickness)
            height: Math.max(0, root.height - 2 * root.thickness)
            radius: Math.max(0, root.radius - root.thickness)
        }
    }
}
