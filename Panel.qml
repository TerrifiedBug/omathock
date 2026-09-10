import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
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

  readonly property bool soundEnabled: service ? service.soundEnabled : ipcState.enabled === true
  readonly property string soundpack: service ? service.packSlug : String(ipcState.soundpack || "")
  readonly property int volume: service ? service.volume
    : (ipcStatusKnown ? Model.normalizeVolume(ipcState.volume) : Model.DEFAULTS.volume)
  readonly property bool luaReady: service ? service.luaReady : ipcState.lua === true
  readonly property var packSlugs: service
    ? service.packs.map(function(p) { return p.slug })
    : (ipcState.packs || [])
  readonly property var packOptions: packSlugs.map(function(slug) {
    return { value: slug, label: Model.packLabel(slug) }
  })

  // One line of why nothing is clicking, rather than a dead panel.
  readonly property string problem:
    !service && !ipcStatusKnown ? (ipcProblem || "Connecting to OmaThock…")
    : !luaReady ? "Needs Hyprland's Lua config (hyprland.lua)"
    : packOptions.length === 0 ? "No soundpacks found"
    : ""

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // A direct-panel bar widget is sized by its own content: without this the
  // bar hands it zero width and the button never appears.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Packs dropped into ~/.local/share/omathock/soundpacks show up on open,
  // without a restart.
  onOpenedChanged: if (opened) refreshPacks()

  // Dropdown assigns its own `value` when a row is picked, which breaks the
  // binding; re-push the service's value so an IPC or CLI change stays visible.
  onSoundpackChanged: packDropdown.value = soundpack

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
    Quickshell.execDetached(command)
    ipcRefreshTimer.restart()
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

  function setVolumeAndPreview(percent) {
    if (service) {
      service.setVolume(percent)
      service.play("default", false)
    } else {
      callIpc("previewVolume", percent)
    }
  }

  Component.onCompleted: Qt.callLater(requestIpcStatus)
  onServiceChanged: if (!service) Qt.callLater(requestIpcStatus)

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
    contentWidth: panel.fittedContentWidth(Style.space(280))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "OMATHOCK"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        Toggle {
          width: parent.width
          label: "Keyboard sounds"
          description: "Click on every key press"
          checked: root.soundEnabled
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily

          onClicked: root.setEnabled(!root.soundEnabled)
        }

        Dropdown {
          id: packDropdown
          width: parent.width
          label: "Soundpack"
          options: root.packOptions
          value: root.soundpack
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily

          onChanged: function(value) { root.setSoundpack(value) }
        }

        // Volume caption styled like Dropdown's own label so the two rows read
        // as one form; the live value tracks the drag, not the committed one.
        Text {
          textFormat: Text.PlainText
          text: "Volume · " + Math.round(slider.liveValue) + "%"
          color: Qt.darker(root.contentForeground, 1.4)
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
          value: root.volume

          // Sample click on release: the level is only meaningful heard.
          onReleased: function(value) {
            root.setVolumeAndPreview(value)
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.problem !== ""
          width: parent.width
          text: root.problem
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
