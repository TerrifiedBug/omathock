import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus its popup: toggle, soundpack picker, volume.
//
// This is a direct-panel bar widget, so one instance exists per monitor while
// exactly one Service.qml owns the key hook and the audio. All state is read
// from that service and every change is written through it — the widget keeps
// no copy, which is why two bars never disagree and why an `omarchy-shell
// omathock …` call is visible here immediately.
Panel {
  id: root
  moduleName: "io.github.terrifiedbug.omathock"
  manageIpc: false

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor(moduleName) : null
  property var ipcState: ({})
  property bool ipcStatusKnown: false
  property bool ipcRefreshPending: false
  property string ipcProblem: ""
  property var ipcActions: []
  property var activeIpcCommand: []
  property bool shuttingDown: false

  readonly property bool soundEnabled: service ? service.soundEnabled : ipcState.enabled === true
  readonly property string soundpack: service ? service.packSlug : String(ipcState.soundpack || "")
  readonly property int volume: service ? service.volume
    : (ipcStatusKnown ? Model.normalizeVolume(ipcState.volume) : Model.DEFAULTS.volume)
  readonly property bool luaReady: service ? service.luaReady : ipcState.lua === true
  readonly property var packSlugs: service
    ? service.packs.map(function(p) { return p.slug })
    : (ipcState.packs || [])
  readonly property string packSlugKey: packSlugs.join("\n")
  readonly property var packGroups: Model.packGroups(packSlugKey ? packSlugKey.split("\n") : [])
  property string browsingBrand: ""
  readonly property var activeGroup: packGroups.find(function(row) { return row.brand === browsingBrand }) || null
  readonly property var packRows: activeGroup ? activeGroup.packs : packGroups
  readonly property int listStart: activeGroup ? 2 : 1
  readonly property int volumeCursor: listStart + packRows.length
  property int cursor: 1
  property int rootCursor: 1
  property real rootScroll: 0
  property int keyboardVolume: -1

  readonly property string playerState: service ? service.playerState : String(ipcState.player || "")
  readonly property string playerProblem: service ? service.playerProblem : String(ipcState.playerProblem || "")

  // One line of why nothing is clicking, rather than a dead panel.
  readonly property string problem:
    !service && !ipcStatusKnown ? (ipcProblem || "Connecting to OmaThock…")
    : !luaReady ? "Needs Hyprland's Lua config (hyprland.lua)"
    : playerProblem !== "" ? playerProblem
    : playerState === "starting" ? "Starting sound player…"
    : packSlugs.length === 0 ? "No soundpacks found"
    : ""

  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // A direct-panel bar widget is sized by its own content: without this the
  // bar hands it zero width and the button never appears.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Packs dropped into ~/.local/share/omathock/soundpacks show up on open,
  // without a restart.
  onOpenedChanged: {
    if (opened) refreshPacks()
    else {
      keyboardVolume = -1
      cancelPreview()
    }
  }

  onPackRowsChanged: {
    cursor = Math.max(0, Math.min(volumeCursor + 1, cursor))
  }

  function moveCursor(dx, dy) {
    if (dx < 0 && activeGroup) {
      leaveGroup()
      return
    }
    if (dx !== 0 && cursor === volumeCursor) {
      keyboardVolume = Model.normalizeVolume((keyboardVolume < 0 ? volume : keyboardVolume) + dx * 5)
      return
    }
    if (dy === 0) return
    cursor = Math.max(0, Math.min(volumeCursor + 1, cursor + dy))
    if (cursor >= listStart && cursor < volumeCursor)
      packList.positionViewAtIndex(cursor - listStart, ListView.Contain)
  }

  function activateCursor() {
    if (cursor === 0) setEnabled(!soundEnabled)
    else if (activeGroup && cursor === 1) leaveGroup()
    else if (cursor >= listStart && cursor < volumeCursor) activatePack(cursor - listStart)
    else if (cursor === volumeCursor + 1) preview()
  }

  function activatePack(index) {
    var row = packRows[index]
    if (!row) return
    if (row.packs) {
      rootCursor = index + listStart
      rootScroll = packList.contentY
      browsingBrand = row.brand
      cursor = listStart
      packList.positionViewAtBeginning()
    } else if (row.slug === soundpack) preview()
    else setSoundpack(row.slug)
  }

  function leaveGroup() {
    if (!activeGroup) return
    browsingBrand = ""
    cursor = rootCursor
    Qt.callLater(function() {
      packList.forceLayout()
      packList.contentY = Math.max(packList.originY, Math.min(rootScroll,
        packList.originY + Math.max(0, packList.contentHeight - packList.height)))
    })
  }

  // A widget hosted by another third-party plugin receives that host's
  // scoped shell facade, so serviceFor() intentionally cannot return this
  // plugin's service. Its public IPC target remains available: use that as
  // the hosted path while retaining direct calls for a normal bar slot.
  function requestIpcStatus() {
    if (service) return
    if (statusProc.running) {
      ipcRefreshPending = true
      return
    }
    statusProc.running = true
  }

  function callIpc(method, argument) {
    var command = ["omarchy-shell", "omathock", method]
    if (argument !== undefined) command.push(String(argument))
    if (method === "soundpack")
      ipcActions = ipcActions.filter(function(action) { return action[2] !== "soundpack" })
    ipcActions.push(command)
    startIpcAction()
  }

  function startIpcAction() {
    if (shuttingDown || actionProc.running || ipcActions.length === 0) return
    activeIpcCommand = ipcActions.shift()
    actionProc.running = true
  }

  function setEnabled(on) {
    if (service) service.setEnabled(on)
    else callIpc(on ? "enable" : "disable")
  }

  function setSoundpack(slug) {
    if (service) service.setSoundpack(slug)
    else callIpc("soundpack", slug)
  }

  function refreshPacks() {
    if (service) service.refreshPacks()
    else callIpc("refresh")
  }

  function preview() {
    if (service) service.preview()
    else callIpc("preview")
  }

  function previewVolume(percent) {
    if (service) service.previewVolume(percent)
    else callIpc("previewVolume", percent)
  }

  function cancelPreview() {
    if (service) service.cancelPreview()
    else callIpc("cancelPreview")
  }

  Component.onCompleted: Qt.callLater(requestIpcStatus)
  Component.onDestruction: {
    shuttingDown = true
    ipcActions = []
    if (service) service.cancelPreview()
    else Quickshell.execDetached(["omarchy-shell", "omathock", "cancelPreview"])
  }
  onServiceChanged: if (!service) Qt.callLater(requestIpcStatus)

  Process {
    id: actionProc
    command: root.activeIpcCommand
    onExited: {
      root.requestIpcStatus()
      Qt.callLater(root.startIpcAction)
    }
  }

  FileView {
    path: root.service ? "" : Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false

    onFileChanged: reload()
    onLoaded: root.requestIpcStatus()
  }

  Process {
    id: statusProc
    command: ["omarchy-shell", "omathock", "status"]

    stdout: StdioCollector {
      waitForEnd: true

      onStreamFinished: {
        try {
          root.ipcState = JSON.parse(String(text || "").trim())
          root.ipcStatusKnown = true
          root.ipcProblem = ""
        } catch (e) {
          root.ipcStatusKnown = false
          root.ipcProblem = "Service not loaded — restart the shell"
        }
      }
    }

    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.ipcStatusKnown = false
        root.ipcProblem = "Service not loaded — restart the shell"
      }
      if (root.ipcRefreshPending) {
        root.ipcRefreshPending = false
        ipcRefreshTimer.restart()
      }
    }
  }

  Timer {
    id: ipcRefreshTimer
    interval: 200
    onTriggered: root.requestIpcStatus()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The thock mark rather than a keyboard glyph: this is a port of thock,
    // and the mark reads at bar size where a keyboard does not.
    iconComponent: Component {
      Item {
        ThockIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barForeground
        }
      }
    }
    // No `active`: that paints the icon in the bar's urgent colour, and
    // sounds being on is the resting state, not an alarm. Muted just dims.
    dimmed: !root.soundEnabled
    tooltipText: root.soundEnabled ? "OmaThock on — right-click to mute" : "OmaThock off — right-click to enable"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.setEnabled(!root.soundEnabled)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: {
        if (root.activeGroup) root.leaveGroup()
        else root.close()
      }
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      Keys.onReleased: function(event) {
        if (root.keyboardVolume < 0) return
        if (event.key !== Qt.Key_Left && event.key !== Qt.Key_Right
            && event.key !== Qt.Key_H && event.key !== Qt.Key_L) return
        root.previewVolume(root.keyboardVolume)
        root.keyboardVolume = -1
      }

      Column {
        id: content
        readonly property real fixedHeight: heading.height + enabledToggle.height + selectedPack.height
          + (backButton.visible ? backButton.height + groupHeading.height : 0)
          + volumeCaption.height + slider.height + previewButton.height
          + (problemLabel.visible ? problemLabel.height : 0)
          + spacing * (6 + (backButton.visible ? 2 : 0) + (problemLabel.visible ? 1 : 0))
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          id: heading
          text: "OMATHOCK"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        Toggle {
          id: enabledToggle
          width: parent.width
          label: "Keyboard sounds"
          description: "Click on every key press"
          checked: root.soundEnabled
          hasCursor: root.cursor === 0
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily

          onClicked: root.setEnabled(!root.soundEnabled)
        }

        Text {
          id: selectedPack
          textFormat: Text.PlainText
          width: parent.width
          text: "Soundpack · " + (root.soundpack ? Model.packLabel(root.soundpack) : "None")
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
          Accessible.role: Accessible.StaticText
          Accessible.name: text
        }

        Button {
          id: backButton
          visible: root.activeGroup !== null
          width: parent.width
          text: "‹ All soundpacks"
          leftAlign: true
          hasCursor: root.cursor === 1 && root.activeGroup !== null
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          Accessible.role: Accessible.Button
          Accessible.name: "All soundpacks"
          onClicked: root.leaveGroup()
        }

        PanelSectionHeader {
          id: groupHeading
          visible: root.activeGroup !== null
          text: root.browsingBrand
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        ListView {
          id: packList
          width: parent.width
          // Reserve the header and fixed footer before giving space to packs.
          readonly property real desiredHeight: Math.min(7, count) * (Style.spacing.popupRowHeight + spacing) - (count ? spacing : 0)
          height: Math.max(0, Math.min(desiredHeight,
            panel.fittedContentHeight(content.fixedHeight + desiredHeight)
              - panel.fittedContentHeight(0) - content.fixedHeight))
          clip: true
          model: root.packRows
          boundsBehavior: Flickable.StopAtBounds
          spacing: Style.spacing.xxs
          Accessible.role: Accessible.List
          Accessible.name: root.activeGroup ? root.browsingBrand + " soundpacks" : "Soundpacks"

          delegate: Item {
            id: packRow
            required property var modelData
            required property int index
            readonly property bool chosen: modelData.slug === root.soundpack
              || (modelData.packs ? modelData.packs.some(function(pack) { return pack.slug === root.soundpack }) : false)
            width: packList.width
            height: Style.spacing.popupRowHeight
            Accessible.role: Accessible.ListItem
            Accessible.name: modelData.label + (modelData.packs ? ", open brand" : "")
            Accessible.checkable: !modelData.packs
            Accessible.checked: chosen
            Accessible.onPressAction: root.activatePack(index)

            CursorSurface {
              anchors.fill: parent
              hasCursor: root.cursor === root.listStart + packRow.index || rowMouse.containsMouse
              current: packRow.chosen
              foreground: root.contentForeground
            }

            Text {
              anchors.left: parent.left
              anchors.right: rowMark.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.rowPaddingX
              textFormat: Text.PlainText
              text: packRow.modelData.label
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              id: rowMark
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: packRow.modelData.packs ? (packRow.chosen ? "✓  ›" : "›") : (packRow.chosen ? "✓" : "")
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: {
                root.cursor = root.listStart + packRow.index
                root.activatePack(packRow.index)
              }
            }
          }
        }

        // The footer never scrolls with the pack list.
        Text {
          id: volumeCaption
          textFormat: Text.PlainText
          text: "Volume · " + Math.round(slider.liveValue) + "%"
          color: root.cursor === root.volumeCursor ? Commons.Color.accent : Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        PanelSlider {
          id: slider
          width: parent.width
          bar: root.bar
          minimum: 0
          maximum: 100
          step: 5
          integer: true
          value: root.keyboardVolume < 0 ? root.volume : root.keyboardVolume
          Accessible.name: "Preview volume"

          // Sample click on release: the level is only meaningful heard.
          onReleased: function(value) {
            root.previewVolume(value)
          }
        }

        Button {
          id: previewButton
          width: parent.width
          text: "Preview"
          hasCursor: root.cursor === root.volumeCursor + 1
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          Accessible.role: Accessible.Button
          Accessible.name: "Preview selected soundpack"
          onClicked: {
            root.cursor = root.volumeCursor + 1
            root.preview()
          }
        }

        Text {
          id: problemLabel
          textFormat: Text.PlainText
          visible: root.problem !== ""
          width: parent.width
          text: root.problem
          color: root.bar ? root.bar.urgent : Commons.Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
