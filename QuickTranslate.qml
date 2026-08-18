import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root
  property var shell: null
  property var manifest: null
  property bool opened: false
  property bool busy: false
  property bool translating: false
  property string copiedAction: ""
  property string sourceLanguage: "en"
  property string targetLanguage: "ja"
  property string translatedText: ""
  property string message: ""
  property bool messageError: false
  property string clearedSourceText: ""
  property string clearedTranslationText: ""
  property bool clearUndoAvailable: false
  property bool restoringClear: false
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("quick_translate.py").toString().replace(/^file:\/\//, ""))
  readonly property var languages: [
    ["en","English"],["ja","Japanese"],["es","Spanish"],["fr","French"],["de","German"],["it","Italian"],["pt","Portuguese"],["nl","Dutch"],["pl","Polish"],["ru","Russian"],["uk","Ukrainian"],["zh-CN","Chinese (Simplified)"],["zh-TW","Chinese (Traditional)"],["ko","Korean"],["ar","Arabic"],["hi","Hindi"],["id","Indonesian"],["tr","Turkish"],["vi","Vietnamese"],["th","Thai"],["sv","Swedish"],["da","Danish"],["no","Norwegian"],["fi","Finnish"],["cs","Czech"],["el","Greek"],["he","Hebrew"],["hu","Hungarian"],["ro","Romanian"],["bg","Bulgarian"],["ca","Catalan"],["tl","Filipino"]]
  readonly property bool canTranslate: !busy && sourceBox.text.trim().length > 0 && sourceBox.text.length <= 5000

  component HotkeyButton: Item {
    id: control
    property string actionText: ""
    property string hotkeyText: ""
    property string reservedText: ""
    property bool available: true
    property bool visuallyMuted: false
    opacity: visuallyMuted ? 0.42 : 1
    signal clicked()
    implicitWidth: Math.max(
      actionButton.implicitWidth,
      reservedLabel.implicitWidth + actionButton.horizontalPadding * 2 + 4
    )
    implicitHeight: actionButton.implicitHeight

    Text {
      id: reservedLabel
      visible: false
      text: control.reservedText
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Button {
      id: actionButton
      anchors.fill: parent
      text: control.hotkeyText === "" ? control.actionText : control.actionText + "  " + control.hotkeyText
      bordered: true
      focusable: true
      enabled: control.available
      onClicked: control.clicked()
    }
  }

  function nameFor(code) { for (var i=0;i<languages.length;i++) if (languages[i][0] === code) return languages[i][1]; return code }
  function indexForLanguage(code) {
    return languages.map(function(item) { return item[0] }).indexOf(code)
  }
  function syncLanguageSelectors() {
    if (!fromPicker || !toPicker) return
    fromPicker.currentIndex = indexForLanguage(sourceLanguage)
    toPicker.currentIndex = indexForLanguage(targetLanguage)
    fromPicker.editText = nameFor(sourceLanguage)
    toPicker.editText = nameFor(targetLanguage)
  }
  function run(operation, params, done) {
    if (busy) return
    busy = true
    translating = operation === "translate"
    bridge.payload = JSON.stringify({operation: operation, params: params || {}})
    bridge.done = done
    bridge.command = ["python3", helperPath]
    bridge.running = true
  }
  function showReply(reply) {
    if (reply && reply.ok) { message = ""; messageError = false; return true }
    message = reply && reply.error ? reply.error.message : "The helper did not return a valid response."
    messageError = true; return false
  }
  function savePreferences() { run("preferences.set", {sourceLanguage: sourceLanguage, targetLanguage: targetLanguage}, function(reply) { showReply(reply) }) }
  function translate() {
    if (!canTranslate) return
    message = ""
    run("translate", {text: sourceBox.text, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage}, function(reply) {
      if (showReply(reply)) translatedText = String(reply.data.translation || "")
    })
  }
  function swap() {
    if (busy) return
    var lang = sourceLanguage; sourceLanguage = targetLanguage; targetLanguage = lang
    var text = sourceBox.text; sourceBox.text = translatedText; translatedText = text
    // Editable ComboBoxes can lose their currentIndex binding after a search,
    // so keep the visible selectors in sync explicitly when swapping.
    syncLanguageSelectors()
    savePreferences()
  }
  function copy(text, action) {
    run("copy", {text: text}, function(reply) {
      if (showReply(reply)) {
        copiedAction = action
        copiedTimer.restart()
      }
    })
  }
  function clearAll() {
    if (busy) return
    if (sourceBox.text.length === 0 && translatedText.length === 0) return
    clearedSourceText = sourceBox.text
    clearedTranslationText = translatedText
    clearUndoAvailable = true
    restoringClear = true
    sourceBox.text = ""
    translatedText = ""
    restoringClear = false
    message = ""
    messageError = false
    copiedAction = ""
    sourceBox.forceActiveFocus()
  }
  function undoClear() {
    if (!clearUndoAvailable || busy) return
    restoringClear = true
    sourceBox.text = clearedSourceText
    translatedText = clearedTranslationText
    restoringClear = false
    clearUndoAvailable = false
    sourceBox.forceActiveFocus()
  }
  function open(payload) { opened = true; Qt.callLater(function(){ sourceBox.forceActiveFocus() }) }
  function close() { opened = false }
  function dismiss() { opened = false; if (shell) shell.hide((manifest && manifest.id) || "shaun.quick-translate") }
  function toggle() { opened ? dismiss() : open("{}") }

  Component.onCompleted: run("preferences.get", {}, function(reply) {
    if (reply && reply.ok) {
      sourceLanguage = reply.data.sourceLanguage || "en"
      targetLanguage = reply.data.targetLanguage || "ja"
      syncLanguageSelectors()
    }
  })

  Timer {
    id: copiedTimer
    interval: 1500
    repeat: false
    onTriggered: root.copiedAction = ""
  }

  Process {
    id: bridge
    property string payload: ""
    property var done: null
    property string responseText: ""
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: {
      bridge.responseText = text
    }}
    onExited: function(code) {
      var reply = null
      if (code === 0) {
        try { reply = JSON.parse(bridge.responseText.trim()) } catch (e) { reply = null }
      }
      var callback = bridge.done
      bridge.done = null
      bridge.responseText = ""
      root.busy = false
      root.translating = false
      if (code !== 0) {
        root.message = "The translator helper failed to run."
        root.messageError = true
      } else if (callback) {
        callback(reply)
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "shaun-quick-translate"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore
    Shortcut {
      sequence: "Ctrl+Y"
      context: Qt.WindowShortcut
      enabled: !root.busy && root.translatedText.length > 0
      onActivated: root.copy(root.translatedText, "translation")
    }
    Shortcut {
      sequence: "Ctrl+Shift+Y"
      context: Qt.WindowShortcut
      enabled: !root.busy && root.translatedText.length > 0
      onActivated: root.copy(sourceBox.text + "\n\n" + root.translatedText, "both")
    }
    Shortcut {
      sequence: "Ctrl+Shift+K"
      context: Qt.WindowShortcut
      enabled: !root.busy && (sourceBox.text.length > 0 || root.translatedText.length > 0)
      onActivated: root.clearAll()
    }
    Shortcut {
      sequence: "Ctrl+Z"
      context: Qt.WindowShortcut
      enabled: root.clearUndoAvailable && !root.busy
      onActivated: root.undoClear()
    }
    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    BorderSurface {
      id: card
      width: Math.min(900, panel.width - Style.gapsOut * 2)
      height: Math.min(690, panel.height - Style.gapsOut * 2)
      anchors.centerIn: parent
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      padding: Style.spacing.panelPadding
      MouseArea { anchors.fill: parent; onClicked: {} }
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.dismiss(); event.accepted = true }
        else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Return) { root.translate(); event.accepted = true }
        else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_U) { root.swap(); event.accepted = true }
      }
      ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset; anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset; anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md
        RowLayout {
          Layout.fillWidth: true
          Label { text: "Quick Translate"; color: Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading; font.bold: true; Layout.fillWidth: true }
          Button {
            text: "×"
            onClicked: root.dismiss()
          }
        }
        RowLayout {
          Layout.fillWidth: true
          ComboBox {
            id: fromPicker
            Layout.fillWidth: true
            editable: true
            model: root.languages.map(function(x) { return x[1] })
            currentIndex: 0
            onEditTextChanged: {
              var match = find(editText, Qt.MatchContains)
              if (match >= 0) currentIndex = match
            }
            onActivated: {
              root.sourceLanguage = root.languages[currentIndex][0]
              root.syncLanguageSelectors()
              root.savePreferences()
            }
            onAccepted: {
              root.sourceLanguage = root.languages[currentIndex][0]
              root.syncLanguageSelectors()
              root.savePreferences()
            }
          }
          HotkeyButton { actionText: "⇄  Swap"; hotkeyText: "Ctrl+U"; available: !root.busy; onClicked: root.swap() }
          ComboBox {
            id: toPicker
            Layout.fillWidth: true
            editable: true
            model: root.languages.map(function(x) { return x[1] })
            currentIndex: 1
            onEditTextChanged: {
              var match = find(editText, Qt.MatchContains)
              if (match >= 0) currentIndex = match
            }
            onActivated: {
              root.targetLanguage = root.languages[currentIndex][0]
              root.syncLanguageSelectors()
              root.savePreferences()
            }
            onAccepted: {
              root.targetLanguage = root.languages[currentIndex][0]
              root.syncLanguageSelectors()
              root.savePreferences()
            }
          }
        }
        Label { text: "Type a language name in either selector to search. Text is only retained for this shell session."; color: Color.menu.text; opacity: .65; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        TextArea {
          id: sourceBox
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.minimumHeight: 160
          placeholderText: "Text to translate"
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          color: Color.menu.text
          font.family: Style.font.menuFamily
          onTextChanged: if (!root.restoringClear) root.clearUndoAvailable = false
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Z
                && root.clearUndoAvailable) {
              root.undoClear()
              event.accepted = true
            }
          }
        }
        Label { text: sourceBox.text.length + " / 5,000"; color: sourceBox.text.length > 5000 ? "#e06c75" : Color.menu.text; opacity: .75; Layout.alignment: Qt.AlignRight }
        TextArea { id: outputBox; Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 160; text: root.translatedText; readOnly: true; placeholderText: "Ctrl + Enter to translate"; wrapMode: TextEdit.Wrap; selectByMouse: true; color: Color.menu.text; font.family: Style.font.menuFamily }
        Label { visible: root.message !== ""; text: root.message; color: root.messageError ? "#e06c75" : Color.menu.text; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        RowLayout {
          Layout.fillWidth: true
          HotkeyButton { actionText: "Clear"; hotkeyText: "Ctrl+Shift+K"; reservedText: "Clear  Ctrl+Shift+K"; available: !root.busy && (sourceBox.text.length > 0 || root.translatedText.length > 0); visuallyMuted: sourceBox.text.length === 0 && root.translatedText.length === 0; onClicked: root.clearAll() }
          HotkeyButton { actionText: root.copiedAction === "translation" ? "󰆏  Copied ✓" : "󰆏  Copy translation"; hotkeyText: root.copiedAction === "translation" ? "" : "Ctrl+Y"; reservedText: "󰆏  Copy translation  Ctrl+Y"; available: !root.busy && root.translatedText.length > 0; visuallyMuted: root.translatedText.length === 0; onClicked: root.copy(root.translatedText, "translation") }
          HotkeyButton { actionText: root.copiedAction === "both" ? "󰆏  Copied ✓" : "󰆏  Copy both"; hotkeyText: root.copiedAction === "both" ? "" : "Ctrl+Shift+Y"; reservedText: "󰆏  Copy both  Ctrl+Shift+Y"; available: !root.busy && root.translatedText.length > 0; visuallyMuted: root.translatedText.length === 0; onClicked: root.copy(sourceBox.text + "\n\n" + root.translatedText, "both") }
          Item { Layout.fillWidth: true }
          HotkeyButton { actionText: root.translating ? "Translating…" : "Translate"; hotkeyText: root.translating ? "" : "Ctrl+Enter"; reservedText: "Translate  Ctrl+Enter"; available: root.canTranslate; visuallyMuted: sourceBox.text.trim().length === 0 || sourceBox.text.length > 5000; onClicked: root.translate() }
        }
      }
    }
  }
}
