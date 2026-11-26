import QtQuick
import QtQuick.Dialogs

// A file dialog that always looks like the system's own, never like the EasyBoard theme.
// Open it with openDialog() (not open()).
FileDialog {
    id: dialog
    property var backend
    function openDialog() {
        if (backend) backend.dialogPalette(true)
        open()
    }
    onVisibleChanged: if (!visible && backend) backend.dialogPalette(false)
}
