import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml.Models

Item {
    id: root
    // menus fade in and out (<controls menuAnimation="true">); read here, Transitions can't see the window
    readonly property bool menuAnim: !!(Window.window && Window.window.menuAnimation)
    property var backend
    property var sounds: []
    property var playing: []
    property var progressMap: ({})
    property string sortMode: "manual"
    property bool showIds: true
    property var tileColors: []
    readonly property var colorNames: [qsTr("Default"), qsTr("Red"), qsTr("Orange"), qsTr("Yellow"),
                                       qsTr("Green"), qsTr("Teal"), qsTr("Blue"), qsTr("Purple"), qsTr("Magenta"),
                                       qsTr("Pink"), qsTr("Light green"), qsTr("Light blue")]
    property var hiddenColors: ({})      // lower-case color ("" = default) -> true while hidden
    property int hiddenCount: 0

    function toggleColor(c) {
        var key = (c || "").toLowerCase()
        var m = Object.assign({}, hiddenColors)
        if (m[key]) delete m[key]; else m[key] = true
        hiddenColors = m
        hiddenCount = Object.keys(m).length
        saveHidden()
        rebuild()
    }
    // stored in the config ("" -> "default") so the command line --list-full can report it
    function saveHidden() {
        if (!backend) return
        backend.setHiddenColors(Object.keys(hiddenColors).map(function (k) { return k === "" ? "default" : k }).join(","))
    }
    function loadHidden() {
        if (!backend) return
        var arr = JSON.parse(backend.settings()).hiddenColors || []
        var m = {}
        for (var i = 0; i < arr.length; i++) m[arr[i] === "default" ? "" : arr[i]] = true
        hiddenColors = m
        hiddenCount = Object.keys(m).length
    }
    function hideAllColors() {
        var m = {}
        for (var i = 0; i < tileColors.length; i++) m[tileColors[i].toLowerCase()] = true
        hiddenColors = m
        hiddenCount = tileColors.length
        saveHidden()
        rebuild()
    }
    function showAllColors() { hiddenColors = ({}); hiddenCount = 0; saveHidden(); rebuild() }
    property alias flick: grid          // the window-level scroll bar in Main.qml drives this

    signal addRequested()
    signal deleteRequested(var ids)
    signal editRequested(var sound)
    signal filesAdded(int count)
    signal addFailed(string message)

    // a theme can change the tiles: their width, no pictures, no IDs (<tiles width pictures ids>)
    readonly property var themeTiles: Window.window && Window.window.themed ? Window.window.theme.tiles : null
    readonly property int tileW: themeTiles && themeTiles.width > 0 ? themeTiles.width : 190
    readonly property bool tilePictures: !themeTiles || themeTiles.pictures
    // Will the board need its scroll bar? Judged with the narrower (scroll bar) layout, so the answer
    // can't flip back and forth when the margin changes.
    readonly property bool scrollable: {
        var cols = Math.max(1, Math.floor((root.width - 14 - 26 - 8) / (tileW + 24)))
        var rows = Math.ceil(grid.count / cols)
        return rows * (tileH + 24) + (selCount > 0 ? 70 : 0) > gridBg.height
    }
    readonly property int tileH: tilePictures ? tileW + 68 : 92
    readonly property var sortKeys: ["manual", "az", "id", "len", "color", "added"]
    readonly property var sortLabels: [qsTr("Manual"), qsTr("A-Z"), qsTr("ID"), qsTr("Length"), qsTr("Color"), qsTr("Added")]
    readonly property bool canReorder: sortMode === "manual" && searchField.text.trim() === ""

    // ---- multi-select -------------------------------------------------
    property var selected: ({})          // sid -> true
    property int selCount: 0
    property string anchorId: ""

    function setSelected(map, anchor) {
        selected = map
        selCount = Object.keys(map).length
        if (anchor !== undefined) anchorId = anchor
    }
    function clearSelection() { setSelected({}, "") }
    function selectedIds() { return Object.keys(selected) }
    function visibleIds() {
        var out = []
        for (var i = 0; i < visualModel.items.count; i++) {
            var m = visualModel.items.get(i).model
            if (m.kind === "sound") out.push(m.sid)
        }
        return out
    }
    function selectAll() {
        var m = {}
        var ids = visibleIds()
        for (var i = 0; i < ids.length; i++) m[ids[i]] = true
        setSelected(m, anchorId)
    }
    function tileClicked(sid, mods) {
        var ctrl = (mods & Qt.ControlModifier) !== 0
        var shift = (mods & Qt.ShiftModifier) !== 0
        var m = Object.assign({}, selected)
        if (shift && anchorId !== "") {
            var ids = visibleIds()
            var a = ids.indexOf(anchorId), b = ids.indexOf(sid)
            if (a >= 0 && b >= 0) {
                if (!ctrl) m = {}
                for (var i = Math.min(a, b); i <= Math.max(a, b); i++) m[ids[i]] = true
                setSelected(m)
                return
            }
        }
        if (ctrl || shift || selCount > 0) {
            if (m[sid]) delete m[sid]; else m[sid] = true
            setSelected(m, sid)
            return
        }
        backend.trigger(sid)
    }
    function pruneSelection() {
        var m = {}
        var any = false
        for (var i = 0; i < sounds.length; i++)
            if (selected[sounds[i].id]) { m[sounds[i].id] = true; any = true }
        if (Object.keys(m).length !== selCount) setSelected(m)
    }

    Keys.onEscapePressed: clearSelection()
    focus: true

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    // "az"/"za", "id_asc"/"id_desc", ... <-> dropdown choice + "Reverse" switch
    function parseMode(m) {
        switch (m) {
        case "za": return { base: "az", rev: true }
        case "id_asc": return { base: "id", rev: false }
        case "id_desc": return { base: "id", rev: true }
        case "len_asc": return { base: "len", rev: false }
        case "len_desc": return { base: "len", rev: true }
        case "color": return { base: "color", rev: false }
        case "color_desc": return { base: "color", rev: true }
        case "added_asc": return { base: "added", rev: false }
        case "added_desc": return { base: "added", rev: true }
        case "az": return { base: "az", rev: false }
        default: return { base: "manual", rev: false }
        }
    }
    function composeMode(base, rev) {
        switch (base) {
        case "az": return rev ? "za" : "az"
        case "id": return rev ? "id_desc" : "id_asc"
        case "len": return rev ? "len_desc" : "len_asc"
        case "color": return rev ? "color_desc" : "color"
        case "added": return rev ? "added_desc" : "added_asc"
        default: return "manual"
        }
    }
    function syncSortUi() {
        var p = parseMode(sortMode)
        sortBox.currentIndex = sortKeys.indexOf(p.base)
        reverseSwitch.checked = p.rev
    }
    function applySort() {
        if (!backend) return
        backend.setSortMode(composeMode(sortKeys[sortBox.currentIndex], reverseSwitch.checked))
    }

    onVisibleChanged: if (!visible) colorPopup.close()
    onSortModeChanged: syncSortUi()
    onSoundsChanged: { rebuild(); pruneSelection() }
    Component.onCompleted: { syncSortUi(); loadHidden(); rebuild() }

    function rebuild() {
        var q = searchField.text.trim().toLowerCase()
        soundsModel.clear()
        // index 0 is always the "+" tile
        soundsModel.append({ kind: "add", sid: "", sname: "", path: "", image: "",
                             volume: 1, looping: false, hotkey: "", tcolor: "" })
        for (var i = 0; i < sounds.length; i++) {
            var s = sounds[i]
            if (q !== "" && s.name.toLowerCase().indexOf(q) < 0 && s.id.indexOf(q) < 0) continue
            if (hiddenColors[(s.color || "").toLowerCase()]) continue
            soundsModel.append({ kind: "sound", sid: s.id, sname: s.name, path: s.path,
                                 image: s.image, volume: s.volume, looping: s["loop"],
                                 hotkey: s.hotkey, tcolor: s.color })
        }
    }

    ListModel { id: soundsModel }

    // ----- header: title | search | colors | sort (a theme can reorder them: <order area="boardHeader">)
    readonly property var headerOrder: ["title", "search", "colors", "sort"]
    // <layout search="center">: the search field leaves the row and sits in the middle of the header
    readonly property bool searchCentered: !!(Window.window && Window.window.themed && Window.window.theme.layout.search === "center")
    Item {
        id: searchCenter
        anchors.horizontalCenter: header.horizontalCenter
        anchors.verticalCenter: header.verticalCenter
        // as wide as fits between the title and the controls on the right (kept centered), within 180..560
        readonly property real leftUsed: boardTitle.visible ? boardTitle.implicitWidth : 0
        readonly property real rightUsed: header.width - sortBox.x
        width: Math.round(Math.max(180, Math.min(560, header.width - 2 * Math.max(leftUsed, rightUsed) - 48)))
        height: 42
    }
    states: State {
        when: root.searchCentered
        ParentChange { target: searchField; parent: searchCenter }
        PropertyChanges { target: searchField; x: 0; y: 0; width: searchCenter.width }
    }
    GridLayout {
        id: header
        rows: 1
        columnSpacing: 12
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        anchors.topMargin: 20
        height: 46


        Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
            id: boardTitle
            visible: !Window.window || Window.window.shown("board.title")
            Layout.column: Window.window && Window.window.orderIndex ? Window.window.orderIndex("boardHeader", "title", root.headerOrder) : root.headerOrder.indexOf("title")
            text: qsTr("Soundboard")
            font.pixelSize: 30
            font.weight: Font.Light
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.minimumWidth: 0
        }

        EbField {
            id: searchField
            visible: !Window.window || Window.window.shown("board.search")
            Layout.column: Window.window && Window.window.orderIndex ? Window.window.orderIndex("boardHeader", "search", root.headerOrder) : root.headerOrder.indexOf("search")
            Layout.fillWidth: true
            Layout.maximumWidth: 210
            Layout.minimumWidth: 110
            Layout.preferredWidth: 190
            implicitHeight: 42
            placeholderText: qsTr("Search sounds…")
            onTextChanged: root.rebuild()
        }

        // show / hide sounds by color
        Rectangle {
            id: colorBtn
            scale: Window.window && Window.window.controlScale ? Window.window.controlScale(colorMouse.containsMouse, colorMouse.pressed, width) : 1
            Behavior on scale { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
            // The menu opens from this invisible, never-moving stand-in for the control at its normal size
            // (it undoes the control's own scale), so the control may grow and sink while the menu stays put.
            Item {
                id: colorAnchor
                anchors.fill: parent
                scale: colorBtn.scale > 0 ? 1 / colorBtn.scale : 1
            }
            GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius; control: true }
            visible: !Window.window || Window.window.shown("board.colors")
            Layout.column: Window.window && Window.window.orderIndex ? Window.window.orderIndex("boardHeader", "colors", root.headerOrder) : root.headerOrder.indexOf("colors")
            Layout.preferredHeight: 42
            Layout.preferredWidth: colorRow.implicitWidth + 28
            radius: Window.window && Window.window.controlRadius ? Window.window.controlRadius(height, 10) : 10
            Shadow { z: -2; lift: 3; opacity: strength * 0.6 }
            Sheen { anchors.fill: parent; radius: parent.radius }
            // same fill as the other buttons
            color: Window.window && Window.window.controlFill ? Window.window.controlFill(colorMouse.pressed ? 2 : colorMouse.containsMouse ? 1 : 0)
                 : (colorMouse.containsMouse ? root.ink(0.13) : root.ink(0.08))
            border.width: colorPopup.opened ? (Window.window && Window.window.focusEdge ? Window.window.focusEdge(2) : 2) : (Window.window && Window.window.edge ? Window.window.edge(1) : 1)
            border.color: colorPopup.opened ? palette.highlight
                        : Window.window && Window.window.themeColor ? Window.window.themeColor("controlBorder", root.ink(0.14)) : root.ink(0.14)

            Row {
                id: colorRow
                anchors.centerIn: parent
                spacing: 7
                Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    text: qsTr("Colors")
                    color: palette.windowText
                    font.pixelSize: 14
                    anchors.verticalCenter: parent.verticalCenter
                }
                // one filled dot per hidden color
                Grid {
                    rows: root.hiddenCount > 1 ? 2 : 1
                    flow: Grid.TopToBottom
                    spacing: 3
                    // whole pixels: a dot on a half pixel looks blurry / uneven
                    y: Math.round((parent.height - height) / 2)
                    Repeater {
                        model: root.tileColors
                        Rectangle {
                            required property string modelData
                            visible: !!root.hiddenColors[modelData.toLowerCase()]
                            width: 12; height: 12; radius: 6
                            readonly property string shown: Window.window && Window.window.tileSwatch ? Window.window.tileSwatch(modelData) : modelData
                            color: shown === "" ? root.ink(0.5) : shown
                        }
                    }
                }
                Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    text: "▾"
                    color: root.ink(0.6)
                    font.pixelSize: 16
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            ToolTip.visible: colorMouse.containsMouse && !colorPopup.opened
            ToolTip.delay: 500
            ToolTip.text: qsTr("Hide specific colors")
            MouseArea {
                id: colorMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: { if (colorPopup.opened) colorPopup.close(); else { sortBox.popup.close(); colorPopup.open() } }
            }

            LiquidPopup {
                id: colorPopup
                animated: root.menuAnim
                parent: colorAnchor
                y: colorBtn.height + 6
                x: 0
                width: 160
                padding: 6
                // pressing the button itself must not count as "outside", so its click can close the menu
                focus: true
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                // the same background as the Sort menu
                background: Rectangle {
                    GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius }
                    Shadow { z: -2 }
                    radius: Window.window && Window.window.controlRadius ? Math.min(Window.window.controlRadius(999, 12), 20) : 12
                    color: Window.window && Window.window.themeColor ? Window.window.themeColor("menu", Window.window.popupFill(palette.base)) : palette.base
                    border.width: Window.window && Window.window.edge ? Window.window.edge(1) : 1
                    Sheen { anchors.fill: parent; radius: parent.radius; amount: 0.3 }
                    border.color: Window.window && Window.window.themeColor ? Window.window.themeColor("border", root.ink(0.18)) : root.ink(0.18)
                }
                // only one of the two menus is ever open
                onAboutToShow: sortBox.popup.close()
                contentItem: ColumnLayout {
                    spacing: 6
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 4.5 * 28
                        ListView {
                            id: colorList
                            anchors.fill: parent
                            clip: true
                            interactive: false
                            boundsBehavior: Flickable.StopAtBounds
                            model: root.tileColors
                            ScrollBar.vertical: EbScrollBar {}
                            delegate: Rectangle {
                                id: row
                                required property int index
                                required property string modelData
                                readonly property bool shown: !root.hiddenColors[modelData.toLowerCase()]
                                width: colorList.width - 10
                                height: 28
                                radius: 7
                                color: rowMouse.containsMouse ? root.ink(0.10) : "transparent"
                                Rectangle {
                                    x: 5; y: Math.round((parent.height - height) / 2)
                                    width: 16; height: 16; radius: 8
                                    readonly property string shown: Window.window && Window.window.tileSwatch ? Window.window.tileSwatch(row.modelData) : row.modelData
                                    color: shown === "" ? root.ink(0.12) : shown
                                    border.width: 1; border.color: root.ink(0.25)
                                    opacity: row.shown ? 1 : 0.35
                                }
                                Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                                    x: 28; anchors.verticalCenter: parent.verticalCenter
                                    text: root.colorNames[row.index] || row.modelData
                                    color: palette.windowText
                                    font.pixelSize: 12
                                    opacity: row.shown ? 1 : 0.45
                                }
                                Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                                    anchors.right: parent.right; anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: row.shown ? "✓" : ""
                                    color: palette.highlight
                                    font.pixelSize: 13
                                }
                                MouseArea {
                                    id: rowMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: root.toggleColor(row.modelData)
                                }
                            }
                        }
                        EbWheel { anchors.fill: parent; flick: colorList; rowHeight: 28; rowsPerNotch: 1 }
                    }
                    // stays at the bottom while the list scrolls
                    EbButton {
                        Layout.fillWidth: true
                        implicitHeight: 32
                        text: root.hiddenCount > 0 ? qsTr("Show all") : qsTr("Hide all")
                        onClicked: root.hiddenCount > 0 ? root.showAllColors() : root.hideAllColors()
                    }
                }
            }
        }

        EbCombo {
            id: sortBox
            // only one of the two menus is ever open
            Connections { target: sortBox.popup; function onAboutToShow() { colorPopup.close() } }
            visible: !Window.window || Window.window.shown("board.sort")
            Layout.column: Window.window && Window.window.orderIndex ? Window.window.orderIndex("boardHeader", "sort", root.headerOrder) : root.headerOrder.indexOf("sort")
            Layout.preferredWidth: 140
            model: root.sortLabels
            ToolTip.visible: hovered
            ToolTip.delay: 500
            ToolTip.text: qsTr("Sort the board")
            onActivated: root.applySort()
        }

        EbSwitch {
            id: reverseSwitch
            text: qsTr("Reverse")
            enabled: root.sortKeys[sortBox.currentIndex] !== "manual"
            opacity: enabled ? 1 : 0.4
            onToggled: root.applySort()
        }

    }

    // ----- drop audio files anywhere on the board to add them (no picture)
    function isAudioFile(p) { return /\.(mp3|wav|flac|ogg|oga|opus|m4a|aac|mp4|mkv|webm|aif|aiff|caf)$/i.test(p) }
    property int dropCount: 0
    DropArea {
        id: fileDrop
        anchors.fill: gridBg
        onEntered: function (drag) {
            var n = 0
            if (drag.hasUrls)
                for (var i = 0; i < drag.urls.length; i++)
                    if (root.isAudioFile(root.backend.urlToPath(drag.urls[i].toString()))) n++
            root.dropCount = n
            drag.accepted = n > 0
        }
        onDropped: function (drop) {
            if (!drop.hasUrls) return
            var added = 0, failed = ""
            for (var i = 0; i < drop.urls.length; i++) {
                var f = root.backend.urlToPath(drop.urls[i].toString())
                if (!root.isAudioFile(f)) continue
                var name = f.replace(/^.*[\\\/]/, "").replace(/\.[^.]+$/, "")
                var err = root.backend.addSound(name, f, "", 1.0, false, "", "")
                if (err === "") added++; else failed = err
            }
            if (added > 0) root.filesAdded(added)
            if (failed !== "") root.addFailed(failed)
        }
    }

    // ----- board
    EbWheel { anchors.fill: gridBg; flick: grid; rowHeight: grid.cellHeight }

    Rectangle {
        id: gridBg
        anchors.top: header.bottom
        anchors.topMargin: 14
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 14
        anchors.rightMargin: root.scrollable ? 26 : 14   // room for the 12 px scroll bar only when there is one
        anchors.bottomMargin: 6
        radius: Window.window && Window.window.themed && Window.window.theme.layout.radius >= 0 ? Window.window.theme.layout.radius : 16
        // a theme's "board" color; picture behind the app: dark glass over it; picture only here: drawn inside this box
        color: Window.window && Window.window.themed && Window.window.theme.colors.board ? Window.window.theme.colors.board
             : Window.window && Window.window.wallpaperBehind ? Qt.rgba(0, 0, 0, 0.45)
             : (Window.window && Window.window.tintOn) ? Window.window.tinted(Qt.darker(palette.window, 1.12), 0.22) : Qt.darker(palette.window, 1.12)
        border.width: (Window.window && Window.window.edge ? Window.window.edge(1) : 1)
        border.color: Window.window && Window.window.themeColor ? Window.window.themeColor("border", root.ink(0.06)) : root.ink(0.06)
        GlassBackdrop { anchors.fill: parent; z: -1; radius: gridBg.radius }
        Shadow { z: -2 }
        Wallpaper {
            anchors.fill: parent
            anchors.margins: 1                   // inside the border
            radius: gridBg.radius - 1
            visible: Window.window ? Window.window.wallpaperBoard : false
            settings: Window.window ? Window.window.wallpaper : ({ url: "", blur: 0, opacity: 1, brightness: 1 })
        }
        // theme elements inside the box, behind the sounds
        Item {
            anchors.fill: parent
            anchors.margins: 1
            clip: true
            Repeater {
                model: Window.window && Window.window.themeElements ? Window.window.themeElements("boardBackground") : []
                // only while the Soundboard is the page on screen
                Loader { required property string modelData; anchors.fill: parent; active: root.visible && (!Window.window || Window.window.animate); source: modelData }
            }
        }
    }

    // The tiles. The clipping is done by this box-sized item, not by the grid, so the tiles' shadows are
    // only cut at the box's edges and the grid itself can sit anywhere inside it.
    Item {
        id: gridClip
        anchors.fill: gridBg
        clip: true
    }
    GridView {
        id: grid
        parent: gridClip
        // <tiles align="center">: the columns are centered in the box; otherwise they start on the left
        readonly property bool centered: !!(Window.window && Window.window.themed && Window.window.theme.tiles.align === "center")
        readonly property int columns: Math.max(1, Math.floor((gridClip.width - (centered ? 0 : 8)) / cellWidth))
        x: centered ? Math.max(0, Math.floor((gridClip.width - columns * cellWidth) / 2)) : 8
        // centered columns glide to their new place (e.g. while the key editor slides open) instead of jumping
        Behavior on x { enabled: grid.centered; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        y: 0
        width: centered ? columns * cellWidth : gridClip.width - 8
        height: gridClip.height
        clip: false
        cellWidth: root.tileW + 24
        cellHeight: root.tileH + 24
        model: visualModel
        boundsBehavior: Flickable.StopAtBounds
        boundsMovement: Flickable.StopAtBounds
        rebound: Transition { NumberAnimation { properties: "x,y"; duration: 0 } }
        flickDeceleration: 4000
        maximumFlickVelocity: 2500
        bottomMargin: root.selCount > 0 ? 70 : 0
        interactive: false          // no click-and-drag scrolling; wheel + scroll bar only
    }

    Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
        anchors.centerIn: gridClip
        anchors.verticalCenterOffset: 60
        visible: searchField.text.trim() !== "" && soundsModel.count <= 1
        text: qsTr("No sounds match “%1”").arg(searchField.text.trim())
        opacity: 0.55
        font.pixelSize: 15
    }

    // ----- bulk actions (visible while something is selected)
    Rectangle {
        id: bulkBar
        visible: root.selCount > 0
        anchors.horizontalCenter: gridBg.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 12
        width: bulkRow.implicitWidth + 28
        height: 50
        radius: Window.window && Window.window.controlRadius ? Math.min(Window.window.controlRadius(50, 14), 25) : 14
        color: Window.window && Window.window.glassOn ? Window.window.themeColor("menu", palette.toolTipBase) : palette.toolTipBase
        border.width: Window.window && Window.window.edge ? Window.window.edge(1) : 1
        border.color: palette.mid
        GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius }
        Shadow { z: -2 }
        RowLayout {
            id: bulkRow
            anchors.centerIn: parent
            spacing: 8
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                text: qsTr("%1 selected").arg(root.selCount)
                color: palette.toolTipText
                Layout.rightMargin: 6
            }
            EbButton { text: qsTr("Select all"); onClicked: root.selectAll() }
            EbButton { text: qsTr("Clear"); onClicked: root.clearSelection() }
            EbButton { text: qsTr("Delete"); danger: true; onClicked: root.deleteRequested(root.selectedIds()) }
        }
    }

    DelegateModel {
        id: visualModel
        model: soundsModel

        delegate: DropArea {
            id: dropArea
            width: grid.cellWidth
            height: grid.cellHeight
            property int visualIndex: DelegateModel.itemsIndex

            onEntered: function (drag) {
                // files dragged in from outside are handled by the board-wide drop area
                if (!drag.source || drag.hasUrls) { drag.accepted = false; return }
                var from = drag.source.visualIndex
                var to = dropArea.visualIndex
                if (to < 1 || from < 1 || from === to) return   // "+" tile stays first
                visualModel.items.move(from, to)
            }

            // "+" tile
            Rectangle {
                visible: model.kind === "add"
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: root.tileW
                height: root.tileH
                radius: Window.window && Window.window.themed && Window.window.theme.tiles.radius >= 0 ? Window.window.theme.tiles.radius : 18
                GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius; tile: true }
                Shadow { z: -2 }
                Sheen { anchors.fill: parent; radius: parent.radius }
                color: addArea.containsMouse ? root.ink(0.13) : root.ink(0.07)
                border.width: (Window.window && Window.window.edge ? Window.window.edge(1) : 1)
                border.color: addArea.containsMouse ? palette.highlight : root.ink(0.18)
                Behavior on color { ColorAnimation { duration: 100 } }

                Column {
                    anchors.centerIn: parent
                    spacing: 6
                    Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "+"
                        font.pixelSize: 80
                        font.weight: Font.Thin
                        color: palette.windowText
                        opacity: 0.8
                    }
                    Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: qsTr("Add sound")
                        font.pixelSize: 14
                        color: palette.windowText
                        opacity: 0.6
                    }
                }
                MouseArea {
                    id: addArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.addRequested()
                }
            }

            SoundTile {
                id: tile
                visible: model.kind === "sound"
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: root.tileW
                height: root.tileH

                sid: model.sid
                name: model.sname
                image: model.image
                hotkey: model.hotkey
                showId: root.showIds && (!root.themeTiles || root.themeTiles.ids)
                color: model.tcolor
                looping: model.looping
                selected: !!root.selected[model.sid]
                selectionActive: root.selCount > 0
                isPlaying: root.playing.indexOf(model.sid) >= 0
                progress: root.progressMap[model.sid] || 0
                draggable: root.canReorder && model.kind === "sound"
                dragParent: root

                onSelectRequested: function (mods) { root.tileClicked(model.sid, mods) }
                onEditRequested: root.editRequested({
                    id: model.sid, name: model.sname, path: model.path, image: model.image,
                    volume: model.volume, "loop": model.looping, hotkey: model.hotkey,
                    color: model.tcolor
                })
                onDropped: {
                    // visualIndex counts the "+" tile, the saved order does not
                    if (dropArea.visualIndex >= 1)
                        root.backend.moveSound(model.sid, dropArea.visualIndex - 1)
                }
            }

            Binding { target: tile; property: "visualIndex"; value: dropArea.visualIndex }
        }
    }

    // highlight while audio files are dragged over the board
    Rectangle {
        anchors.fill: gridBg
        radius: gridBg.radius
        visible: fileDrop.containsDrag
        z: 20
        color: Qt.rgba(palette.highlight.r, palette.highlight.g, palette.highlight.b, 0.18)
        border.width: 3
        border.color: palette.highlight
        Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
            anchors.centerIn: parent
            text: root.dropCount === 1 ? qsTr("Drop to import 1 sound") : qsTr("Drop to import %1 sounds").arg(root.dropCount)
            color: palette.windowText
            font.pixelSize: 20
            font.weight: Font.DemiBold
        }
    }
}
