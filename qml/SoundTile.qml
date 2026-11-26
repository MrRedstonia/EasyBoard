import QtQuick
import QtQuick.Controls

// One sound on the board: square picture with margin, name + progress bar underneath.
// Click = play / stop. Right-click or the pencil = edit. Drag = rearrange (when allowed).
Item {
    id: tile

    property string sid: ""
    property bool showId: true
    property string name: ""
    property string image: ""
    property string hotkey: ""
    property string color: ""
    property bool looping: false
    property bool isPlaying: false
    property real progress: 0
    property bool draggable: true
    property Item dragParent: null
    property int visualIndex: 0
    property bool moved: false
    property bool selected: false
    property bool selectionActive: false   // some tile on the board is selected

    // a tile that grows under the mouse stays on top of its neighbors
    z: hover.hovered ? 2 : 0
    signal playRequested()
    signal selectRequested(int modifiers)
    signal editRequested()
    signal dropped()

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    readonly property bool hasColor: color !== ""
    // colors (and the theme's tile settings) come from the window: a theme may restyle each tile color
    readonly property var style: Window.window && Window.window.tileStyle ? Window.window.tileStyle(color)
        : { primary: hasColor ? color : ink(0.08), secondary: hasColor ? Qt.rgba(0, 0, 0, 0.16) : ink(0.07),
            text: hasColor ? "#ffffff" : palette.windowText, progress: hasColor ? "#ffffff" : palette.highlight }
    readonly property var themeTiles: Window.window && Window.window.themed ? Window.window.theme.tiles : null
    readonly property color cardColor: style.primary
    readonly property color textColor: style.text

    Drag.active: area.drag.active
    Drag.source: tile
    Drag.hotSpot.x: width / 2
    Drag.hotSpot.y: height / 2
    Drag.onActiveChanged: if (Drag.active) moved = true

    states: State {
        when: tile.Drag.active
        ParentChange { target: tile; parent: tile.dragParent }
        AnchorChanges {
            target: tile
            anchors.horizontalCenter: undefined
            anchors.verticalCenter: undefined
        }
    }

    Rectangle {
        id: card
        anchors.fill: parent
        radius: tile.themeTiles && tile.themeTiles.radius >= 0 ? tile.themeTiles.radius : 18
        color: tile.cardColor
        border.width: (tile.isPlaying || tile.selected) ? (Window.window && Window.window.focusEdge ? Window.window.focusEdge(3) : 3) : (Window.window && Window.window.edge ? Window.window.edge(1) : 1)
        border.color: tile.selected ? palette.highlight : (tile.isPlaying ? palette.highlight : (tile.style.border || tile.ink(0.14)))
        // a theme can make tiles grow a little under the mouse (<tiles hoverScale="1.04">)
        readonly property real hoverScale: tile.themeTiles ? tile.themeTiles.hoverScale : 1
        scale: area.pressed && !tile.Drag.active ? 0.97
             : tile.Drag.active ? 1.04
             : (hover.hovered && hoverScale > 1 ? hoverScale : 1)
        opacity: tile.Drag.active ? 0.92 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 120 } }
        // raised look (<depth shadow sheen>), and glass under the tile (<tiles glass="true">)
        GlassBackdrop { anchors.fill: parent; z: -1; radius: card.radius; tile: true }
        Shadow { z: -2 }
        // tiles get a lighter sheen than controls: see-through glass, not white cards
        Sheen { anchors.fill: parent; radius: card.radius; amount: 0.5 }

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            // Square picture with a margin around it, corners rounded (a theme can leave it out: <tiles pictures="false">)
            Rectangle {
                id: pic
                visible: !tile.themeTiles || tile.themeTiles.pictures
                width: parent.width
                height: visible ? width : 0
                radius: Math.max(0, card.radius - 6)
                color: tile.style.secondary

                RoundedImage {
                    id: rimg
                    anchors.fill: parent
                    radius: pic.radius
                    source: tile.image !== ""
                            ? "file://" + (tile.image.charAt(0) === "/" ? tile.image : "/" + tile.image)
                            : ""
                }
                // the glyph of a sound without a picture: the theme's text glyph or picture, else ♪
                readonly property real glyphOpacity: tile.themeTiles && tile.themeTiles.glyphOpacity >= 0 ? tile.themeTiles.glyphOpacity : 0.35
                readonly property real glyphSize: tile.themeTiles && tile.themeTiles.glyphSize > 0 ? tile.themeTiles.glyphSize : 56
                // a theme's own (maybe animated) glyph: <replace part="tileGlyph">
                readonly property string glyphPart: Window.window && Window.window.part ? Window.window.part("tileGlyph") : ""
                Loader {
                    id: glyphPartLoader
                    anchors.centerIn: parent
                    width: pic.glyphSize
                    height: pic.glyphSize
                    active: !rimg.ready && pic.glyphPart !== ""
                    source: pic.glyphPart
                    Binding { target: glyphPartLoader.item; property: "color"; value: tile.textColor; when: glyphPartLoader.status === Loader.Ready }
                    Binding { target: glyphPartLoader.item; property: "playing"; value: tile.isPlaying; when: glyphPartLoader.status === Loader.Ready }
                }
                Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    anchors.centerIn: parent
                    visible: !rimg.ready && pic.glyphPart === "" && !(tile.themeTiles && tile.themeTiles.glyphUrl !== "")
                    text: tile.themeTiles && tile.themeTiles.glyph !== "" ? tile.themeTiles.glyph : "♪"
                    font.pixelSize: pic.glyphSize
                    color: tile.textColor
                    opacity: pic.glyphOpacity
                }
                Image {
                    anchors.centerIn: parent
                    visible: !rimg.ready && pic.glyphPart === "" && tile.themeTiles !== null && tile.themeTiles.glyphUrl !== ""
                    source: visible ? tile.themeTiles.glyphUrl : ""
                    width: pic.glyphSize
                    height: pic.glyphSize
                    sourceSize: Qt.size(pic.glyphSize * 2, pic.glyphSize * 2)
                    fillMode: Image.PreserveAspectFit
                    opacity: pic.glyphOpacity
                }

                // ID chip (top-left; a theme can draw its own: <replace part="soundId">)
                readonly property string idPart: Window.window && Window.window.part ? Window.window.part("soundId") : ""
                Loader {
                    id: idPartLoader
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: 6
                    active: tile.showId && pic.idPart !== ""
                    source: pic.idPart
                    Binding { target: idPartLoader.item; property: "text"; value: tile.sid; when: idPartLoader.status === Loader.Ready }
                }
                Rectangle {
                    visible: tile.showId && pic.idPart === ""
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: 6
                    height: 20; radius: 10; width: idText.implicitWidth + 12
                    color: tile.style.chip || Qt.rgba(0, 0, 0, 0.6)
                    Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; id: idText; anchors.centerIn: parent; text: tile.sid; color: "white"; font.pixelSize: 11 }
                }
                // Loop + hotkey chips (bottom-left)
                Row {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: 6
                    spacing: 4
                    Rectangle {
                        visible: tile.looping
                        height: 20; radius: 10; width: 24
                        color: tile.style.chip || Qt.rgba(0, 0, 0, 0.6)
                        Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; anchors.centerIn: parent; text: "↻"; color: "white"; font.pixelSize: 12 }
                    }
                    Rectangle {
                        visible: tile.hotkey !== ""
                        height: 20; radius: 10; width: Math.min(hkText.implicitWidth + 12, pic.width - 44)
                        color: tile.style.chip || Qt.rgba(0, 0, 0, 0.6)
                        Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; id: hkText; anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6
                               verticalAlignment: Text.AlignVCenter; text: Window.window ? Window.window.prettyHotkey(tile.hotkey) : tile.hotkey; color: "white"
                               font.pixelSize: 11; elide: Text.ElideRight }
                    }
                }
            }

            // Up to two lines. (Never give the Text a fixed height shorter than two lines,
            // or Qt silently drops to one line and elides.)
            Item {
                width: parent.width
                height: titleMetrics.height * 2 + 2
                FontMetrics { id: titleMetrics; font: titleText.font }
                Rectangle {
                    anchors.centerIn: parent
                    width: Math.min(parent.width, titleText.contentWidth + 22)
                    height: titleText.contentHeight + 8
                    radius: 14
                    color: tile.style.label || Qt.rgba(0, 0, 0, 0.2)
                }
                Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    id: titleText
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 14
                    x: 7
                    text: tile.name
                    color: tile.textColor
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
            }

            // Progress bar (only filled while the sound plays; space is always reserved).
            // A theme can draw its own: <replace part="tileProgress">
            Item {
                id: trackBox
                width: parent.width
                height: 5
                readonly property string partUrl: Window.window && Window.window.part ? Window.window.part("tileProgress") : ""
                Loader {
                    id: progPart
                    anchors.fill: parent
                    active: trackBox.partUrl !== ""
                    source: trackBox.partUrl
                    opacity: tile.isPlaying ? 1 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                    Binding { target: progPart.item; property: "progress"; value: Math.max(0, Math.min(1, tile.progress)); when: progPart.status === Loader.Ready }
                    Binding { target: progPart.item; property: "color"; value: tile.style.progress; when: progPart.status === Loader.Ready }
                }
            Rectangle {
                id: track
                visible: trackBox.partUrl === ""
                width: parent.width
                height: 5
                radius: 2.5
                color: Qt.rgba(tile.textColor.r, tile.textColor.g, tile.textColor.b, 0.18)
                opacity: tile.isPlaying ? 1 : 0.0
                Behavior on opacity { NumberAnimation { duration: 150 } }

                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: Math.max(0, Math.min(1, tile.progress)) * parent.width
                    color: tile.style.progress
                    Behavior on width { NumberAnimation { duration: 100; easing.type: Easing.Linear } }
                }
            }
            }

        }

        // Edit pencil (top-right of the picture, appears on hover)
        Rectangle {
            id: pencil
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.rightMargin: 18
            anchors.topMargin: 12 + (tile.width - 24) - 6 - 30
            width: 30; height: 30; radius: 15
            color: Qt.rgba(0, 0, 0, 0.62)
            // a theme can leave the pencil out (<tiles editButton="false">): right-click still edits
            visible: !tile.themeTiles || tile.themeTiles.editButton
            opacity: (hover.hovered || pencilArea.containsMouse) && !tile.Drag.active ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 110 } }
            Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; anchors.centerIn: parent; text: "✎"; color: "white"; font.pixelSize: 15 }
            MouseArea {
                id: pencilArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tile.editRequested()
            }
        }
    }

    // Selection tick (top-left of the picture)
    Rectangle {
        id: tick
        x: tile.width - 18 - 26; y: 18
        width: 26; height: 26; radius: 13
        visible: !tile.Drag.active
        // a theme can keep it off on plain hover (<tiles selectButton="false">): it still shows while selecting
        opacity: (tile.selected || tile.selectionActive || (hover.hovered && (!tile.themeTiles || tile.themeTiles.selectButton))) ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 110 } }
        color: tile.selected ? palette.highlight : Qt.rgba(0, 0, 0, 0.55)
        border.width: 2
        border.color: "white"
        Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
            anchors.centerIn: parent
            visible: tile.selected
            text: "✓"
            color: palette.highlightedText
            font.pixelSize: 15
            font.bold: true
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: tile.selectRequested(Qt.ControlModifier)
        }
    }

    HoverHandler { id: hover }

    MouseArea {
        id: area
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        drag.target: tile.draggable ? tile : null
        drag.threshold: 8
        onClicked: function (ev) {
            if (ev.button === Qt.RightButton) tile.editRequested()
            else if (!tile.moved) tile.selectRequested(ev.modifiers)
        }
        onReleased: {
            if (tile.moved) tile.dropped()
            tile.moved = false
        }
    }
}
