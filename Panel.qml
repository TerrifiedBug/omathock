import QtQuick
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
  readonly property bool soundEnabled: service ? service.soundEnabled : false
  readonly property string soundpack: service ? service.packSlug : ""
  readonly property int volume: service ? service.volume : Model.DEFAULTS.volume
  readonly property var packOptions: (service ? service.packs : []).map(function(p) {
    return { value: p.slug, label: Model.packLabel(p.slug) }
  })

  // One line of why nothing is clicking, rather than a dead panel.
  readonly property string problem:
    !service ? "Service not loaded — restart the shell"
    : !service.luaReady ? "Needs Hyprland's Lua config (hyprland.lua)"
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
  onOpenedChanged: if (opened && service) service.refreshPacks()

  // Dropdown assigns its own `value` when a row is picked, which breaks the
  // binding; re-push the service's value so an IPC or CLI change stays visible.
  onSoundpackChanged: packDropdown.value = soundpack

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌" // nf-md-keyboard
    dimmed: !root.soundEnabled
    active: root.soundEnabled
    tooltipText: root.soundEnabled ? "OmaThock on — right-click to mute" : "OmaThock off — right-click to enable"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) { if (root.service) root.service.setEnabled(!root.soundEnabled) }
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

          onClicked: if (root.service) root.service.setEnabled(!root.soundEnabled)
        }

        Dropdown {
          id: packDropdown
          width: parent.width
          label: "Soundpack"
          options: root.packOptions
          value: root.soundpack
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily

          onChanged: function(value) { if (root.service) root.service.setSoundpack(value) }
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
            if (!root.service) return
            root.service.setVolume(value)
            root.service.play("default", false)
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
