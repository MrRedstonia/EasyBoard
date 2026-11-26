import QtQuick
import QtQuick.Effects

// The background picture (Settings > Appearance), cropped to fill the item, with the chosen blur,
// opacity and brightness. `radius` > 0 rounds its corners.
Item {
    id: root
    // { url, blur 0..1, opacity 0..1, brightness 0..2 (1 = unchanged) }
    property var settings: ({ url: "", blur: 0, opacity: 1, brightness: 1 })
    property real radius: 0
    // Blurring blends in pixels from outside the picture. Mirrored copies of the picture are laid
    // around it (this far) so the edges blend with real color instead of fading out; the picture
    // itself keeps its size, so blurring never zooms in.
    readonly property real pad: settings.blur > 0 ? Math.ceil(settings.blur * 64) + 4 : 0

    visible: settings.url !== ""
    opacity: settings.opacity

    Item {
        id: content
        anchors.fill: parent
        clip: true
        // rounded corners: the drawn picture is masked by a rounded rectangle
        layer.enabled: root.radius > 0
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: maskItem
        }

        Item {
            id: padded
            x: -root.pad
            y: -root.pad
            width: root.width + 2 * root.pad
            height: root.height + 2 * root.pad
            visible: false
            layer.enabled: true

            Repeater {
                model: root.pad > 0 ? 9 : 1      // the picture, plus its 8 mirrored neighbors when blurred
                Image {
                    required property int index
                    readonly property int col: root.pad > 0 ? index % 3 - 1 : 0
                    readonly property int row: root.pad > 0 ? Math.floor(index / 3) - 1 : 0
                    x: root.pad + col * root.width
                    y: root.pad + row * root.height
                    width: root.width
                    height: root.height
                    mirror: col !== 0
                    mirrorVertically: row !== 0
                    source: root.settings.url        // one load: the copies share the cached picture
                    asynchronous: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 2560             // plenty for a background, keeps big photos light
                    mipmap: true
                }
            }
        }
        MultiEffect {
            x: padded.x
            y: padded.y
            width: padded.width
            height: padded.height
            source: padded
            autoPaddingEnabled: false
            blurEnabled: root.settings.blur > 0
            blur: root.settings.blur
            blurMax: 64
            brightness: root.settings.brightness - 1
        }
    }

    Item {
        id: maskItem
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle { anchors.fill: parent; radius: root.radius; color: "black" }
    }
}
