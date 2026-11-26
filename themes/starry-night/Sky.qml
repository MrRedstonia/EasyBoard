import QtQuick

// Starry Night background: a night-sky gradient, twinkling stars and now and then a shooting star.
Item {
    id: sky
    readonly property real speed: Window.window && Window.window.animSpeed > 0 ? Window.window.animSpeed : 1

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#050818" }
            GradientStop { position: 0.55; color: "#0e1640" }
            GradientStop { position: 1.0; color: "#1c2462" }
        }
    }

    Repeater {
        model: 110
        Rectangle {
            required property int index
            // fixed, scattered places (as fractions), so the sky doesn't jump when the window is resized
            readonly property real fx: ((index * 7919) % 1000) / 1000
            readonly property real fy: ((index * 104729) % 997) / 997
            x: Math.round(fx * sky.width)
            y: Math.round(fy * sky.height)
            width: index % 11 === 0 ? 3 : (index % 3 === 0 ? 2 : 1.5)
            height: width
            radius: width / 2
            color: index % 6 === 0 ? "#ffe6a8" : "#ffffff"
            opacity: 0.4
            SequentialAnimation on opacity {
                loops: Animation.Infinite
                PauseAnimation { duration: ((index * 137) % 4000) / sky.speed }
                NumberAnimation { to: 1; duration: (1400 + (index * 53) % 1800) / sky.speed; easing.type: Easing.InOutSine }
                NumberAnimation { to: 0.2; duration: (1400 + (index * 71) % 1800) / sky.speed; easing.type: Easing.InOutSine }
            }
        }
    }

    // shooting star: a short bright streak crossing part of the sky
    Item {
        id: shooter
        property real sx: 0
        property real sy: 0
        width: 140
        height: 2
        rotation: 24
        opacity: 0
        Rectangle {
            anchors.fill: parent
            radius: 1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: "#ffffff" }
            }
        }
    }
    ParallelAnimation {
        id: shoot
        NumberAnimation { target: shooter; property: "x"; from: shooter.sx; to: shooter.sx + 420; duration: 900 / sky.speed; easing.type: Easing.InQuad }
        NumberAnimation { target: shooter; property: "y"; from: shooter.sy; to: shooter.sy + 190; duration: 900 / sky.speed; easing.type: Easing.InQuad }
        SequentialAnimation {
            NumberAnimation { target: shooter; property: "opacity"; from: 0; to: 1; duration: 200 / sky.speed }
            NumberAnimation { target: shooter; property: "opacity"; to: 0; duration: 700 / sky.speed }
        }
    }
    Timer {
        interval: 9000 / sky.speed
        repeat: true
        running: true
        onTriggered: {
            shooter.sx = Math.random() * sky.width * 0.7
            shooter.sy = Math.random() * sky.height * 0.35
            shoot.restart()
        }
    }
}
