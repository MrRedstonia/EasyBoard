import QtQuick
import QtQuick.Controls
import QtQuick.Layouts


// Sound library: browse / search MyInstants, and manage what has been downloaded into the "sounds" folder.
Item {
    id: root
    property var backend
    signal deleteRequested(string path, string name)
    signal revertRequested(string path, string name)

    property string tab: "browse"          // "browse" | "downloaded"
    property var st: ({ state: "idle", kind: "", query: "", message: "", items: [] })
    property var dl: []
    property string dlError: ""
    readonly property bool busy: st.state === "loading"
    // narrow windows: 2 columns below 800 px, 1 below 650 (0 = as many as fit, at least 3)
    readonly property int maxColumns: Window.width < 650 ? 1 : (Window.width < 800 ? 2 : 0)

    // small spinning circle shown on top of a button
    // (a theme can draw its own: <replace part="spinner">)
    component Spinner: Item {
        id: sp
        property bool shown: false
        readonly property string partUrl: Window.window && Window.window.part ? Window.window.part("spinner") : ""
        anchors.centerIn: parent
        width: 24
        height: 24
        visible: shown
        BusyIndicator { anchors.fill: parent; visible: sp.partUrl === ""; running: sp.shown && visible }
        Loader { anchors.fill: parent; active: sp.shown && sp.partUrl !== ""; source: sp.partUrl }
    }

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    // The cards live in list models that are updated in place: only values that changed are touched,
    // so the cards (and everything in them) are kept instead of being rebuilt on every poll.
    ListModel { id: browseModel }
    ListModel { id: dlModel }
    function syncModel(model, items) {
        for (var i = 0; i < items.length; i++) {
            if (i < model.count) {
                var row = model.get(i)
                for (var k in items[i]) if (row[k] !== items[i][k]) model.setProperty(i, k, items[i][k])
            } else {
                model.append(items[i])
            }
        }
        while (model.count > items.length) model.remove(model.count - 1)
    }
    property string lastStateRaw: ""
    property string lastDlRaw: ""
    function refreshState() {
        if (!backend) return
        try {
            if (tab === "browse") {
                var raw = backend.libState()
                if (raw === lastStateRaw) return      // nothing new: leave everything as it is
                lastStateRaw = raw
                st = JSON.parse(raw)
                syncModel(browseModel, st.items)
            } else {
                var rawDl = backend.libDownloaded()
                if (rawDl === lastDlRaw) return
                lastDlRaw = rawDl
                dl = JSON.parse(rawDl)
            }
        } catch (e) {}
    }
    onDlFilteredChanged: syncModel(dlModel, dlFiltered)
    function runSearch() {
        if (!backend || tab !== "browse") return
        var q = searchField.text.trim()
        if (q === "") backend.libTrending(); else backend.libSearch(q)
        refreshState()
    }
    function setTab(t) {
        if (tab === t) return
        if (backend) backend.libStopPreview()
        tab = t
        searchField.text = ""
        dlError = ""
        refreshState()
    }
    readonly property var dlFiltered: {
        var q = searchField.text.trim().toLowerCase()
        return dl.filter(function (d) { return q === "" || d.name.toLowerCase().indexOf(q) >= 0 })
    }

    onVisibleChanged: {
        if (!visible && backend) backend.libStopPreview()
        if (!visible || !backend) return
        refreshState()
        if (tab === "browse" && st.state === "idle") { backend.libTrending(); refreshState() }
    }
    // Poll while the page is open (results arrive from a background thread).
    Timer {
        interval: 300
        repeat: true
        running: root.visible
        onTriggered: root.refreshState()
    }

    EbWheel { anchors.fill: parent; flick: scroll }

    Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight + 24
        clip: true
        interactive: false          // wheel + scroll bar only, no click-and-drag scrolling
        boundsBehavior: Flickable.StopAtBounds
        boundsMovement: Flickable.StopAtBounds
        rebound: Transition { NumberAnimation { properties: "x,y"; duration: 0 } }
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: EbScrollBar {}

        ColumnLayout {
            id: col
            // the scroll bar takes 12 px from the right when it is shown (only then do the cards change size)
            readonly property bool scrollable: scroll.contentHeight > scroll.height + 0.5
            x: 32
            width: Math.min(scroll.width - 64 - (scrollable ? 12 : 0), 1600)
            spacing: 14

            Item { Layout.preferredHeight: 14 }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Sound library"); font.pixelSize: 30; font.weight: Font.Light }

            // ---- sub-tabs
            RowLayout {
                spacing: 8
                EbButton {
                    text: qsTr("Browse")
                    implicitHeight: 38
                    accent: root.tab === "browse"
                    onClicked: root.setTab("browse")
                }
                EbButton {
                    text: qsTr("Downloaded")
                    implicitHeight: 38
                    accent: root.tab === "downloaded"
                    onClicked: root.setTab("downloaded")
                }
            }

            // ---- search (Browse) / filter (Downloaded)
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                EbField {
                    id: searchField
                    Layout.fillWidth: true
                    placeholderText: root.tab === "browse" ? qsTr("Search sounds…") : qsTr("Filter downloaded sounds…")
                    onAccepted: root.runSearch()
                }
                EbButton {
                    visible: root.tab === "browse"
                    text: qsTr("Search")
                    accent: true
                    implicitHeight: 42
                    enabled: !root.busy
                    onClicked: root.runSearch()
                }
            }

            // =================== BROWSE ===================
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                visible: root.tab === "browse"
                Layout.fillWidth: true
                font.pixelSize: 17
                font.weight: Font.DemiBold
                Layout.topMargin: 4
                elide: Text.ElideRight
                text: root.st.kind === "search" ? qsTr("Results for “%1”").arg(root.st.query)
                    : root.st.kind === "trending" ? qsTr("Trending") : qsTr("Sounds")
            }

            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                visible: root.tab === "browse" && (root.busy || root.st.state === "error" || (root.st.state === "done" && root.st.items.length === 0))
                wrapMode: Text.Wrap
                opacity: 0.6
                color: root.st.state === "error" ? "#e5484d" : palette.windowText
                text: root.busy ? qsTr("Loading…")
                    : root.st.state === "error" ? root.st.message
                    : qsTr("No sounds found.")
            }

            Flow {
                id: grid
                visible: root.tab === "browse"
                Layout.fillWidth: true
                readonly property real minCard: 310
                readonly property int columns: root.maxColumns > 0 ? root.maxColumns : Math.max(3, Math.floor((col.width + spacing) / (minCard + spacing)))
                readonly property real cardW: Math.floor((col.width - (columns - 1) * spacing) / columns)
                spacing: 12

                Repeater {
                    model: root.tab === "browse" ? browseModel : null
                    delegate: Rectangle {
                        id: card
                        // the row of the list model (updated in place, so the card itself stays)
                        required property var model
                        readonly property var modelData: model
                        width: grid.cardW
                        height: 190
                        radius: 14
                        color: Window.window && Window.window.solid ? Window.window.solid(((Window.window && Window.window.tintOn) ? Window.window.tintFill(0) : root.ink(0.06))) : root.ink(0.06)
                        border.width: 1
                        border.color: root.ink(0.14)

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 14
                            spacing: 6

                            Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                                Layout.fillWidth: true
                                text: card.modelData.title
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                font.pixelSize: 18
                                font.weight: Font.DemiBold
                                color: palette.windowText
                            }
                            Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                visible: true
                                text: card.modelData.description
                                wrapMode: Text.Wrap
                                maximumLineCount: 3
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignTop
                                font.pixelSize: 13
                                color: root.ink(0.6)
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                EbButton {
                                    implicitWidth: 78
                                    implicitHeight: 40
                                    text: card.modelData.preview === "playing" ? qsTr("Stop")
                                        : card.modelData.preview === "loading" ? "" : qsTr("Play")
                                    onClicked: root.backend.libPreview(card.modelData.id, card.modelData.mp3)
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 500
                                    ToolTip.text: qsTr("Only you hear the preview")
                                    Spinner { shown: card.modelData.preview === "loading" }
                                }
                                EbButton {
                                    Layout.fillWidth: true
                                    implicitHeight: 40
                                    accent: card.modelData.status === "none" || card.modelData.status === "error"
                                    enabled: card.modelData.status === "none" || card.modelData.status === "error"
                                    text: card.modelData.status === "done" ? qsTr("Downloaded ✓")
                                        : card.modelData.status === "loading"
                                            ? (card.modelData.progress >= 0 ? Math.round(card.modelData.progress * 100) + "%" : "")
                                        : card.modelData.status === "error" ? qsTr("Retry")
                                        : qsTr("Download")
                                    onClicked: root.backend.libDownload(card.modelData.id, card.modelData.title, card.modelData.mp3)
                                    ToolTip.visible: hovered && card.modelData.error !== ""
                                    ToolTip.text: card.modelData.error
                                    Spinner { shown: card.modelData.status === "loading" && card.modelData.progress < 0 }
                                }
                            }
                            // download progress (a theme can draw its own: <replace part="downloadProgress">)
                            Loader {
                                id: dlPart
                                readonly property string partUrl: Window.window && Window.window.part ? Window.window.part("downloadProgress") : ""
                                Layout.fillWidth: true
                                Layout.preferredHeight: item ? Math.max(4, item.implicitHeight) : 4
                                active: partUrl !== "" && card.modelData.status === "loading"
                                visible: active
                                source: partUrl
                                Binding { target: dlPart.item; property: "progress"; value: card.modelData.progress; when: dlPart.status === Loader.Ready }
                            }
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 4
                                radius: 2
                                visible: card.modelData.status === "loading" && dlPart.partUrl === ""
                                color: root.ink(0.12)
                                Rectangle {
                                    height: parent.height
                                    radius: 2
                                    color: palette.highlight
                                    width: parent.width * Math.max(0.03, card.modelData.progress)
                                    Behavior on width { NumberAnimation { duration: 150 } }
                                }
                            }
                        }
                    }
                }
            }

            EbButton {
                Layout.alignment: Qt.AlignHCenter
                visible: root.tab === "browse" && root.st.state === "done" && !!root.st.hasNext
                enabled: !root.st.loadingMore
                text: root.st.loadingMore ? "" : qsTr("Load more")
                onClicked: root.backend.libMore()
                Spinner { shown: !!root.st.loadingMore }
            }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                visible: root.tab === "browse" && root.st.state === "done" && root.st.message !== ""
                wrapMode: Text.Wrap
                color: "#e5484d"
                text: root.st.message
            }

            // =================== DOWNLOADED ===================
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                visible: root.tab === "downloaded"
                Layout.fillWidth: true
                Layout.topMargin: 4
                font.pixelSize: 17
                font.weight: Font.DemiBold
                text: qsTr("Downloaded sounds")
            }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                visible: root.tab === "downloaded" && root.dlFiltered.length === 0
                opacity: 0.6
                wrapMode: Text.Wrap
                text: root.dl.length === 0 ? qsTr("Nothing downloaded yet. Sounds you download show up here.") : qsTr("No matches.")
            }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                visible: root.tab === "downloaded" && root.dlError !== ""
                wrapMode: Text.Wrap
                color: "#e5484d"
                text: root.dlError
            }

            Flow {
                id: dgrid
                visible: root.tab === "downloaded"
                Layout.fillWidth: true
                readonly property real minCard: 310
                readonly property int columns: root.maxColumns > 0 ? root.maxColumns : Math.max(3, Math.floor((col.width + spacing) / (minCard + spacing)))
                readonly property real cardW: Math.floor((col.width - (columns - 1) * spacing) / columns)
                spacing: 12

                Repeater {
                    model: root.tab === "downloaded" ? dlModel : null
                    delegate: Rectangle {
                        id: dcard
                        required property var model
                        readonly property var modelData: model
                        property bool renaming: false
                        width: dgrid.cardW
                        height: 190
                        radius: 14
                        color: Window.window && Window.window.solid ? Window.window.solid(((Window.window && Window.window.tintOn) ? Window.window.tintFill(0) : root.ink(0.06))) : root.ink(0.06)
                        border.width: 1
                        border.color: root.ink(0.14)

                        function commitRename() {
                            var err = root.backend.libRename(modelData.path, renameField.text)
                            root.dlError = err
                            if (err === "") renaming = false
                            root.refreshState()
                        }

                        // revert to the original download (only when the sound was edited)
                        EbButton {
                            id: revertBtn
                            z: 2
                            visible: !dcard.renaming
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.topMargin: 8
                            anchors.rightMargin: 8
                            implicitWidth: 32
                            implicitHeight: 32
                            leftPadding: 0; rightPadding: 0
                            enabled: dcard.modelData.edited && !dcard.modelData.reverting
                            onClicked: root.revertRequested(dcard.modelData.path, dcard.modelData.name)
                            Image {
                                anchors.centerIn: parent
                                width: 18; height: 18
                                sourceSize: Qt.size(36, 36)
                                visible: !dcard.modelData.reverting
                                opacity: revertBtn.enabled ? 1 : 0.3
                                source: Window.window ? Window.window.iconFor("revert", palette.windowText) : ""
                                fillMode: Image.PreserveAspectFit
                            }
                            Spinner {
                                width: 22; height: 22
                                shown: !!dcard.modelData.reverting
                            }
                            ToolTip.visible: hovered
                            ToolTip.delay: 400
                            ToolTip.text: qsTr("Revert sound to its original version")
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 14
                            spacing: 6

                            Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                                visible: !dcard.renaming
                                Layout.fillWidth: true
                                Layout.rightMargin: 36      // room for the revert button
                                text: dcard.modelData.name
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                font.pixelSize: 18
                                font.weight: Font.DemiBold
                                color: palette.windowText
                            }
                            EbField {
                                id: renameField
                                visible: dcard.renaming
                                Layout.fillWidth: true
                                implicitHeight: 40
                                text: dcard.modelData.name
                                onAccepted: dcard.commitRename()
                            }
                            Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                text: dcard.modelData.description
                                wrapMode: Text.Wrap
                                maximumLineCount: 3
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignTop
                                font.pixelSize: 13
                                color: root.ink(0.6)
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                EbButton {
                                    visible: !dcard.renaming
                                    implicitWidth: 78
                                    implicitHeight: 40
                                    text: dcard.modelData.preview === "playing" ? qsTr("Stop")
                                        : dcard.modelData.preview === "loading" ? "" : qsTr("Play")
                                    onClicked: root.backend.libPreviewFile(dcard.modelData.path)
                                    Spinner { shown: dcard.modelData.preview === "loading" }
                                }
                                EbButton {
                                    visible: !dcard.renaming
                                    Layout.fillWidth: true
                                    implicitHeight: 40
                                    text: qsTr("Rename")
                                    onClicked: { renameField.text = dcard.modelData.name; root.dlError = ""; dcard.renaming = true; renameField.forceActiveFocus(); renameField.selectAll() }
                                }
                                EbButton {
                                    visible: !dcard.renaming
                                    Layout.fillWidth: true
                                    implicitHeight: 40
                                    danger: true
                                    text: qsTr("Delete")
                                    onClicked: root.deleteRequested(dcard.modelData.path, dcard.modelData.name)
                                }
                                EbButton {
                                    visible: dcard.renaming
                                    Layout.fillWidth: true
                                    implicitHeight: 40
                                    accent: true
                                    text: qsTr("Save")
                                    onClicked: dcard.commitRename()
                                }
                                EbButton {
                                    visible: dcard.renaming
                                    Layout.fillWidth: true
                                    implicitHeight: 40
                                    text: qsTr("Cancel")
                                    onClicked: { dcard.renaming = false; root.dlError = "" }
                                }
                            }
                        }
                    }
                }
            }

            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                Layout.fillWidth: true
                Layout.topMargin: 6
                visible: root.tab === "browse"
                wrapMode: Text.Wrap
                opacity: 0.5
                font.pixelSize: 12
                text: qsTr("Sounds come from myinstants.com (through its public API). Downloads are saved in the sounds folder and show up under “Downloaded” when you pick an audio file.")
            }
        }
    }
}
