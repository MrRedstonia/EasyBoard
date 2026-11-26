import QtQuick

// Glass (a theme's <glass .../>) under a surface. Put it inside the surface with `z: -1`, under the
// surface's own (see-through) color.
//
// `control: true` is for buttons, drop-downs and fields: those only get glass when the theme also asks
// for it (<controls glass="true">); `tile: true` likewise for sound tiles (<tiles glass="true">).
//
// Many controls carry one of these, so this is only a light wrapper: the glass itself (GlassSurface.qml,
// with its effects) is created only while a theme actually uses it.
Item {
    id: root
    property real radius: 0
    property bool control: false
    property bool tile: false
    readonly property var w: Window.window
    readonly property bool on: !!(w && w.glassOn)
        && (!control || w.theme.controls.glass === true)
        && (!tile || w.theme.tiles.glass === true)
    visible: on
    Loader {
        anchors.fill: parent
        active: root.on
        sourceComponent: GlassSurface { radius: root.radius }
    }
}
