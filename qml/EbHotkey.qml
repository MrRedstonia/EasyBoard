import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Click-to-record hotkey field with a Clear button.
RowLayout {
    id: hk
    property string value: ""
    property bool capturing: false
    signal edited(string value)
    spacing: 8

    function keyName(ev) {
        var k = ev.key
        if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k)
        if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(k)
        if (k >= Qt.Key_F1 && k <= Qt.Key_F24) return "F" + (k - Qt.Key_F1 + 1)
        var map = {}
        map[Qt.Key_Space] = "Space"; map[Qt.Key_Return] = "Enter"; map[Qt.Key_Enter] = "Enter"
        map[Qt.Key_Tab] = "Tab"; map[Qt.Key_Backspace] = "Backspace"; map[Qt.Key_Insert] = "Insert"
        map[Qt.Key_Delete] = "Delete"; map[Qt.Key_Home] = "Home"; map[Qt.Key_End] = "End"
        map[Qt.Key_PageUp] = "PageUp"; map[Qt.Key_PageDown] = "PageDown"
        map[Qt.Key_Up] = "ArrowUp"; map[Qt.Key_Down] = "ArrowDown"
        map[Qt.Key_Left] = "ArrowLeft"; map[Qt.Key_Right] = "ArrowRight"
        map[Qt.Key_Minus] = "Minus"; map[Qt.Key_Equal] = "Equal"
        map[Qt.Key_Comma] = "Comma"; map[Qt.Key_Period] = "Period"
        map[Qt.Key_Slash] = "Slash"; map[Qt.Key_Semicolon] = "Semicolon"
        return map[k] || ""
    }

    EbButton {
        Layout.fillWidth: true
        accent: hk.capturing
        text: hk.capturing ? qsTr("Press a key combination…")
             : (hk.value !== "" ? (Window.window ? Window.window.prettyHotkey(hk.value) : hk.value) : qsTr("Click to record"))
        onClicked: { hk.capturing = true; forceActiveFocus() }
        onActiveFocusChanged: if (!activeFocus) hk.capturing = false
        Keys.onPressed: function (ev) {
            if (!hk.capturing) return
            if (ev.key === Qt.Key_Escape) { hk.capturing = false; ev.accepted = true; return }
            var name = hk.keyName(ev)
            if (name === "") { ev.accepted = true; return }
            var parts = []
            // macOS: Qt reports Command as "Control" and Control as "Meta"; stored as Super (Command) / Ctrl
            var mac = Qt.platform.os === "osx"
            if (ev.modifiers & (mac ? Qt.MetaModifier : Qt.ControlModifier)) parts.push("Ctrl")
            if (ev.modifiers & Qt.AltModifier) parts.push("Alt")
            if (ev.modifiers & Qt.ShiftModifier) parts.push("Shift")
            if (ev.modifiers & (mac ? Qt.ControlModifier : Qt.MetaModifier)) parts.push("Super")
            parts.push(name)
            hk.value = parts.join("+")
            hk.capturing = false
            ev.accepted = true
            hk.edited(hk.value)
        }
    }
    EbButton {
        text: qsTr("Clear")
        enabled: hk.value !== ""
        onClicked: { hk.value = ""; hk.edited("") }
    }
}
