import QtQuick
import QtQuick.Controls

// Themed drop-down. Works with a JS array of strings or of objects (+ textRole).
ComboBox {
    id: control

    function ink(a) { return Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, a) }

    // a menu must not stay open when its page is switched away or hidden
    onVisibleChanged: if (!visible) popup.close()

    property int arrowSize: 16
    implicitHeight: 42
    font.pixelSize: 14
    hoverEnabled: true
    // menus fade in and out (<controls menuAnimation="true">); read here, Transitions can't see the window
    readonly property bool menuAnim: !!(Window.window && Window.window.menuAnimation)
    // While its menu is open the drop-down keeps its normal size and doesn't animate: the menu hangs
    // from it, and a drop-down that still grows or shrinks would drag the menu along (it "shifted").
    // a theme can make it grow under the mouse and sink when pressed, like the buttons
    scale: Window.window && Window.window.controlScale ? Window.window.controlScale(control.hovered, control.pressed, control.width) : 1
    Behavior on scale { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
    // The menu opens from this invisible, never-moving stand-in for the control at its normal size
    // (it undoes the control's own scale), so the control may grow and sink while the menu stays put.
    Item {
        id: popupAnchor
        anchors.fill: parent
        scale: control.scale > 0 ? 1 / control.scale : 1
    }


    delegate: ItemDelegate {
        id: item
        required property int index
        width: control.width - 8
        height: 38
        highlighted: control.highlightedIndex === index
        contentItem: Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
            text: control.textAt(item.index)
            font: control.font
            color: item.highlighted && !(Window.window && Window.window.themed && Window.window.theme.colors.selection) ? palette.highlightedText : palette.windowText
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            leftPadding: 6
        }
        // the row under the mouse: the theme's selection color (<colors selection>), or the accent
        background: Rectangle {
            radius: Window.window && Window.window.controlRadius ? Window.window.controlRadius(height, 8) : 8
            color: item.highlighted ? (Window.window && Window.window.themeColor ? Window.window.themeColor("selection", palette.highlight) : palette.highlight) : "transparent"
        }
    }

    // a drawn triangle, so it is centered exactly (a text glyph sits off-center in its line box)
    indicator: Canvas {
        id: arrow
        readonly property color ink: control.ink(0.6)
        width: Math.round(control.arrowSize * 0.75)
        height: Math.round(control.arrowSize * 0.42)
        x: control.width - width - 16
        y: Math.round((control.height - height) / 2)
        opacity: control.enabled ? 1 : 0.4
        onInkChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.fillStyle = arrow.ink
            ctx.beginPath()
            ctx.moveTo(0, 0)
            ctx.lineTo(width, 0)
            ctx.lineTo(width / 2, height)
            ctx.closePath()
            ctx.fill()
        }
    }

    contentItem: Text { style: Window.window && Window.window.textShadow ? Text.Outline : Text.Normal; styleColor: Window.window && Window.window.textShadowColor ? Window.window.textShadowColor : "transparent"; 
        leftPadding: 14
        rightPadding: 38
        text: control.displayText
        font: control.font
        color: control.currentIndex < 0 ? control.ink(0.45) : palette.windowText
        opacity: control.enabled ? 1 : 0.4
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    background: Rectangle {
        GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius; control: true }
        radius: Window.window && Window.window.controlRadius ? Window.window.controlRadius(height, 10) : 10
        // the same fill as every other button
        color: !Window.window || !Window.window.controlFill ? control.ink(control.hovered ? 0.13 : 0.08)
             : !control.enabled ? Window.window.solid(control.ink(0.05))
             : Window.window.controlFill(control.pressed ? 2 : control.hovered ? 1 : 0)
        border.width: control.visualFocus || control.popup.visible ? (Window.window && Window.window.focusEdge ? Window.window.focusEdge(2) : 2) : (Window.window && Window.window.edge ? Window.window.edge(1) : 1)
        Shadow { z: -2; lift: 3; opacity: strength * 0.6 }
        Sheen { anchors.fill: parent; radius: parent.radius }
        border.color: control.visualFocus || control.popup.visible ? palette.highlight
                    : Window.window && Window.window.themeColor ? Window.window.themeColor("controlBorder", control.ink(0.14)) : control.ink(0.14)
    }

    popup: LiquidPopup {
        animated: control.menuAnim
        parent: popupAnchor
        y: control.height + 4
        width: control.width
        implicitHeight: Math.min(contentItem.implicitHeight + 8, 300)
        padding: 4
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            ScrollIndicator.vertical: ScrollIndicator {}
        }
        background: Rectangle {
            GlassBackdrop { anchors.fill: parent; z: -1; radius: parent.radius }
            Shadow { z: -2 }
            radius: Window.window && Window.window.controlRadius ? Math.min(Window.window.controlRadius(999, 12), 20) : 12
            // a glass theme's menus: <colors menu>, see-through over the frosted glass
            color: Window.window && Window.window.themeColor ? Window.window.themeColor("menu", Window.window.popupFill(palette.base)) : palette.base
            border.width: Window.window && Window.window.edge ? Window.window.edge(1) : 1
            Sheen { anchors.fill: parent; radius: parent.radius; amount: 0.3 }
            border.color: Window.window && Window.window.themeColor ? Window.window.themeColor("border", control.ink(0.18)) : control.ink(0.18)
        }
    }
}
