import QtQuick

// Kitty background: a pink gradient with cats, bows, hearts and paws floating gently upwards.
Item {
    id: root
    clip: true
    readonly property real speed: Window.window && Window.window.animSpeed > 0 ? Window.window.animSpeed : 1

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#ffeaf3" }
            GradientStop { position: 1.0; color: "#ffd3e6" }
        }
    }

    Repeater {
        model: 18
        Item {
            id: floater
            required property int index
            // each one gets its own picture, size, lane, speed and start time
            readonly property string kind: ["cat.svg", "bow-pink.svg", "heart", "paw-pink.svg", "heart", "bow-pink.svg"][index % 6]
            readonly property real size: kind === "cat.svg" ? 54 + (index % 3) * 10 : 26 + (index % 4) * 6
            readonly property real lane: ((index * 397) % 1000) / 1000
            readonly property int travel: (22000 + (index * 1777) % 14000)
            width: size
            height: size
            x: lane * (root.width - size)
            opacity: 0.55
            Image {
                anchors.fill: parent
                visible: floater.kind !== "heart"
                source: floater.kind !== "heart" ? Qt.resolvedUrl(floater.kind) : ""
                sourceSize: Qt.size(floater.size * 2, floater.size * 2)
                fillMode: Image.PreserveAspectFit
                smooth: true
            }
            Text {
                anchors.centerIn: parent
                visible: floater.kind === "heart"
                text: "♥"
                color: "#ff7eb6"
                font.pixelSize: floater.size
            }
            // float up from below the window to above it, again and again. The first rise starts part
            // of the way up, so they are spread over the window from the beginning.
            readonly property real start: ((index * 613) % 1000) / 1000
            y: root.height + size
            SequentialAnimation {
                running: root.height > 0
                NumberAnimation {
                    target: floater; property: "y"
                    from: root.height * floater.start; to: -floater.size * 2
                    duration: floater.travel * Math.max(0.05, floater.start) / root.speed
                }
                NumberAnimation {
                    target: floater; property: "y"
                    from: root.height + floater.size; to: -floater.size * 2
                    duration: floater.travel / root.speed
                    loops: Animation.Infinite
                }
            }
            // a gentle sway
            SequentialAnimation on rotation {
                loops: Animation.Infinite
                NumberAnimation { from: -10; to: 10; duration: (2600 + floater.index * 150) / root.speed; easing.type: Easing.InOutSine }
                NumberAnimation { from: 10; to: -10; duration: (2600 + floater.index * 150) / root.speed; easing.type: Easing.InOutSine }
            }
        }
    }
}
