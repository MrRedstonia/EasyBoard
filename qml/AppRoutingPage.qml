import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "App routing" page: apps whose audio is mixed into EasyBoard Mic (Linux) or the virtual cable
// (Windows/macOS). "+" lists the apps playing audio right now; each routed app can be switched
// off or removed.
Item {
    id: root
    // menus fade in and out (<controls menuAnimation="true">); read here, Transitions can't see the window
    readonly property bool menuAnim: !!(Window.window && Window.window.menuAnimation)
    property var backend
    property var routes: []
    property var playing: []
    readonly property bool supported: backend ? backend.appRoutingSupported() : false
    onVisibleChanged: if (visible) reload(); else pop.close()

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }
    function reload() { if (backend) routes = JSON.parse(backend.appRoutes()) }
    function reloadPlaying() { if (backend) playing = JSON.parse(backend.playingApps()) }
    Component.onCompleted: reload()

    // Rounded square with the app's icon, or its first letter when it has none.
    component AppIcon: Rectangle {
        property string source: ""
        property string name: ""
        implicitWidth: 32
        implicitHeight: 32
        radius: 8
        color: source === "" ? root.ink(0.10) : "transparent"
        Image {
            anchors.fill: parent
            visible: parent.source !== ""
            source: parent.source
            sourceSize: Qt.size(64, 64)
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
        }
        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
            anchors.centerIn: parent
            visible: parent.source === ""
            text: parent.name.length > 0 ? parent.name.charAt(0).toUpperCase() : "?"
            font.pixelSize: 15
            font.weight: Font.DemiBold
            opacity: 0.7
        }
    }

    // small square button with a text glyph
    component GlyphButton: Rectangle {
        id: gb
        property string glyph: ""
        property string tip: ""
        property bool danger: false
        signal clicked()
        implicitWidth: 32
        implicitHeight: 32
        // like every other button: the theme's radius, glass, depth and grow / sink animation
        radius: Window.window && Window.window.controlRadius ? Window.window.controlRadius(32, 8) : 8
        GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius; control: true }
        Shadow { z: -2; opacity: strength * 0.6 }
        Sheen { anchors.fill: parent; radius: parent.radius }
        scale: Window.window && Window.window.controlScale ? Window.window.controlScale(gbMouse.containsMouse, gbMouse.pressed, width) : 1
        Behavior on scale { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
        // same fill as every other button
        color: gb.danger && gbMouse.containsMouse && !(Window.window && Window.window.themed && Window.window.theme.controls.glass) ? Qt.rgba(0.9, 0.28, 0.3, 0.28)
             : Window.window && Window.window.controlFill ? Window.window.controlFill(gbMouse.pressed ? 2 : gbMouse.containsMouse ? 1 : 0)
             : (gbMouse.containsMouse ? root.ink(0.13) : root.ink(0.08))
        border.width: (Window.window && Window.window.edge ? Window.window.edge(1) : 1)
        border.color: Window.window && Window.window.themeColor ? Window.window.themeColor("controlBorder", root.ink(0.14)) : root.ink(0.14)
        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; anchors.centerIn: parent; text: gb.glyph; font.pixelSize: gb.glyph === "+" ? 20 : 14; color: Window.window && Window.window.glyphColor ? Window.window.glyphColor(palette.windowText) : palette.windowText }
        MouseArea {
            id: gbMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: gb.clicked()
        }
        ToolTip.visible: gb.tip !== "" && gbMouse.containsMouse && !(Window.window && Window.window.themed && !Window.window.theme.controls.tooltips)
        ToolTip.delay: 500
        ToolTip.text: gb.tip
    }

    // Same placement as the Sound editor / Sound library / Settings pages: 32 px in, title 28 px down.
    ColumnLayout {
        // at most 920 px from the left, unless the theme says otherwise (<layout pageWidth pageAlign>)
        width: Window.window && Window.window.pageWidth ? Window.window.pageWidth(root.width - 64) : Math.min(root.width - 64, 920)
        x: 32 + (Window.window && Window.window.pageOffset ? Window.window.pageOffset(root.width - 64, width) : 0)
        y: 0
        height: root.height - 18                // bottom padding as on the Soundboard
        spacing: 14

        Item { Layout.preferredHeight: 14 }
        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("App routing"); font.pixelSize: 30; font.weight: Font.Light }

        Rectangle {
            id: box
            Layout.fillWidth: true
            Layout.fillHeight: true
            // always the look of the sound editor's waveform box (see-through)
            GlassBackdrop { anchors.fill: parent; z: -1; radius: 12 }
            Shadow { z: -2 }
            radius: 12
            color: Window.window && Window.window.tintOn ? Window.window.tintFill(0) : root.ink(0.06)
            border.width: (Window.window && Window.window.edge ? Window.window.edge(1) : 1)
            border.color: root.ink(0.14)

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        opacity: 0.6
                        font.pixelSize: 12
                        text: !root.supported
                            ? (Qt.platform.os === "osx" ? qsTr("App routing needs macOS 14.2 or newer.")
                                                        : qsTr("App routing needs Windows 10 version 2004 or newer."))
                            : Qt.platform.os === "linux"
                                ? qsTr("Sound from these apps is also sent through EasyBoard Mic. You still hear them as usual.")
                                : qsTr("Sound from these apps is also sent through the virtual cable. You still hear them as usual.")
                    }
                    GlyphButton {
                        id: addButton
                        glyph: "+"
                        tip: qsTr("Add an app")
                        visible: root.supported
                        onClicked: {
                            if (pop.opened) { pop.close(); return }
                            root.reloadPlaying()
                            pop.open()
                        }

                        // The menu opens from this invisible, never-moving stand-in for the control at its normal size
                        // (it undoes the control's own scale), so the control may grow and sink while the menu stays put.
                        Item {
                            id: popupAnchor
                            anchors.fill: parent
                            scale: addButton.scale > 0 ? 1 / addButton.scale : 1
                        }
                        LiquidPopup {
                            id: pop
                            animated: root.menuAnim
                            parent: popupAnchor
                            y: addButton.height + 8
                            x: addButton.width - width
                            width: 300
                            height: Math.min(360, implicitHeight)   // exactly the content; scrolls past 360
                            padding: 10
                            focus: true
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                            background: Rectangle {
                                radius: 12
                                color: Window.window && Window.window.themeColor ? Window.window.themeColor("menu", Window.window.popupFill(Qt.tint(Window.window.opaqueWindow, root.ink(0.08)))) : Qt.tint(palette.window, root.ink(0.08))
                                GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius }
                                Shadow { z: -2 }
                                Sheen { anchors.fill: parent; radius: parent.radius; amount: 0.3 }
                                border.width: 1
                                border.color: root.ink(0.16)
                            }
                            // apps start and stop playing: keep the list current while it is open
                            Timer { interval: 1500; repeat: true; running: pop.opened; onTriggered: root.reloadPlaying() }
                            contentItem: ColumnLayout {
                                spacing: 8
                                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Apps playing audio"); font.weight: Font.DemiBold; opacity: 0.75 }
                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.preferredHeight: root.playing.length > 0 ? root.playing.length * 44 : 88
                                    ListView {
                                        id: playList
                                        anchors.fill: parent
                                        clip: true
                                        interactive: false
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: root.playing
                                        ScrollBar.vertical: EbScrollBar {}
                                        delegate: Rectangle {
                                            id: prow
                                            required property var modelData
                                            // room for the scroll bar only when it is shown
                                            width: playList.width - (playList.contentHeight > playList.height + 0.5 ? 12 : 0)
                                            height: 44
                                            radius: 8
                                            color: prowMouse.containsMouse && !modelData.added ? root.ink(0.10) : "transparent"
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 6
                                                anchors.rightMargin: 8
                                                spacing: 10
                                                AppIcon { source: prow.modelData.icon; name: prow.modelData.name; opacity: prow.modelData.added ? 0.5 : 1 }
                                                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                                                    Layout.fillWidth: true
                                                    text: prow.modelData.name
                                                    elide: Text.ElideRight
                                                    opacity: prow.modelData.added ? 0.5 : 1
                                                }
                                                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; visible: prow.modelData.added; text: qsTr("Added"); opacity: 0.5; font.pixelSize: 12 }
                                            }
                                            MouseArea {
                                                id: prowMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                enabled: !prow.modelData.added
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    root.backend.addAppRoute(prow.modelData.key, prow.modelData.name, prow.modelData.iconSpec)
                                                    pop.close()
                                                    root.reload()
                                                }
                                            }
                                        }
                                    }
                                    EbWheel { anchors.fill: parent; flick: playList; rowHeight: 44; rowsPerNotch: 1.5 }
                                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                                        anchors.fill: parent
                                        visible: root.playing.length === 0
                                        wrapMode: Text.Wrap
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        opacity: 0.5
                                        text: qsTr("No apps are playing audio right now. Start playing something, it shows up here.")
                                    }
                                }
                            }
                        }
                    }
                }

                // the routed apps; scrolls inside the box when there are many
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    ListView {
                        id: routeList
                        anchors.fill: parent
                        clip: true
                        interactive: false
                        spacing: 8
                        boundsBehavior: Flickable.StopAtBounds
                        model: root.routes
                        ScrollBar.vertical: EbScrollBar {}
                        delegate: Rectangle {
                            id: rrow
                            required property var modelData
                            width: routeList.width - (routeList.contentHeight > routeList.height ? 12 : 0)
                            height: 52
                            radius: 10
                            color: root.ink(0.05)
                            border.width: 1
                            border.color: root.ink(0.10)
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10
                                spacing: 12
                                AppIcon {
                                    source: rrow.modelData.icon
                                    name: rrow.modelData.name
                                    opacity: rrow.modelData.enabled ? 1 : 0.45
                                }
                                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                                    Layout.fillWidth: true
                                    text: rrow.modelData.name
                                    elide: Text.ElideRight
                                    opacity: rrow.modelData.enabled ? 1 : 0.45
                                }
                                EbSwitch {
                                    checked: rrow.modelData.enabled
                                    spacing: 0
                                    onToggled: { root.backend.setAppRouteEnabled(rrow.modelData.key, checked); root.reload() }
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 500
                                    ToolTip.text: checked ? qsTr("Routed: click to stop sending this app") : qsTr("Off: click to send this app again")
                                }
                                GlyphButton {
                                    glyph: "✕"
                                    danger: true
                                    tip: qsTr("Remove")
                                    onClicked: { root.backend.removeAppRoute(rrow.modelData.key); root.reload() }
                                }
                            }
                        }
                    }
                    EbWheel { anchors.fill: parent; flick: routeList; rowHeight: 60; rowsPerNotch: 1.5 }
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                        anchors.centerIn: parent
                        visible: root.supported && root.routes.length === 0
                        opacity: 0.45
                        text: qsTr("No apps yet. Click + to add one.")
                    }
                }
            }
        }
    }
}
