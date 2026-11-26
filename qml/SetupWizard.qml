import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// First-run page. Mirrors the concept art: big title, one input dropdown,
// a "get started" button, concentric rings in the top-left corner.
Item {
    id: root
    property var backend
    signal finished()

    property var inputList: []
    property var virtualList: []
    property bool needsVirtual: backend ? backend.needsVirtualDevice() : false

    // Windows / macOS: find VB-Cable ourselves; only ask when it can't be found.
    readonly property string autoVirtual: {
        for (var i = 0; i < virtualList.length; i++)
            if (/cable input|cable in 16|vb-cable/i.test(virtualList[i])) return virtualList[i]
        return ""
    }
    readonly property bool askVirtual: needsVirtual && autoVirtual === ""

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    Component.onCompleted: {
        if (!backend) return
        inputList = [{ id: "", label: qsTr("No input") }].concat(JSON.parse(backend.inputs()))
        virtualList = JSON.parse(backend.virtualCandidates())
        inputBox.currentIndex = -1
        virtualBox.currentIndex = -1
    }

    // Decorative rings
    Canvas {
        id: rings
        anchors.fill: parent
        // stronger in light mode, where faint dark-on-white lines can't be seen
        readonly property bool darkTheme: palette.window.hslLightness < 0.5
        readonly property color ringColor: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, darkTheme ? 0.08 : 0.16)
        onRingColorChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.strokeStyle = rings.ringColor
            ctx.lineWidth = 3
            var radii = [0.07, 0.16, 0.25, 0.36]
            for (var i = 0; i < radii.length; i++) {
                ctx.beginPath()
                ctx.arc(0.03 * width, 0.04 * height, radii[i] * width, 0, Math.PI * 2)
                ctx.stroke()
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 40
        spacing: 0

        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("EasyBoard Setup Wizard")
            font.pixelSize: Math.max(28, Math.min(64, root.width / 18))
            font.weight: Font.Light
        }

        Item { Layout.fillHeight: true }

        ColumnLayout {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 420
            spacing: 14

            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.alignment: Qt.AlignHCenter
                visible: root.inputList.length <= 1
                text: qsTr("No microphones were found.")
                opacity: 0.55
            }

            EbCombo {
                id: inputBox
                arrowSize: 24
                Layout.fillWidth: true
                model: root.inputList
                textRole: "label"
                valueRole: "id"
                currentIndex: -1
                displayText: currentIndex < 0 ? qsTr("Please Select Your Input") : currentText
            }

            EbCombo {
                id: virtualBox
                arrowSize: 24
                visible: root.askVirtual
                Layout.fillWidth: true
                model: root.virtualList
                currentIndex: -1
                displayText: currentIndex < 0 ? qsTr("Select your virtual cable output") : currentText
            }

            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                visible: root.needsVirtual
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                opacity: 0.55
                font.pixelSize: 12
                textFormat: Text.StyledText
                linkColor: palette.highlight
                onLinkActivated: function (l) { Qt.openUrlExternally(l) }
                HoverHandler { cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor }
                text: root.askVirtual
                    ? (Qt.platform.os === "windows"
                        ? qsTr("VB-Cable wasn't found. Download it <a href=\"https://vb-audio.com/Cable/\">here</a> (vb-audio.com/Cable), install it (then restart your PC) and restart EasyBoard.")
                        : qsTr("VB-Cable wasn't found. Download it <a href=\"https://vb-audio.com/Cable/\">here</a> (vb-audio.com/Cable), install it and restart EasyBoard."))
                    : (Qt.platform.os === "windows"
                        ? qsTr("EasyBoard will use VB-Cable. In Discord, OBS and other apps (or as your system default input), pick \"CABLE Output (VB-Audio Virtual Cable)\" as the microphone.")
                        : qsTr("EasyBoard will use VB-Cable. In your apps, pick \"VB-Cable\" as the microphone."))
            }
        }

        Item { Layout.fillHeight: true }

        EbButton {
            id: go
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 240
            Layout.preferredHeight: 60
            Layout.bottomMargin: 30
            accent: inputBox.currentIndex > 0   // "skip" stays gray
            enabled: !root.needsVirtual || root.autoVirtual !== "" || virtualBox.currentIndex >= 0
            text: inputBox.currentIndex > 0 ? qsTr("get started") : qsTr("skip")
            font.pixelSize: 22
            // lowercase text: center the x-height band (not the line box) in the button
            FontMetrics { id: fm; font: go.font }
            contentItem: Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                text: go.text
                font: go.font
                color: go.accent ? palette.highlightedText : palette.windowText
                opacity: go.enabled ? 1 : 0.4
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                topPadding: Math.max(0, fm.descent - fm.ascent + fm.xHeight)
                bottomPadding: Math.max(0, fm.ascent - fm.descent - fm.xHeight)
            }
            onClicked: {
                backend.finishSetup(inputBox.currentIndex > 0 ? inputBox.currentValue : "", true,
                                    root.needsVirtual ? (root.autoVirtual !== "" ? root.autoVirtual : virtualBox.currentText) : "")
                root.finished()
            }
        }
    }
}
