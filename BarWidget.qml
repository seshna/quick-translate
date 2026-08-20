import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "shaun.quick-translate"
  property bool showBarIcon: true
  property string responseText: ""
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("quick_translate.py").toString().replace(/^file:\/\//, ""))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: showBarIcon

  function refreshPreferences() {
    if (!preferences.running) preferences.running = true
  }

  Component.onCompleted: refreshPreferences()

  Timer {
    interval: 1200
    running: true
    repeat: true
    onTriggered: root.refreshPreferences()
  }

  Process {
    id: preferences
    command: ["python3", root.helperPath]
    stdinEnabled: true
    onStarted: write('{"operation":"preferences.get","params":{}}\n')
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.responseText = text }
    onExited: function(code) {
      if (code !== 0) return
      try {
        var reply = JSON.parse(root.responseText.trim())
        if (reply.ok && reply.data) root.showBarIcon = reply.data.showBarIcon !== false
      } catch (e) {}
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
