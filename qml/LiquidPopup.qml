import QtQuick
import QtQuick.Controls

// A menu that opens like a drop of liquid when `animated` (the theme's <controls menuAnimation="true">):
// it falls open from the top, narrower and squashed at first, stretches a touch past its size and
// springs back, while fading in. It closes with a quick fade. Without `animated` it simply appears.
Popup {
    id: pop
    property bool animated: false
    property real drop: 1                        // 0 = just starting to open, 1 = open
    readonly property real yStretch: 0.5 + 0.5 * drop
    readonly property real xStretch: 0.9 + 0.1 * drop

    property Scale backgroundScale: Scale { origin.x: pop.width / 2; origin.y: 0; xScale: pop.xStretch; yScale: pop.yStretch }
    property Scale contentScale: Scale { origin.x: pop.availableWidth / 2; origin.y: 0; xScale: pop.xStretch; yScale: pop.yStretch }
    function applyScales() {
        if (background) background.transform = [backgroundScale]
        if (contentItem) contentItem.transform = [contentScale]
    }
    onBackgroundChanged: applyScales()
    onContentItemChanged: applyScales()
    Component.onCompleted: applyScales()
    onAboutToShow: if (!animated) drop = 1

    // (a popup ignores a transition's `enabled`: without `animated` it gets no transition at all)
    enter: animated ? liquidEnter : null
    exit: animated ? liquidExit : null
    property Transition liquidEnter: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 160; easing.type: Easing.OutCubic }
        SpringAnimation { property: "drop"; from: 0; to: 1; spring: 4.5; damping: 0.3; epsilon: 0.002 }
    }
    property Transition liquidExit: Transition {
        NumberAnimation { property: "opacity"; to: 0; duration: 120 }
        NumberAnimation { property: "drop"; to: 0.85; duration: 120; easing.type: Easing.InCubic }
    }
}
