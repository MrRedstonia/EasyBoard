import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Themed tray menu for Windows (the native one is always light). Opened on right click.
ApplicationWindow {
    id: menu
    property var mainWin
    property var backend
    property bool loopAll: false
    property bool mainVisible: true

    transientParent: null
    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.NoDropShadowWindowHint
    color: "transparent"
    width: 143 + 2 * margin
    height: col.implicitHeight + 2 * margin + 4
    readonly property int margin: 4

    // Opens next to the mouse cursor (px, py in screen coordinates), kept inside the screen.
    function openAt(px, py) {
        var scr = Qt.application.screens[0]
        for (var i = 0; i < Qt.application.screens.length; i++) {
            var c = Qt.application.screens[i]
            if (px >= c.virtualX && px < c.virtualX + c.width && py >= c.virtualY && py < c.virtualY + c.height) scr = c
        }
        var nx = px - width / 2
        nx = Math.max(scr.virtualX + 4, Math.min(scr.virtualX + scr.width - width - 4, nx))
        var ny = py > scr.virtualY + scr.height / 2 ? py - height - 4 : py + 4
        ny = Math.max(scr.virtualY + 4, Math.min(scr.virtualY + scr.height - height - 4, ny))
        x = nx; y = ny
        menu.opacity = 0        // window-level, so the stale picture from last time never shows
        show(); raise(); requestActivate()
        openAnim.restart()
    }

    onActiveChanged: if (!active) hide()
    ParallelAnimation {
        id: openAnim
        NumberAnimation { target: menu; property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.Linear }
    }

    component Item2: Rectangle {
        id: it
        property string label
        property bool checked: false
        property bool check: false
        signal clicked()
        Layout.fillWidth: true
        Layout.preferredHeight: 23
        radius: 6
        color: ma.containsMouse ? Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.12) : "transparent"
        Behavior on color { ColorAnimation { duration: 60 } }
        Text {
            anchors.left: parent.left; anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: it.label
            color: palette.windowText
            // the font and crisp text of the native Windows menus
            font.family: Qt.platform.os === "windows" ? "Segoe UI" : Qt.application.font.family
            font.pixelSize: 12
            renderType: Text.NativeRendering
        }
        // checkbox: an outline, filled with the accent color and a plain white tick when on
        Rectangle {
            visible: it.check
            anchors.right: parent.right; anchors.rightMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            width: 15; height: 15; radius: 4
            color: it.checked ? palette.highlight : "transparent"
            border.width: it.checked ? 0 : 1
            border.color: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.45)
            Canvas {
                anchors.fill: parent
                visible: it.checked
                onPaint: {
                    var c = getContext("2d")
                    c.reset()
                    c.strokeStyle = "#ffffff"
                    c.lineWidth = 1.6
                    c.lineCap = "butt"
                    c.lineJoin = "miter"
                    c.beginPath()
                    c.moveTo(4, 7.7)
                    c.lineTo(6.5, 10.2)
                    c.lineTo(11, 5)
                    c.stroke()
                }
            }
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            onClicked: { menu.hide(); it.clicked() }
        }
    }

    Rectangle {
        id: card
        anchors.fill: parent
        anchors.margins: 1
        radius: 8
        color: palette.window
        border.width: 1
        border.color: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.18)

        ColumnLayout {
            id: col
            anchors.fill: parent
            anchors.margins: menu.margin
            spacing: 1
            Item2 {
                label: menu.mainVisible ? qsTr("Hide EasyBoard") : qsTr("Show EasyBoard")
                onClicked: {
                    if (menu.mainWin.visible) menu.mainWin.hide()
                    else { menu.mainWin.show(); menu.mainWin.raise(); menu.mainWin.requestActivate() }
                }
            }
            Item2 { label: qsTr("Stop All Sounds"); onClicked: menu.backend.stopAll() }
            Item2 { label: qsTr("Loop Sounds"); check: true; checked: menu.loopAll; onClicked: menu.backend.toggleLoopAll() }
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 1; Layout.topMargin: 2; Layout.bottomMargin: 2
                color: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.14)
            }
            Item2 { label: qsTr("Quit"); onClicked: menu.backend.quit() }
        }
    }
}
