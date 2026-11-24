/*
    SPDX-FileCopyrightText: Veldmuis Linux
    SPDX-FileCopyrightText: 2014 Marco Martin <mart@kde.org>
    SPDX-License-Identifier: GPL-2.0-or-later

    Derived from the Breeze splash: same structure and animation timing, with
    the wordmark replacing the Plasma logo and colours taken from the active
    colour scheme instead of being hardcoded.
*/

import QtQuick
import org.kde.kirigami as Kirigami

Rectangle {
    id: root
    color: Kirigami.Theme.backgroundColor

    property int stage

    onStageChanged: {
        if (stage == 2) {
            introAnimation.running = true;
        } else if (stage == 5) {
            introAnimation.target = busyIndicator;
            introAnimation.from = 1;
            introAnimation.to = 0;
            introAnimation.running = true;
        }
    }

    Item {
        id: content
        anchors.fill: parent
        opacity: 0

        Column {
            id: wordmark
            anchors.centerIn: parent
            spacing: 0

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                color: Kirigami.Theme.highlightColor
                font.pixelSize: Kirigami.Units.gridUnit * 3
                font.weight: Font.Bold
                text: "Veldmuis"
                textFormat: Text.PlainText
                Accessible.name: text
                Accessible.role: Accessible.StaticText
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                color: Kirigami.Theme.textColor
                font.pixelSize: Kirigami.Units.gridUnit
                font.letterSpacing: Kirigami.Units.gridUnit * 0.25
                opacity: 0.7
                text: "Linux"
                textFormat: Text.PlainText
                Accessible.name: text
                Accessible.role: Accessible.StaticText
            }
        }

        Image {
            id: busyIndicator
            y: parent.height - (parent.height - wordmark.y) / 2 - height / 2
            anchors.horizontalCenter: parent.horizontalCenter
            asynchronous: true
            source: "images/busywidget.svgz"
            sourceSize.height: Kirigami.Units.gridUnit * 2
            sourceSize.width: Kirigami.Units.gridUnit * 2
            RotationAnimator on rotation {
                id: rotationAnimator
                from: 0
                to: 360
                // Not a standard duration: the splash spinner should not speed up
                // or slow down with the animation scaling preference.
                duration: 2000
                loops: Animation.Infinite
                running: Kirigami.Units.longDuration > 1
            }
        }
    }

    OpacityAnimator {
        id: introAnimation
        running: false
        target: content
        from: 0
        to: 1
        duration: Kirigami.Units.veryLongDuration * 2
        easing.type: Easing.InOutQuad
    }
}
