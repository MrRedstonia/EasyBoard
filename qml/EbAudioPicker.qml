import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Select File" button that opens a menu: sounds downloaded from the Sound Library (searchable)
// and, fixed at the bottom, a button that opens the normal file dialog for a custom file.
EbButton {
    id: root
    property var backend
    property var items: []
    signal picked(string path)
    signal customRequested()

    text: qsTr("Select File")

    // reads as a drop-down: room on the right for a chevron
    leftPadding: 12
    rightPadding: 26
    implicitWidth: Math.max(84, labelMetrics.advanceWidth + 12 + 26)
    TextMetrics { id: labelMetrics; font: root.font; text: root.text }
    Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
        anchors.right: parent.right
        anchors.rightMargin: 9
        anchors.verticalCenter: parent.verticalCenter
        text: "▾"
        font.pixelSize: 16
        color: root.accent ? palette.highlightedText : root.ink(0.7)
    }

    // What to show for a chosen file: just the file name for sounds in the library folder,
    // the full path for anything else.
    function shownPath(p) {
        if (!p) return ""
        if (backend && backend.isLibraryFile(p)) {
            var n = p.replace(/\\/g, "/")
            return n.substring(n.lastIndexOf("/") + 1)
        }
        return p
    }
    function isLibrary(p) { return !!p && shownPath(p) !== p }
    Component.onCompleted: items = backend ? JSON.parse(backend.librarySounds()) : []

    readonly property bool menuOpen: pop.opened
    function close() { pop.close() }
    function reload() {
        items = backend ? JSON.parse(backend.librarySounds()) : []
        search.text = ""
    }
    readonly property var filtered: {
        var q = search.text.trim().toLowerCase()
        return items.filter(function (i) { return q === "" || i.name.toLowerCase().indexOf(q) >= 0 })
    }

    // the menu must not stay open when its page / panel goes away
    onVisibleChanged: if (!visible) pop.close()
    onClicked: { if (pop.opened) pop.close(); else { reload(); pop.open() } }

    // menus open like liquid (<controls menuAnimation="true">); read here, a popup can't see the window
    readonly property bool menuAnim: !!(Window.window && Window.window.menuAnimation)
    // The menu opens from this invisible, never-moving stand-in for the button at its normal size (it
    // undoes the button's own grow / sink scale), so the button may grow while the menu stays put.
    Item {
        id: popupAnchor
        anchors.fill: parent
        scale: root.scale > 0 ? 1 / root.scale : 1
    }
    LiquidPopup {
        id: pop
        parent: popupAnchor
        animated: root.menuAnim
        y: root.height + 11
        x: root.width - width
        width: 270
        height: 300
        padding: 10
        // pressing the button itself must not count as "outside", so its click can close the menu
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        background: Rectangle {
            radius: 12
            // a glass theme's menu color over glass, like the other menus
            color: Window.window && Window.window.glassOn ? Window.window.themeColor("menu", palette.base)
                 : Window.window && Window.window.popupFill ? Window.window.popupFill(Qt.tint(Window.window.opaqueWindow, root.ink(0.08))) : Qt.tint(palette.window, root.ink(0.08))
            border.width: Window.window && Window.window.edge ? Window.window.edge(1) : 1
            GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius }
            Shadow { z: -2 }
            border.color: root.ink(0.16)
        }
        contentItem: ColumnLayout {
            spacing: 8
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Downloaded"); font.weight: Font.DemiBold; opacity: 0.75 }
            EbField {
                id: search
                Layout.fillWidth: true
                implicitHeight: 34
                placeholderText: qsTr("Search downloaded sounds…")
            }
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ListView {
                    id: list
                    anchors.fill: parent
                    clip: true
                    interactive: false
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.filtered
                    ScrollBar.vertical: EbScrollBar {}
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        width: list.width - 10
                        height: 32
                        radius: 8
                        color: rowMouse.containsMouse ? root.ink(0.10) : "transparent"
                        Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                            anchors.left: parent.left; anchors.leftMargin: 8
                            anchors.right: parent.right; anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.name
                            elide: Text.ElideRight
                            color: palette.windowText
                            font.pixelSize: 13
                        }
                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: { pop.close(); root.picked(row.modelData.path) }
                        }
                    }
                }
                EbWheel { anchors.fill: parent; flick: list; rowHeight: 32; rowsPerNotch: 1.5 }
                Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
                    anchors.centerIn: parent
                    visible: root.filtered.length === 0
                    opacity: 0.5
                    text: root.items.length === 0 ? qsTr("No downloaded sounds yet") : qsTr("No matches")
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.ink(0.14) }
            Label { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; text: qsTr("Custom"); font.weight: Font.DemiBold; opacity: 0.75 }
            EbButton {
                Layout.fillWidth: true
                implicitHeight: 36
                text: qsTr("Select file…")
                onClicked: { pop.close(); root.customRequested() }
            }
        }
    }
}
