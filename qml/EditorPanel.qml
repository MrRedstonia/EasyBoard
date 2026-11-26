import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

// Right-hand sidebar used to add or edit a sound (replaces the old popup).
Item {
    id: panel
    property var backend
    property var colors: []
    property bool open: false
    onOpenChanged: if (!open) selectBtn.close()
    signal deleteRequested(string id)

    property string editId: ""          // "" = adding a new sound
    property string audioPath: ""
    property string newImagePath: ""    // freshly chosen picture (will be copied)
    property string existingImage: ""   // picture already stored in the config folder
    property bool removeImage: false
    property string hotkeyText: ""
    onHotkeyTextChanged: if (hotkeyField.value !== hotkeyText) hotkeyField.value = hotkeyText
    property string tileColor: ""
    property string errorText: ""

    readonly property int panelWidth: 390
    readonly property var colorNames: [qsTr("Default"), qsTr("Red"), qsTr("Orange"), qsTr("Yellow"),
                                       qsTr("Green"), qsTr("Teal"), qsTr("Blue"), qsTr("Purple"), qsTr("Magenta"),
                                       qsTr("Pink"), qsTr("Light green"), qsTr("Light blue")]

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    Layout.fillHeight: true
    Layout.preferredWidth: open ? panelWidth : 0
    property bool snap: false
    function closeNow() { snap = true; open = false; Qt.callLater(function () { snap = false }) }
    Behavior on Layout.preferredWidth { enabled: !panel.snap; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    clip: true
    visible: Layout.preferredWidth > 0.5

    function openNew() {
        editId = ""; audioPath = ""; newImagePath = ""; existingImage = ""
        removeImage = false; hotkeyText = ""; tileColor = ""; hotkeyField.capturing = false; errorText = ""
        nameField.text = ""; volumeSlider.value = 1.0; loopSwitch.checked = false
        open = true
    }

    function openEdit(s) {
        editId = s.id; audioPath = s.path; newImagePath = ""; existingImage = s.image
        removeImage = false; hotkeyText = s.hotkey; tileColor = s.color; hotkeyField.capturing = false; errorText = ""
        nameField.text = s.name; volumeSlider.value = s.volume; loopSwitch.checked = s["loop"]
        open = true
    }

    function isAudioFile(p) { return /\.(mp3|wav|flac|ogg|oga|opus|m4a|aac|mp4|mkv|webm|aif|aiff|caf)$/i.test(p) }
    property bool fetchingImage: false
    function isWebLink(u) { return /^https?:\/\//i.test(u) }
    // a picture dropped as a web link is downloaded in the background; one from disk is used as it is,
    // or converted first when it's in a format Qt can't show (WebP, AVIF, HEIC...)
    function fetchImage(u) {
        fetchingImage = true
        if (isWebLink(u)) backend.imageFromUrl(u)
        else backend.prepareImage(u)
        imageFetchTimer.start()
    }
    Timer {
        id: imageFetchTimer
        interval: 150
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var r = JSON.parse(backend.imageFetchState())
            if (r.state === "loading") return
            stop()
            panel.fetchingImage = false
            if (r.state === "done") { panel.newImagePath = r.path; panel.removeImage = false }
            else if (r.state === "error" && Window.window) Window.window.toast(r.error)
        }
    }

    function isImageFile(p) { return /\.(png|jpe?g|webp|avif|heic|heif|bmp|gif|svg)$/i.test(p) }

    function baseName(p) {
        var s = p.replace(/\\/g, "/")
        return s.substring(s.lastIndexOf("/") + 1)
    }

    function save() {
        errorText = ""
        if (audioPath === "") { errorText = qsTr("Choose an audio file."); return }
        var name = nameField.text.trim()
        if (name === "") name = baseName(audioPath).replace(/\.[^.]+$/, "")
        var err
        if (editId === "")
            err = backend.addSound(name, audioPath, newImagePath, volumeSlider.value,
                                   loopSwitch.checked, hotkeyText, tileColor)
        else
            err = backend.updateSound(editId, name, audioPath, newImagePath, removeImage,
                                      volumeSlider.value, loopSwitch.checked, hotkeyText, tileColor)
        if (err !== "") { errorText = err; return }
        open = false
    }

    EbFileDialog {
        backend: panel.backend
        id: audioDialog
        title: qsTr("Choose an audio file")
        nameFilters: [qsTr("Audio files (*.mp3 *.wav *.flac *.ogg *.oga *.opus *.m4a *.aac *.mp4 *.mkv *.webm *.aif *.aiff *.caf)"),
                      qsTr("All files (*)")]
        onAccepted: {
            panel.audioPath = backend.urlToPath(selectedFile.toString())
            if (nameField.text === "")
                nameField.text = panel.baseName(panel.audioPath).replace(/\.[^.]+$/, "")
        }
    }
    EbFileDialog {
        backend: panel.backend
        id: imageDialog
        title: qsTr("Choose a picture")
        nameFilters: [qsTr("Pictures (*.png *.jpg *.jpeg *.webp *.avif *.heic *.heif *.bmp *.gif *.svg)"), qsTr("All files (*)")]
        onAccepted: panel.fetchImage(backend.urlToPath(selectedFile.toString()))
    }
    // Panel background + divider
    Rectangle {
        GlassBackdrop { anchors.fill: parent; z: -1 }
        anchors.fill: parent
        readonly property color solid: (Window.window && Window.window.tintOn) ? Window.window.tinted(Qt.tint(palette.window, panel.ink(0.04)), 0.14) : Qt.tint(palette.window, panel.ink(0.04))
        color: Window.window && Window.window.themed && Window.window.theme.colors.panel ? Window.window.theme.colors.panel
             : Window.window && Window.window.wallpaperAll ? Qt.rgba(solid.r, solid.g, solid.b, 0.7) : solid
    }
    Rectangle {
        width: 1
        height: parent.height
        color: panel.ink(0.14)
    }

    // Fixed-width content so it doesn't reflow while the panel animates
    Item {
        width: panel.panelWidth
        height: parent.height

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
                x: 22
                width: scroll.availableWidth - 44
                spacing: 14

                Item { Layout.preferredHeight: 6 }

                RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                            Layout.fillWidth: true
                            text: nameField.text.trim() !== "" ? nameField.text.trim() : qsTr("New sound")
                            font.pixelSize: 22
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                            Layout.fillWidth: true
                            visible: panel.editId !== ""
                            text: qsTr("ID %1").arg(panel.editId)
                            font.pixelSize: 12
                            opacity: 0.5
                            elide: Text.ElideRight
                        }
                    }
                    EbButton {
                        text: "✕"
                        font.pixelSize: 24
                        implicitWidth: 44
                        implicitHeight: 44
                        onClicked: panel.open = false
                    }
                }

                // Square picture
                Rectangle {
                    id: picBox
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 180
                    Layout.preferredHeight: 180
                    radius: 14
                    color: Window.window && Window.window.solid ? Window.window.solid(((Window.window && Window.window.tintOn) ? Window.window.tintFill(0) : panel.ink(0.07))) : panel.ink(0.07)
                    border.width: picDrop.containsDrag ? 3 : 1
                    border.color: picDrop.containsDrag ? palette.highlight : panel.ink(0.16)

                    DropArea {
                        id: picDrop
                        anchors.fill: parent
                        onEntered: function (drag) {
                            var ok = false
                            if (drag.hasUrls)
                                for (var i = 0; i < drag.urls.length; i++) {
                                    var u = drag.urls[i].toString()
                                    if (panel.isWebLink(u) || panel.isImageFile(backend.urlToPath(u))) ok = true
                                }
                            if (!ok && drag.hasText && panel.isWebLink(drag.text.trim())) ok = true
                            drag.accepted = ok
                        }
                        onDropped: function (drop) {
                            if (drop.hasUrls)
                                for (var i = 0; i < drop.urls.length; i++) {
                                    var u = drop.urls[i].toString()
                                    if (panel.isWebLink(u)) { panel.fetchImage(u); return }
                                    var f = backend.urlToPath(u)
                                    if (panel.isImageFile(f)) { panel.fetchImage(f); return }
                                }
                            if (drop.hasText && panel.isWebLink(drop.text.trim())) panel.fetchImage(drop.text.trim())
                        }
                    }

                    RoundedImage {
                        anchors.fill: parent
                        radius: picBox.radius
                        source: {
                            var p = panel.newImagePath !== "" ? panel.newImagePath
                                  : (panel.removeImage ? "" : panel.existingImage)
                            if (p === "") return ""
                            p = p.replace(/\\/g, "/")
                            return "file://" + (p.charAt(0) === "/" ? p : "/" + p)
                        }
                    }
                    Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                        anchors.centerIn: parent
                        visible: panel.fetchingImage
                        text: qsTr("Downloading…")
                        font.pixelSize: 14
                        color: palette.windowText
                        opacity: 0.7
                    }
                    Column {
                        anchors.centerIn: parent
                        visible: !panel.fetchingImage && panel.newImagePath === "" && (panel.removeImage || panel.existingImage === "")
                        spacing: 4
                        Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; anchors.horizontalCenter: parent.horizontalCenter; text: "+"; font.pixelSize: 48; color: palette.windowText; opacity: 0.5 }
                        Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("Add picture"); font.pixelSize: 13; color: palette.windowText; opacity: 0.5 }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: imageDialog.openDialog()
                    }
                }
                EbButton {
                    Layout.alignment: Qt.AlignHCenter
                    visible: panel.newImagePath !== "" || (!panel.removeImage && panel.existingImage !== "")
                    text: qsTr("Remove picture")
                    implicitHeight: 32
                    onClicked: { panel.newImagePath = ""; panel.removeImage = true }
                }

                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Name"); opacity: 0.7 }
                EbField {
                    id: nameField
                    Layout.fillWidth: true
                    placeholderText: qsTr("Sound name")
                }

                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Audio file"); opacity: 0.7 }
                // Wide path box with the "Select File" button inside it
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    radius: 10
                    color: Window.window && Window.window.solid ? Window.window.solid(((Window.window && Window.window.tintOn) ? Window.window.tintFill(0) : panel.ink(0.06))) : panel.ink(0.06)
                    border.width: audioDrop.containsDrag ? 2 : 1
                    border.color: audioDrop.containsDrag ? palette.highlight : panel.ink(0.14)

                    DropArea {
                        id: audioDrop
                        anchors.fill: parent
                        onEntered: function (drag) {
                            var ok = false
                            if (drag.hasUrls)
                                for (var i = 0; i < drag.urls.length; i++)
                                    if (panel.isAudioFile(backend.urlToPath(drag.urls[i].toString()))) ok = true
                            drag.accepted = ok
                        }
                        onDropped: function (drop) {
                            if (!drop.hasUrls) return
                            for (var i = 0; i < drop.urls.length; i++) {
                                var f = backend.urlToPath(drop.urls[i].toString())
                                if (panel.isAudioFile(f)) {
                                    panel.audioPath = f
                                    if (nameField.text === "")
                                        nameField.text = panel.baseName(f).replace(/\.[^.]+$/, "")
                                    break
                                }
                            }
                        }
                    }

                    // hovering shows the full path of a file that is not in the sounds folder
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        hoverEnabled: true
                        ToolTip.visible: containsMouse && panel.audioPath !== "" && !selectBtn.isLibrary(panel.audioPath)
                        ToolTip.delay: 500
                        ToolTip.text: panel.audioPath
                    }
                    // button that clears the chosen file (a backspace key)
                    EbButton {
                        id: clearBtn
                        visible: panel.audioPath !== ""
                        anchors.right: selectBtn.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        implicitWidth: 34
                        implicitHeight: 34
                        leftPadding: 0; rightPadding: 0
                        onClicked: panel.audioPath = ""
                        Image {
                            anchors.centerIn: parent
                            width: 18; height: 18
                            sourceSize: Qt.size(36, 36)
                            source: Window.window ? Window.window.iconFor("backspace", palette.windowText) : ""
                            fillMode: Image.PreserveAspectFit
                        }
                        ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: qsTr("Clear")
                    }
                    Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.right: clearBtn.visible ? clearBtn.left : selectBtn.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: panel.audioPath !== "" ? selectBtn.shownPath(panel.audioPath) : "../../"
                        elide: Text.ElideLeft
                        font.pixelSize: 14
                        color: palette.windowText
                        opacity: panel.audioPath !== "" ? 1 : 0.4
                    }
                    EbAudioPicker {
                        id: selectBtn
                        backend: panel.backend
                        anchors.right: parent.right
                        anchors.rightMargin: 5
                        anchors.verticalCenter: parent.verticalCenter
                        implicitHeight: 34
                        onPicked: function (f) {
                            panel.audioPath = f
                            if (nameField.text === "")
                                nameField.text = panel.baseName(f).replace(/\.[^.]+$/, "")
                        }
                        onCustomRequested: audioDialog.openDialog()
                    }
                }

                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Color"); opacity: 0.7; visible: !Window.window || Window.window.shown("editor.color") }
                Flow {
                    // a theme that draws every tile the same can leave the color choice out (<hide element="editor.color">)
                    visible: !Window.window || Window.window.shown("editor.color")
                    Layout.fillWidth: true
                    spacing: 10
                    Repeater {
                        model: panel.colors
                        Rectangle {
                            id: swatch
                            required property int index
                            required property string modelData
                            readonly property string label: panel.colorNames[index] || modelData
                            width: 32; height: 32; radius: 16
                            readonly property string shown: Window.window && Window.window.tileSwatch ? Window.window.tileSwatch(modelData) : modelData
                            color: shown === "" ? panel.ink(0.10) : shown
                            border.width: panel.tileColor === modelData || activeFocus ? 3 : 1
                            border.color: activeFocus ? palette.highlight
                                        : (panel.tileColor === modelData ? palette.windowText : panel.ink(0.25))
                            activeFocusOnTab: true
                            Keys.onSpacePressed: panel.tileColor = modelData
                            Keys.onReturnPressed: panel.tileColor = modelData
                            Accessible.role: Accessible.RadioButton
                            Accessible.name: label
                            Accessible.checked: panel.tileColor === modelData
                            Accessible.onPressAction: panel.tileColor = modelData
                            Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                                anchors.centerIn: parent
                                visible: swatch.shown === ""
                                text: "∅"
                                color: palette.windowText
                                opacity: 0.6
                                font.pixelSize: 16
                            }
                            MouseArea {
                                id: swatchArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { panel.tileColor = swatch.modelData; swatch.forceActiveFocus() }
                            }
                            ToolTip.visible: swatchArea.containsMouse
                            ToolTip.delay: 250
                            ToolTip.text: swatch.label
                        }
                    }
                }

                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Volume"); opacity: 0.7 }
                RowLayout {
                    Layout.fillWidth: true
                    EbSlider { id: volumeSlider; Layout.fillWidth: true; from: 0; to: 2; value: 1 }
                    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: Math.round(volumeSlider.value * 100) + "%"; Layout.preferredWidth: 48; horizontalAlignment: Text.AlignRight }
                }

                EbSwitch {
                    id: loopSwitch
                    text: qsTr("Loop this sound")
                    Layout.fillWidth: true
                }

                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Hotkey"); opacity: 0.7 }
                EbHotkey {
                    id: hotkeyField
                    Layout.fillWidth: true
                    value: panel.hotkeyText
                    onEdited: function (v) { panel.hotkeyText = v }
                }

                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    visible: panel.errorText !== ""
                    text: panel.errorText
                    color: "#e5484d"
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    spacing: 8
                    EbButton {
                        visible: panel.editId !== ""
                        danger: true
                        text: qsTr("Delete")
                        onClicked: panel.deleteRequested(panel.editId)
                    }
                    Item { Layout.fillWidth: true }
                    EbButton { text: qsTr("Cancel"); onClicked: panel.open = false }
                    EbButton {
                        accent: true
                        text: panel.editId === "" ? qsTr("Add") : qsTr("Save")
                        onClicked: panel.save()
                    }
                }

                Item { Layout.preferredHeight: 20 }
            }
        }
    }
}
