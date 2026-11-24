/*
 * SPDX-FileCopyrightText: no
 * SPDX-License-Identifier: CC0-1.0
 */

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: root

    width: 780
    height: 500
    color: "#201411"

    property bool syncing: true
    readonly property var chooserConfig: typeof config === "undefined" ? null : config

    // packagechooserq deletes its global storage key when packageChoice is empty, and
    // Calamares' shellprocess expansion treats a missing key as a fatal error. An
    // explicit token keeps "no extras" a defined state for the bootstrap job.
    readonly property string noSelectionToken: "None"

    function updateSelection() {
        if (syncing || chooserConfig === null) {
            return
        }

        var selected = []
        if (steam.checked) {
            selected.push("steam")
        }
        if (lutris.checked) {
            selected.push("lutris")
        }
        if (discord.checked) {
            selected.push("discord")
        }
        if (qbittorrent.checked) {
            selected.push("qbittorrent")
        }
        if (syncthing.checked) {
            selected.push("syncthing")
        }
        if (code.checked) {
            selected.push("code")
        }
        if (dotfiles.checked) {
            selected.push("dotfiles")
        }
        if (opencode.checked) {
            selected.push("opencode")
        }
        if (codex.checked) {
            selected.push("codex")
        }
        chooserConfig.packageChoice = selected.length > 0 ? selected.join(",") : noSelectionToken
    }

    function loadSelection() {
        var selected = []
        if (chooserConfig !== null && chooserConfig.packageChoice.length > 0) {
            selected = chooserConfig.packageChoice.split(",")
        }

        // "gaming" is the legacy grouped token; tick the individual applications.
        if (selected.indexOf("gaming") >= 0) {
            selected.push("steam", "lutris", "discord")
        }

        steam.checked = selected.indexOf("steam") >= 0
        lutris.checked = selected.indexOf("lutris") >= 0
        discord.checked = selected.indexOf("discord") >= 0
        qbittorrent.checked = selected.indexOf("qbittorrent") >= 0
        syncthing.checked = selected.indexOf("syncthing") >= 0
        code.checked = selected.indexOf("code") >= 0
        dotfiles.checked = selected.indexOf("dotfiles") >= 0
        opencode.checked = selected.indexOf("opencode") >= 0
        codex.checked = selected.indexOf("codex") >= 0
        syncing = false
        // Publish the normalized selection right away so the global storage key exists
        // even when the user leaves this page without toggling anything.
        updateSelection()
    }

    Component.onCompleted: loadSelection()

    component OptionRow: CheckBox {
        id: control

        property string title
        property string description

        width: parent ? parent.width : 0
        height: 68
        hoverEnabled: true
        text: ""

        indicator: Rectangle {
            width: 26
            height: 26
            x: 16
            y: (control.height - height) / 2
            radius: 5
            color: control.checked ? "#e59c3f" : "#201411"
            border.color: control.checked ? "#f5b85f" : "#80604d"
            border.width: 2

            Rectangle {
                anchors.centerIn: parent
                width: 11
                height: 11
                radius: 3
                color: "#201411"
                visible: control.checked
            }
        }

        background: Rectangle {
            radius: 6
            color: control.checked ? "#3a271d"
                                   : (control.hovered ? "#32211c" : "#2a1b17")
            border.color: control.checked ? "#e59c3f" : "#5a3a2a"
            border.width: control.checked ? 2 : 1
        }

        contentItem: Item {
            implicitWidth: 0
            implicitHeight: 0
        }

        Column {
            anchors.left: control.indicator.right
            anchors.leftMargin: 14
            anchors.right: control.right
            anchors.rightMargin: 16
            anchors.verticalCenter: control.verticalCenter
            spacing: 2

            Text {
                width: parent.width
                text: control.title
                color: "#fff6ed"
                font.pixelSize: 16
                font.bold: true
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: control.description
                color: "#c9b8aa"
                font.pixelSize: 13
                elide: Text.ElideRight
            }
        }

        onToggled: root.updateSelection()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 28
        spacing: 14

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            Label {
                text: qsTr("Optional software")
                color: "#fff6ed"
                font.pixelSize: 26
                font.bold: true
            }

            Label {
                Layout.fillWidth: true
                text: qsTr("Choose any extras you want included in the installed system. Each application is installed on its own.")
                color: "#c9b8aa"
                font.pixelSize: 14
                wrapMode: Text.WordWrap
            }
        }

        Flickable {
            id: scroller

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: optionColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
            }

            Column {
                id: optionColumn

                width: scroller.width
                spacing: 8

                Label {
                    width: parent.width
                    text: qsTr("Gaming")
                    color: "#e59c3f"
                    font.pixelSize: 13
                    font.bold: true
                    font.capitalization: Font.AllUppercase
                }

                OptionRow {
                    id: steam
                    title: qsTr("Steam")
                    description: qsTr("Game store and library")
                }

                OptionRow {
                    id: lutris
                    title: qsTr("Lutris")
                    description: qsTr("Game launcher for Wine, emulators, and native titles")
                }

                OptionRow {
                    id: discord
                    title: qsTr("Discord")
                    description: qsTr("Voice, video, and text chat")
                }

                Item {
                    width: parent.width
                    height: 8
                }

                Label {
                    width: parent.width
                    text: qsTr("Tools")
                    color: "#e59c3f"
                    font.pixelSize: 13
                    font.bold: true
                    font.capitalization: Font.AllUppercase
                }

                OptionRow {
                    id: qbittorrent
                    title: qsTr("qBittorrent")
                    description: qsTr("BitTorrent client")
                }

                OptionRow {
                    id: syncthing
                    title: qsTr("Syncthing")
                    description: qsTr("Continuous file sync between devices")
                }

                OptionRow {
                    id: code
                    title: qsTr("Visual Studio Code")
                    description: qsTr("Code editor")
                }

                OptionRow {
                    id: dotfiles
                    title: qsTr("Dotfiles restore")
                    description: qsTr("chezmoi and the restore helper")
                }

                Item {
                    width: parent.width
                    height: 8
                }

                Label {
                    width: parent.width
                    text: qsTr("AI coding agents")
                    color: "#e59c3f"
                    font.pixelSize: 13
                    font.bold: true
                    font.capitalization: Font.AllUppercase
                }

                OptionRow {
                    id: opencode
                    title: qsTr("opencode")
                    description: qsTr("Open-source terminal coding agent")
                }

                OptionRow {
                    id: codex
                    title: qsTr("Codex CLI")
                    description: qsTr("OpenAI's terminal coding agent")
                }
            }
        }
    }
}
