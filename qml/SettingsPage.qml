import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

Item {
    id: root
    property var backend
    property var inputList: []
    // the list always starts with "No input" (empty id)
    function withNone(raw) { return [{ id: "", label: qsTr("No input") }].concat(JSON.parse(raw)) }
    property var virtualList: []
    property bool needsVirtual: backend ? backend.needsVirtualDevice() : false
    property bool loading: false
    component MuteButton: Rectangle {
        id: mb
        property int which: 0
        Layout.preferredWidth: 32
        Layout.preferredHeight: 32
        radius: Window.window && Window.window.controlRadius ? Window.window.controlRadius(32, 8) : 8
        GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius; control: true }
        scale: Window.window && Window.window.controlScale ? Window.window.controlScale(mbMouse.containsMouse, mbMouse.pressed, width) : 1
        Behavior on scale { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
        Shadow { z: -2; lift: 3; opacity: strength * 0.6 }
        Sheen { anchors.fill: parent; radius: parent.radius }
        color: Window.window && Window.window.controlFill ? Window.window.controlFill(mbMouse.pressed ? 2 : mbMouse.containsMouse ? 1 : 0)
             : (mbMouse.containsMouse ? root.ink(0.13) : root.ink(0.08))
        border.width: (Window.window && Window.window.edge ? Window.window.edge(1) : 1)
        border.color: root.ink(0.14)
        Image {
            anchors.centerIn: parent
            width: 18; height: 18
            sourceSize: Qt.size(36, 36)
            source: root.backend ? root.backend.iconUrl(root.muted[mb.which] ? "muted" : "speaker", String(palette.windowText)) : ""
        }
        MouseArea {
            id: mbMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.backend.toggleMute(["personal", "sink", "mic"][mb.which])
        }
        ToolTip.visible: mbMouse.containsMouse
        ToolTip.delay: 500
        ToolTip.text: root.muted[mb.which] ? qsTr("Unmute") : qsTr("Mute")
    }
    readonly property var muted: Window.window ? Window.window.muted : [false, false, false]
    property bool checking: false
    property string updateText: ""

    function showUpdate(raw) {
        if (!raw) return
        var r = JSON.parse(raw)
        if (r.state === "available")
            updateText = qsTr("Version %1 is available (you have %2). <a href=\"%3\">Download</a>").arg(r.latest).arg(r.current).arg(r.url)
        else if (r.state === "uptodate")
            updateText = r.message ? r.message : qsTr("You're up to date (version %1).").arg(r.current)
        else
            updateText = r.message
    }
    Timer {
        interval: 300; repeat: true; running: root.checking
        onTriggered: {
            var r = root.backend.updateResult()
            if (r !== "") { root.checking = false; root.showUpdate(r) }
        }
    }
    readonly property string autoVirtual: {
        for (var i = 0; i < virtualList.length; i++)
            if (/cable input|cable in 16|vb-cable/i.test(virtualList[i])) return virtualList[i]
        return ""
    }
    readonly property bool askVirtual: needsVirtual && autoVirtual === ""

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    property string lastInputsRaw: ""
    // the device lists come from a cache at once; a moment later they are checked again in case a
    // microphone was plugged in or removed
    Timer {
        id: devTimer
        interval: 1500
        repeat: true
        running: root.visible   // keeps checking while the page stays open
        onTriggered: {
            if (inputBox.popup.visible || virtualBox.popup.visible) return   // don't pull the list from under an open menu
            var raw = backend.inputs()
            if (raw === root.lastInputsRaw) return
            root.lastInputsRaw = raw
            var cur = inputBox.currentIndex >= 0 ? root.inputList[inputBox.currentIndex].id : ""
            var curV = virtualBox.currentIndex >= 0 ? root.virtualList[virtualBox.currentIndex] : ""
            root.loading = true
            root.inputList = root.withNone(raw)
            root.virtualList = JSON.parse(backend.virtualCandidates())
            inputBox.currentIndex = -1
            for (var i = 0; i < root.inputList.length; i++) if (root.inputList[i].id === cur) inputBox.currentIndex = i
            virtualBox.currentIndex = root.virtualList.indexOf(curV)
            root.loading = false
        }
    }
    function refresh() {
        if (!backend) return
        loading = true
        lastInputsRaw = backend.inputs()
        inputList = withNone(lastInputsRaw)
        virtualList = JSON.parse(backend.virtualCandidates())
        devTimer.restart()
        var s = JSON.parse(backend.settings())
        inputBox.currentIndex = -1
        for (var i = 0; i < inputList.length; i++)
            if (inputList[i].id === s.input) inputBox.currentIndex = i
        virtualBox.currentIndex = virtualList.indexOf(s.virtualDevice)
        localSlider.value = s.volumeLocal
        virtualSlider.value = s.volumeVirtual
        micSlider.value = s.volumeMic
        stopHk.value = s.hotkeyStopAll
        loopHk.value = s.hotkeyLoopAll
        mutePersonalHk.value = s.hotkeyMutePersonal
        muteSinkHk.value = s.hotkeyMuteSink
        muteMicHk.value = s.hotkeyMuteMic
        launchBox.checked = s.launchOnStartup
        minimizedBox.checked = s.startMinimized
        trayBox.checked = s.closeToTray
        updBox.checked = s.checkUpdates
        followBox.checked = s.themeFollow
        trayFollowBox.checked = s.trayFollow
        trayThemeBox.currentIndex = s.trayDark ? 0 : 1
        themeBox.currentIndex = s.themeDark ? 0 : 1
        tintBox.checked = s.tint
        idsBox.checked = s.showIds
        wpBox.checked = s.wallpaperOn
        wallpaperSet = s.wallpaperSet
        wpMode = s.wallpaperMode
        wpShadow.checked = s.wallpaperTextShadow
        wpBlur.value = s.wallpaperBlur
        wpOpacity.value = s.wallpaperOpacity
        wpBright.value = s.wallpaperBrightness
        showUpdate(backend.updateResult())
        loading = false
    }

    function apply() {
        if (loading || !backend) return
        backend.applySettings(
            inputBox.currentIndex >= 0 ? inputList[inputBox.currentIndex].id : "",
            true,
            virtualBox.currentIndex >= 0 ? virtualList[virtualBox.currentIndex] : "",
            localSlider.value, virtualSlider.value)
    }

    // ---- background picture
    // a theme decides the light/dark look, the accent tint and the background itself
    readonly property bool themed: Window.window ? Window.window.themed : false
    property bool wallpaperSet: false
    property string wpMode: "board"      // "board" | "behind" | "all"
    // the background picture's preview, choices and sliders all share this width
    readonly property int wpWidth: 320
    property bool fetchingWallpaper: false
    function isImageFile(p) { return /\.(png|jpe?g|webp|avif|heic|heif|bmp|gif|svg)$/i.test(p) }
    function isWebLink(u) { return /^https?:\/\//i.test(u) }
    function applyWallpaper() {
        if (loading || !backend) return
        backend.setWallpaperOptions(wpBox.checked, wpMode, wpBlur.value, wpOpacity.value, wpBright.value, wpShadow.checked)
    }
    function useWallpaper(path) {
        var err = backend.setWallpaperFile(path)
        if (err !== "") { if (Window.window) Window.window.toast(err); return }
        wallpaperSet = true
        applyWallpaper()
    }
    // a picture dropped as a web link is downloaded first; one from disk is used as it is, or
    // converted first when it's in a format Qt can't show (WebP, AVIF, HEIC...)
    function fetchWallpaper(u) {
        fetchingWallpaper = true
        if (isWebLink(u)) backend.imageFromUrl(u)
        else backend.prepareImage(u)
        wpFetchTimer.start()
    }
    Timer {
        id: wpFetchTimer
        interval: 150
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var r = JSON.parse(root.backend.imageFetchState())
            if (r.state === "loading") return
            stop()
            root.fetchingWallpaper = false
            if (r.state === "done") root.useWallpaper(r.path)
            else if (r.state === "error" && Window.window) Window.window.toast(r.error)
        }
    }
    EbFileDialog {
        backend: root.backend
        id: wpDialog
        title: qsTr("Choose a background picture")
        nameFilters: [qsTr("Pictures (*.png *.jpg *.jpeg *.webp *.avif *.heic *.heif *.bmp *.gif *.svg)"), qsTr("All files (*)")]
        onAccepted: root.fetchWallpaper(root.backend.urlToPath(selectedFile.toString()))
    }

    // ---- release notes (Markdown from GitHub, or the copy shipped with the app)
    Popup {
        id: notesPopup
        property string notes: ""
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(680, parent ? parent.width - 80 : 680)
        height: parent ? parent.height - 120 : 600
        modal: true
        focus: true
        padding: 24
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.5) }
        background: Rectangle {
            radius: 18
            color: Window.window && Window.window.popupFill ? Window.window.popupFill(Qt.tint(Window.window.opaqueWindow, root.ink(0.05))) : Qt.tint(palette.window, root.ink(0.05))
            border.width: 1
            border.color: root.ink(0.16)
        }
        contentItem: ColumnLayout {
            spacing: 12
            RowLayout {
                Layout.fillWidth: true
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Release notes"); font.pixelSize: 20; font.weight: Font.DemiBold; Layout.fillWidth: true }
                EbButton { text: qsTr("Close"); implicitHeight: 34; onClicked: notesPopup.close() }
            }
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Flickable {
                    id: notesFlick
                    anchors.fill: parent
                    clip: true
                    contentWidth: width
                    contentHeight: notesText.implicitHeight
                    interactive: false
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: EbScrollBar {}
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                        id: notesText
                        width: notesFlick.width - 16
                        wrapMode: Text.Wrap
                        textFormat: Text.MarkdownText
                        text: notesPopup.notes
                        linkColor: palette.highlight
                        onLinkActivated: function (l) { Qt.openUrlExternally(l) }
                        HoverHandler { cursorShape: notesText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor }
                    }
                }
                EbWheel { anchors.fill: parent; flick: notesFlick }
            }
        }
    }

    function applyAppearance() {
        if (loading || !backend) return
        backend.setAppearance(followBox.checked, themeBox.currentIndex === 0, trayFollowBox.checked, trayThemeBox.currentIndex === 0, tintBox.checked, idsBox.checked)
    }

    // Re-reads just the three volumes (used when they were changed from the command line).
    function refreshVolumes() {
        if (!backend) return
        var s = JSON.parse(backend.settings())
        loading = true
        localSlider.value = s.volumeLocal
        virtualSlider.value = s.volumeVirtual
        micSlider.value = s.volumeMic
        loading = false
    }

    function applyHotkeys() {
        if (loading || !backend) return
        backend.setAppHotkeys(stopHk.value, loopHk.value, mutePersonalHk.value, muteSinkHk.value, muteMicHk.value)
    }

    function applyBehavior() {
        if (loading || !backend) return
        backend.setBehavior(launchBox.checked, minimizedBox.checked, trayBox.checked)
    }

    Component.onCompleted: refresh()

    EbWheel { anchors.fill: parent; flick: scroll }

    Flickable {
        id: scroll
        anchors.fill: parent
        readonly property real availableWidth: width
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        interactive: false          // wheel + scroll bar only, no click-and-drag scrolling
        boundsBehavior: Flickable.StopAtBounds
        boundsMovement: Flickable.StopAtBounds
        rebound: Transition { NumberAnimation { properties: "x,y"; duration: 0 } }
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: EbScrollBar {}

        ColumnLayout {
            id: col
            x: 32
            width: Math.min(scroll.availableWidth - 64, 620)
            spacing: 14

            Item { Layout.preferredHeight: 14 }

            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Settings"); font.pixelSize: 30; font.weight: Font.Light }

            // -------- volumes
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Volumes"); font.pixelSize: 17; font.weight: Font.DemiBold; Layout.topMargin: 8 }

            RowLayout {
                Layout.fillWidth: true
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Personal volume"); Layout.preferredWidth: 210 }
                EbSlider { id: localSlider; Layout.fillWidth: true; enabled: !root.muted[0]; from: 0; to: 1.5; value: 1; onMoved: root.apply() }
                MuteButton { which: 0 }
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: Math.round(localSlider.value * 100) + "%"; opacity: root.muted[0] ? 0.4 : 1; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
            }
            RowLayout {
                Layout.fillWidth: true
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    text: Qt.platform.os === "linux" ? qsTr("EasyBoard Sink volume") : qsTr("Soundboard volume")
                    Layout.preferredWidth: 210
                }
                EbSlider { id: virtualSlider; Layout.fillWidth: true; enabled: !root.muted[1]; from: 0; to: 1.5; value: 1; onMoved: root.apply() }
                MuteButton { which: 1 }
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: Math.round(virtualSlider.value * 100) + "%"; opacity: root.muted[1] ? 0.4 : 1; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
            }
            RowLayout {
                Layout.fillWidth: true
                visible: inputBox.currentIndex > 0
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: root.needsVirtual ? qsTr("Microphone volume") : qsTr("EasyBoard Mic volume"); Layout.preferredWidth: 210 }
                EbSlider {
                    id: micSlider
                    Layout.fillWidth: true
                    enabled: !root.muted[2]
                    from: 0; to: 1.5; value: 1
                    onMoved: { if (!root.loading && root.backend) root.backend.setMicVolume(value) }
                }
                MuteButton { which: 2 }
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: Math.round(micSlider.value * 100) + "%"; opacity: root.muted[2] ? 0.4 : 1; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
            }

            // -------- devices
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Microphone"); font.pixelSize: 17; font.weight: Font.DemiBold; Layout.topMargin: 16 }
            EbCombo {
                id: inputBox
                Layout.fillWidth: true
                model: root.inputList
                textRole: "label"
                displayText: currentIndex < 0 ? qsTr("Please Select Your Input") : currentText
                onActivated: root.apply()
            }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                visible: root.needsVirtual
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.6
                font.pixelSize: 12
                text: Qt.platform.os === "windows"
                    ? qsTr("Remember to choose \"CABLE Output (VB-Audio Virtual Cable)\" as your microphone in apps or as the system default")
                    : qsTr("Remember to choose \"VB-Cable\" as your microphone in apps or as the system default")
            }

            // Only shown when the virtual cable (VB-Cable) was not found automatically.
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Virtual cable output"); font.pixelSize: 17; font.weight: Font.DemiBold; visible: root.askVirtual; Layout.topMargin: 16 }
            EbCombo {
                id: virtualBox
                visible: root.askVirtual
                Layout.fillWidth: true
                model: root.virtualList
                displayText: currentIndex < 0 ? qsTr("Select your virtual cable output") : currentText
                onActivated: root.apply()
            }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                visible: root.askVirtual
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.6
                font.pixelSize: 12
                textFormat: Text.StyledText
                linkColor: palette.highlight
                onLinkActivated: function (l) { Qt.openUrlExternally(l) }
                text: Qt.platform.os === "windows"
                    ? qsTr("VB-Cable wasn't found. Download it <a href=\"https://vb-audio.com/Cable/\">here</a>, install it and restart EasyBoard.")
                    : qsTr("VB-Cable wasn't found. Download it <a href=\"https://vb-audio.com/Cable/\">here</a>, install it and restart EasyBoard.")
            }

            // -------- behavior
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Behavior"); font.pixelSize: 17; font.weight: Font.DemiBold; Layout.topMargin: 16 }
            EbSwitch {
                id: launchBox
                text: qsTr("Launch on startup")
                onToggled: root.applyBehavior()
            }
            EbSwitch {
                id: minimizedBox
                text: qsTr("Start minimized")
                onToggled: root.applyBehavior()
            }
            EbSwitch {
                id: trayBox
                text: qsTr("Close to system tray")
                onToggled: root.applyBehavior()
            }

            // -------- hotkeys
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Hotkeys"); font.pixelSize: 17; font.weight: Font.DemiBold; Layout.topMargin: 16 }
            RowLayout {
                Layout.fillWidth: true
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Stop all sounds"); Layout.preferredWidth: 210 }
                EbHotkey { id: stopHk; Layout.fillWidth: true; onEdited: root.applyHotkeys() }
            }
            RowLayout {
                Layout.fillWidth: true
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Loop all sounds"); Layout.preferredWidth: 210 }
                EbHotkey { id: loopHk; Layout.fillWidth: true; onEdited: root.applyHotkeys() }
            }
            RowLayout {
                Layout.fillWidth: true
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Mute Personal volume"); Layout.preferredWidth: 210 }
                EbHotkey { id: mutePersonalHk; Layout.fillWidth: true; onEdited: root.applyHotkeys() }
            }
            RowLayout {
                Layout.fillWidth: true
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: Qt.platform.os === "linux" ? qsTr("Mute EasyBoard Sink") : qsTr("Mute Soundboard volume"); Layout.preferredWidth: 210 }
                EbHotkey { id: muteSinkHk; Layout.fillWidth: true; onEdited: root.applyHotkeys() }
            }
            RowLayout {
                Layout.fillWidth: true
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: root.needsVirtual ? qsTr("Mute Microphone volume") : qsTr("Mute EasyBoard Mic"); Layout.preferredWidth: 210 }
                EbHotkey { id: muteMicHk; Layout.fillWidth: true; onEdited: root.applyHotkeys() }
            }

            // -------- appearance
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Appearance"); font.pixelSize: 17; font.weight: Font.DemiBold; Layout.topMargin: 16 }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                visible: root.themed
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.6
                font.pixelSize: 12
                text: root.themed ? qsTr("The theme \"%1\" is in use, so the theme, accent tint and background picture options are turned off. Choose \"Default\" on the Themes page to use them.").arg(Window.window.theme.name) : ""
            }
            EbSwitch {
                id: followBox
                enabled: !root.themed
                text: qsTr("App follows system theme")
                onToggled: root.applyAppearance()
            }
            EbCombo {
                id: themeBox
                visible: !followBox.checked
                enabled: !root.themed
                Layout.preferredWidth: 160
                model: [qsTr("Dark"), qsTr("Light")]
                onActivated: root.applyAppearance()
            }
            EbSwitch {
                id: trayFollowBox
                text: qsTr("Tray follows system theme")
                onToggled: root.applyAppearance()
            }
            EbCombo {
                id: trayThemeBox
                visible: !trayFollowBox.checked
                Layout.preferredWidth: 160
                model: [qsTr("Dark"), qsTr("Light")]
                onActivated: root.applyAppearance()
            }
            EbSwitch {
                id: tintBox
                enabled: !root.themed
                text: qsTr("Tint the app with the accent color")
                onToggled: root.applyAppearance()
            }
            EbSwitch {
                id: idsBox
                text: qsTr("Show sound IDs on the board")
                onToggled: root.applyAppearance()
            }
            // background picture: set a little apart from the switches above
            EbSwitch {
                id: wpBox
                enabled: !root.themed
                Layout.topMargin: 14
                text: qsTr("Use a picture as the background")
                onToggled: {
                    root.applyWallpaper()
                    if (checked && !root.wallpaperSet) wpDialog.openDialog()
                }
            }
            ColumnLayout {
                id: wpGroup
                visible: wpBox.checked && !root.themed
                Layout.fillWidth: true
                Layout.bottomMargin: 8
                spacing: 10

                // preview + drop zone: a file from your computer or a picture / link from a browser
                Rectangle {
                    id: wpDropBox
                    Layout.preferredWidth: root.wpWidth
                    Layout.maximumWidth: root.wpWidth
                    Layout.preferredHeight: 200
                    radius: 12
                    // always solid: the window's own background never shows through the preview
                    color: Window.window ? Qt.tint(Window.window.opaqueWindow, root.ink(0.06)) : root.ink(0.06)
                    border.width: wpDrop.containsDrag ? 3 : 1
                    border.color: wpDrop.containsDrag ? palette.highlight : root.ink(0.14)
                    Wallpaper {
                        anchors.fill: parent
                        anchors.margins: 1
                        radius: wpDropBox.radius - 1
                        settings: Window.window ? Window.window.wallpaper : ({ url: "", blur: 0, opacity: 1, brightness: 1 })
                    }
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                        anchors.centerIn: parent
                        visible: root.fetchingWallpaper || !root.wallpaperSet
                        text: root.fetchingWallpaper ? qsTr("Downloading…") : qsTr("Drop a picture here")
                        opacity: 0.6
                    }
                    DropArea {
                        id: wpDrop
                        anchors.fill: parent
                        onEntered: function (drag) {
                            var ok = false
                            if (drag.hasUrls)
                                for (var i = 0; i < drag.urls.length; i++) {
                                    var u = drag.urls[i].toString()
                                    if (root.isWebLink(u) || root.isImageFile(root.backend.urlToPath(u))) ok = true
                                }
                            if (!ok && drag.hasText && root.isWebLink(drag.text.trim())) ok = true
                            drag.accepted = ok
                        }
                        onDropped: function (drop) {
                            if (drop.hasUrls)
                                for (var i = 0; i < drop.urls.length; i++) {
                                    var u = drop.urls[i].toString()
                                    if (root.isWebLink(u)) { root.fetchWallpaper(u); return }
                                    var f = root.backend.urlToPath(u)
                                    if (root.isImageFile(f)) { root.fetchWallpaper(f); return }
                                }
                            if (drop.hasText && root.isWebLink(drop.text.trim())) root.fetchWallpaper(drop.text.trim())
                        }
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 10
                        spacing: 6
                        // clear the current picture (a backspace key, as for sound files)
                        EbButton {
                            glass: true             // see-through over the picture, whatever the mode below
                            visible: root.wallpaperSet
                            implicitWidth: 34
                            implicitHeight: 34
                            leftPadding: 0; rightPadding: 0
                            onClicked: { root.backend.clearWallpaper(); root.wallpaperSet = false }
                            Image {
                                anchors.centerIn: parent
                                width: 18; height: 18
                                sourceSize: Qt.size(36, 36)
                                source: Window.window ? Window.window.iconFor("backspace", palette.windowText) : ""
                                fillMode: Image.PreserveAspectFit
                            }
                            ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: qsTr("Clear picture")
                        }
                        EbButton {
                            glass: true
                            implicitHeight: 34
                            text: root.wallpaperSet ? qsTr("Change picture…") : qsTr("Choose picture…")
                            onClicked: wpDialog.openDialog()
                        }
                    }
                }

                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Picture should appear"); Layout.topMargin: 4 }
                // the three choices side by side, as wide as the sliders together; long names wrap onto two lines
                RowLayout {
                    Layout.preferredWidth: root.wpWidth
                    Layout.maximumWidth: root.wpWidth
                    spacing: 8
                    Repeater {
                        model: [
                            { mode: "board", text: qsTr("In soundboard section only") },
                            { mode: "behind", text: qsTr("In the background") },
                            { mode: "all", text: qsTr("Behind UI elements") }
                        ]
                        EbButton {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1          // equal thirds
                            Layout.fillHeight: true
                            wrap: true
                            font.pixelSize: 12
                            leftPadding: 6
                            rightPadding: 6
                            text: modelData.text
                            accent: root.wpMode === modelData.mode
                            onClicked: { root.wpMode = modelData.mode; root.applyWallpaper() }
                        }
                    }
                }

                RowLayout {
                    Layout.preferredWidth: root.wpWidth
                    Layout.maximumWidth: root.wpWidth
                    Layout.topMargin: 4
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Blur"); Layout.preferredWidth: 80 }
                    EbSlider { id: wpBlur; Layout.fillWidth: true; from: 0; to: 1; value: 0; onMoved: root.applyWallpaper() }
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: Math.round(wpBlur.value * 100) + "%"; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
                }
                RowLayout {
                    Layout.preferredWidth: root.wpWidth
                    Layout.maximumWidth: root.wpWidth
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Opacity"); Layout.preferredWidth: 80 }
                    EbSlider { id: wpOpacity; Layout.fillWidth: true; from: 0; to: 1; value: 1; onMoved: root.applyWallpaper() }
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: Math.round(wpOpacity.value * 100) + "%"; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
                }
                RowLayout {
                    Layout.preferredWidth: root.wpWidth
                    Layout.maximumWidth: root.wpWidth
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Brightness"); Layout.preferredWidth: 80 }
                    EbSlider { id: wpBright; Layout.fillWidth: true; from: 0; to: 2; value: 1; onMoved: root.applyWallpaper() }
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: Math.round(wpBright.value * 100) + "%"; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
                }
                EbSwitch {
                    id: wpShadow
                    text: qsTr("Add shadows to text")
                    onToggled: root.applyWallpaper()
                }
            }

            // -------- updates
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Updates"); font.pixelSize: 17; font.weight: Font.DemiBold; Layout.topMargin: 16 }
            EbSwitch {
                id: updBox
                text: qsTr("Check for updates on startup")
                onToggled: { if (!root.loading && root.backend) root.backend.setCheckUpdates(checked) }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                EbButton {
                    text: root.checking ? qsTr("Checking…") : qsTr("Check for updates")
                    enabled: !root.checking
                    onClicked: { root.updateText = ""; root.checking = true; root.backend.startUpdateCheck() }
                }
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    textFormat: Text.StyledText
                    linkColor: palette.highlight
                    text: root.updateText
                    onLinkActivated: function (l) { Qt.openUrlExternally(l) }
                }
            }

            // -------- about
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("About"); font.pixelSize: 17; font.weight: Font.DemiBold; Layout.topMargin: 16 }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "EasyBoard " + (root.backend ? JSON.parse(root.backend.settings()).version : "") + "\nMrRedstonia · contact@mrredstonia.com"
                opacity: 0.55
            }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                id: repoLink
                Layout.fillWidth: true
                textFormat: Text.RichText
                linkColor: palette.highlight
                // (rich text ignores linkColor: the color goes into the links themselves)
                readonly property string linkCss: "style=\"color:" + String(palette.highlight) + "\""
                text: "<a " + linkCss + " href=\"https://github.com/MrRedstonia/EasyBoard\">GitHub</a> · <a " + linkCss + " href=\"notes:\">" + qsTr("Release notes") + "</a>"
                onLinkActivated: function (link) {
                    if (link === "notes:") { notesPopup.notes = root.backend.releaseNotes(); notesPopup.open() }
                    else Qt.openUrlExternally(link)
                }
                HoverHandler { cursorShape: repoLink.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor }
            }

            Item { Layout.preferredHeight: 24 }
        }
    }
}
