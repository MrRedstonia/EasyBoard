import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Effects

// Themes page: pick a theme, add one from a zip file ("+"), open the themes folder.
// Themes are folders in <config>/themes (see THEMES.md).
Item {
    id: root
    property var backend
    property var themes: []
    property string current: ""
    signal themeChanged()

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }
    function reload() {
        if (!backend) return
        themes = JSON.parse(backend.themes())
        current = Window.window && Window.window.themed ? Window.window.theme.id : ""
    }
    function apply(id) {
        var err = backend.setTheme(id)
        if (err !== "") { if (Window.window) Window.window.toast(err); return }
        root.themeChanged()
        current = id
    }
    onVisibleChanged: if (visible) reload()
    Component.onCompleted: reload()

    EbFileDialog {
        backend: root.backend
        id: zipDialog
        title: qsTr("Choose a theme (.zip)")
        nameFilters: [qsTr("Theme files (*.zip)"), qsTr("All files (*)")]
        onAccepted: root.installZip(root.backend.urlToPath(selectedFile.toString()))
    }
    function installZip(path) {
        var r = JSON.parse(backend.installTheme(path))
        if (r.error !== "") { if (Window.window) Window.window.toast(r.error); return }
        reload()
        apply(r.id)
        if (Window.window) Window.window.toast(qsTr("Theme installed"))
    }

    // a theme card: a small picture of its colors (or its preview image), name and author
    component ThemeCard: Rectangle {
        id: card
        property string themeId: ""
        property string name: ""
        property string author: ""
        property string description: ""
        property string windowColor: ""
        property string accent: ""
        property string textColor: ""
        property string preview: ""
        property bool removable: false
        readonly property bool selected: root.current === themeId
        width: root.cardW
        height: swatch.height + 76
        radius: 14
        color: cardMouse.containsMouse ? root.ink(0.10) : root.ink(0.05)
        border.width: selected ? 2 : 1
        border.color: selected ? palette.highlight : root.ink(0.14)

        // the picture: the theme's own thumbnail, or a little sketch of the app in its colors.
        // Everything inside is cut to the rounded corners.
        Item {
            id: swatch
            x: 10; y: 10
            width: parent.width - 20
            height: Math.round(width * 0.5)
            readonly property real radius: 10
            Item {
                id: swatchContent
                anchors.fill: parent
                layer.enabled: true
                layer.effect: MultiEffect { maskEnabled: true; maskSource: swatchMask }
                Rectangle { anchors.fill: parent; color: card.windowColor !== "" ? card.windowColor : palette.window }
                Image {
                    anchors.fill: parent
                    visible: card.preview !== ""
                    source: card.preview
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    mipmap: true
                }
                Item {
                    id: sketch
                    anchors.fill: parent
                    visible: card.preview === ""
                    // a theme without its own accent uses the system's
                    readonly property color accentC: card.accent !== "" ? card.accent
                        : (Window.window && Window.window.systemAccent ? Window.window.systemAccent : palette.highlight)
                    readonly property color textC: card.textColor !== "" ? card.textColor : palette.windowText
                    Rectangle { x: 0; y: 0; width: Math.round(parent.width * 0.11); height: parent.height; color: Qt.rgba(0, 0, 0, 0.18) }
                    Rectangle { x: Math.round(parent.width * 0.03); y: 10; width: 10; height: 10; radius: 3; color: parent.accentC }
                    Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                        x: Math.round(parent.width * 0.16); y: 8
                        text: "Aa"
                        font.pixelSize: Math.round(swatch.height * 0.2)
                        color: parent.textC
                    }
                    Grid {
                        x: Math.round(parent.width * 0.16); y: Math.round(parent.height * 0.42)
                        columns: 4; spacing: 6
                        Repeater {
                            model: 8
                            Rectangle {
                                required property int index
                                width: Math.round((swatch.width * 0.8 - 18) / 4); height: Math.round(swatch.height * 0.2); radius: 5
                                color: index === 2 ? sketch.accentC : Qt.rgba(0.5, 0.5, 0.5, 0.25)
                            }
                        }
                    }
                }
            }
            Item {
                id: swatchMask
                anchors.fill: parent
                visible: false
                layer.enabled: true
                Rectangle { anchors.fill: parent; radius: swatch.radius; color: "black" }
            }
            Rectangle {
                anchors.fill: parent
                radius: swatch.radius
                color: "transparent"
                border.width: 1
                border.color: root.ink(0.12)
            }
        }
        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
            x: 12; y: swatch.y + swatch.height + 8
            width: parent.width - 24 - (removeBtn.visible ? 34 : 0)
            text: card.name
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }
        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
            x: 12; y: swatch.y + swatch.height + 30
            width: parent.width - 24 - (removeBtn.visible ? 34 : 0)
            text: card.author !== "" ? qsTr("by %1").arg(card.author) : ""
            font.pixelSize: 12
            opacity: 0.6
            elide: Text.ElideRight
        }
        MouseArea {
            id: cardMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (!card.selected) root.apply(card.themeId)
        }
        ToolTip.visible: cardMouse.containsMouse && card.description !== ""
        ToolTip.delay: 600
        ToolTip.text: card.description
        // remove a theme you added (built-in ones stay)
        Rectangle {
            id: removeBtn
            visible: card.removable
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 10
            width: 28; height: 28; radius: 7
            color: rmMouse.containsMouse ? Qt.rgba(0.9, 0.28, 0.3, 0.28) : root.ink(0.07)
            border.width: 1
            border.color: root.ink(0.14)
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; anchors.centerIn: parent; text: "✕"; font.pixelSize: 12 }
            MouseArea {
                id: rmMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    var wasCurrent = card.selected
                    var err = root.backend.removeTheme(card.themeId)
                    if (err !== "") { if (Window.window) Window.window.toast(err); return }
                    if (wasCurrent) root.themeChanged()
                    root.reload()
                }
            }
            ToolTip.visible: rmMouse.containsMouse
            ToolTip.delay: 500
            ToolTip.text: qsTr("Remove theme")
        }
    }

    // laid out like the Sound library: full width with the same margin left and right
    readonly property real gridW: col.width
    readonly property int columns: Math.max(1, Math.floor((gridW + 12) / (240 + 12)))
    readonly property real cardW: Math.floor((gridW - (columns - 1) * 12) / columns)

    EbWheel { anchors.fill: parent; flick: scroll }
    Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        interactive: false
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: EbScrollBar {}

        ColumnLayout {
            id: col
            readonly property bool scrollable: scroll.contentHeight > scroll.height + 0.5
            x: 32
            width: scroll.width - 64 - (scrollable ? 12 : 0)
            spacing: 14

            Item { Layout.preferredHeight: 14 }
            RowLayout {
                Layout.fillWidth: true
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Themes"); font.pixelSize: 30; font.weight: Font.Light; Layout.fillWidth: true }
                Rectangle {
                    id: addButton
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    Layout.alignment: Qt.AlignVCenter
                    radius: 9
                    color: Window.window && Window.window.controlFill ? Window.window.controlFill(addMouse.pressed ? 2 : addMouse.containsMouse ? 1 : 0) : root.ink(0.08)
                    border.width: 1
                    border.color: root.ink(0.14)
                    // drawn rather than a "+" character: a font's "+" sits a little off center
                    Rectangle { anchors.centerIn: parent; width: 14; height: 2; radius: 1; color: palette.windowText }
                    Rectangle { anchors.centerIn: parent; width: 2; height: 14; radius: 1; color: palette.windowText }
                    MouseArea {
                        id: addMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: zipDialog.openDialog()
                    }
                    ToolTip.visible: addMouse.containsMouse
                    ToolTip.delay: 500
                    ToolTip.text: qsTr("Add a theme (.zip)")
                }
            }
            Label { 
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.6
                font.pixelSize: 12
                textFormat: Text.StyledText
                // (a near-white accent would vanish in the glow below: then links use the text color)
                linkColor: palette.highlight.hslLightness > 0.85 ? palette.windowText : palette.highlight
                // over a picture or an animated background: a soft shadow keeps it readable
                layer.enabled: !!(Window.window && Window.window.wallpaperBehind)
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: palette.windowText.hslLightness > 0.5 ? "black" : "white"
                    shadowOpacity: 0.9
                    shadowBlur: 0.5
                    shadowVerticalOffset: 0
                    shadowHorizontalOffset: 0
                }
                text: qsTr("Click a theme to use it. Add one with + (a .zip file, or drop it here), or put its folder in the <a href=\"folder\">themes folder</a>. <a href=\"docs\">How to make a theme</a>")
                onLinkActivated: function (l) {
                    Qt.openUrlExternally(l === "docs" ? "https://github.com/MrRedstonia/EasyBoard/blob/main/THEMES.md"
                                                     : root.backend.themesFolderUrl())
                }
            }

            Flow {
                Layout.fillWidth: true
                spacing: 12
                ThemeCard {
                    // EasyBoard's own look: always its own colors, not the active theme's
                    themeId: ""
                    name: qsTr("Default")
                    author: "EasyBoard"
                    description: qsTr("EasyBoard's own look: follows your system, with the options in Settings > Appearance.")
                    windowColor: Window.window ? Window.window.defaultLook.window : ""
                    accent: Window.window ? Window.window.defaultLook.accent : ""
                    textColor: Window.window ? Window.window.defaultLook.text : ""
                }
                Repeater {
                    model: root.themes
                    ThemeCard {
                        required property var modelData
                        themeId: modelData.id
                        name: modelData.name
                        author: modelData.author
                        description: modelData.description
                        windowColor: modelData.window
                        accent: modelData.accent
                        textColor: modelData.text
                        preview: modelData.preview
                        removable: !modelData.builtin
                    }
                }
            }
            Item { Layout.preferredHeight: 24 }
        }
    }

    // theme zip files can be dropped anywhere on the page
    DropArea {
        anchors.fill: parent
        onEntered: function (drag) {
            drag.accepted = drag.hasUrls && /\.zip$/i.test(drag.urls[0].toString())
        }
        onDropped: function (drop) {
            if (drop.hasUrls) root.installZip(root.backend.urlToPath(drop.urls[0].toString()))
        }
    }
}
