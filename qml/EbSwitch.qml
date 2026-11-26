import QtQuick
import QtQuick.Controls

// Themed on/off switch with a text label.
Switch {
    id: control

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    implicitHeight: 34
    opacity: enabled ? 1 : 0.45
    spacing: 12
    font.pixelSize: 14

    indicator: Rectangle {
        x: control.leftPadding
        y: (control.height - height) / 2
        implicitWidth: 44
        implicitHeight: 24
        radius: 12
        color: control.checked ? (palette.highlight.hslLightness > 0.85 ? control.ink(0.38) : palette.highlight)
             : Window.window && Window.window.solid ? Window.window.solid(control.ink(0.20)) : control.ink(0.20)
        Behavior on color { ColorAnimation { duration: 120 } }

        Rectangle {
            x: control.checked ? parent.width - width - 3 : 3
            y: 3
            width: 18
            height: 18
            radius: 9
            color: "white"
            // on a very light accent (a white theme accent) the knob needs an edge to be seen
            border.width: palette.highlight.hslLightness > 0.85 ? 1 : 0
            border.color: control.ink(0.25)
            Behavior on x { NumberAnimation { duration: 120 } }
        }
    }

    contentItem: Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
        text: control.text
        font: control.font
        color: palette.windowText
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.Wrap
        leftPadding: control.indicator.width + control.spacing
    }
}
