import QtQuick
import QtQuick.Controls

// Themed button. `accent: true` fills it with the system highlight color.
Button {
    id: control
    property bool accent: false
    property bool danger: false
    // keep the see-through look even when controls are made solid (e.g. on top of a picture preview)
    property bool glass: false
    // true: a long label wraps onto a second line instead of being cut off
    property bool wrap: false
    // color changes are animated only after the button has been in its window for a moment
    property bool settled: false
    readonly property var shownIn: Window.window
    onShownInChanged: { settled = false; if (shownIn) settleTimer.restart() }
    Timer { id: settleTimer; interval: 250; onTriggered: control.settled = true }

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    implicitHeight: wrap ? Math.max(40, label.implicitHeight + 14) : 40
    // a theme can make buttons grow under the mouse and sink when pressed
    scale: Window.window && Window.window.controlScale ? Window.window.controlScale(control.hovered, control.down, control.width) : 1
        Behavior on scale { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
    implicitWidth: Math.max(84, label.implicitWidth + 32)
    font.pixelSize: 14
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus

    background: Rectangle {
        GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius; control: true }
        radius: Window.window && Window.window.controlRadius ? Window.window.controlRadius(height, 10) : 10
        antialiasing: true
        color: {
            var w = Window.window
            if (!control.enabled) return w && w.solid && !control.glass ? w.solid(control.ink(0.05)) : control.ink(0.05)
            if (control.accent) {
                // glass controls: a highlighted button is brighter glass, not a solid block of color
                if (w && w.themed && w.theme.controls.glass) {
                    var sel = Qt.color(w.themeColor("selection", palette.highlight))
                    return control.down ? Qt.darker(sel, 1.1) : control.hovered ? Qt.lighter(sel, 1.1) : sel
                }
                if (control.down) return Qt.darker(palette.highlight, 1.25)
                return control.hovered ? Qt.lighter(palette.highlight, 1.12) : palette.highlight
            }
            // (no red warning color on glass: a delete button looks like the others there)
            if (control.danger && control.hovered && !(w && w.themed && w.theme.controls.glass)) return Qt.rgba(0.9, 0.28, 0.3, 0.28)
            var state = control.down ? 2 : control.hovered ? 1 : 0
            return w && w.controlFill ? w.controlFill(state, control.glass) : control.ink([0.08, 0.13, 0.20][state])
        }
        border.width: control.accent ? 0 : (control.visualFocus ? (Window.window && Window.window.focusEdge ? Window.window.focusEdge(1) : 1) : (Window.window && Window.window.edge ? Window.window.edge(1) : 1))
        Shadow { z: -2; lift: 3; opacity: strength * 0.6 }
        Sheen { anchors.fill: parent; radius: parent.radius }
        border.color: control.visualFocus ? palette.highlight
                    : Window.window && Window.window.themeColor ? Window.window.themeColor("controlBorder", control.ink(0.14)) : control.ink(0.14)
        Behavior on color { enabled: control.settled; ColorAnimation { duration: 50 } }
    }

    contentItem: Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
        id: label
        text: control.text
        font: control.font
        color: control.accent && !(Window.window && Window.window.themed && Window.window.theme.controls.glass) ? palette.highlightedText : palette.windowText
        opacity: control.enabled ? 1 : 0.4
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: control.wrap ? Text.ElideNone : Text.ElideRight
        wrapMode: control.wrap ? Text.WordWrap : Text.NoWrap
        maximumLineCount: control.wrap ? 2 : 1
        lineHeight: control.wrap ? 0.95 : 1
    }
}
