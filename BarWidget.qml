import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "shaun.quick-translate"
  property bool showBarIcon: true
  readonly property string stateRoot: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
  readonly property string preferencesPath: stateRoot + "/omarchy/quick-translate/preferences.json"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: showBarIcon

  function applyPreferences(text) {
    try {
      var preferences = JSON.parse(text)
      showBarIcon = preferences.showBarIcon !== false
    } catch (e) {
      showBarIcon = true
    }
  }
  function setBarIconVisible(value) { showBarIcon = value === true }

  FileView {
    id: preferencesFile
    path: root.preferencesPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyPreferences(text())
    onLoadFailed: root.showBarIcon = true
  }

  // Atomic replacement can invalidate an inotify watch on some filesystems.
  // Keep an infrequent FileView reload as a fallback; overlay changes update
  // bar widgets immediately through the shell, without launching a process.
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: preferencesFile.reload()
  }

  Component.onCompleted: {
    if (preferencesFile.loaded) {
      root.applyPreferences(preferencesFile.text())
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰗊"
    fontSize: Style.font.body * 1.35
    tooltipText: "Quick Translate"
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton && root.bar)
        root.bar.run("omarchy-shell shell toggle shaun.quick-translate '{}'")
    }
  }
}
