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
  property var shortcuts: ({copy: "Ctrl+Y", copyAll: "Ctrl+Shift+Y", switch: "Ctrl+U", clear: "Ctrl+Shift+K", translate: "Ctrl+Enter", undo: "Ctrl+Z"})
  property bool showBarIcon: true
  property bool showHotkeys: true
  property bool setupOpen: false
  property int settingsSelectedIndex: 0
  property string recordingAction: ""
  property string settingsError: ""
  property bool resetConfirmationVisible: false
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
    property string compactActionText: ""
    property string hotkeyText: ""
    property string reservedText: ""
    property bool available: true
    property bool visuallyMuted: false
    property bool showHotkey: root.showHotkeys
    opacity: visuallyMuted ? 0.42 : 1
    signal clicked()
    implicitWidth: Math.max(
      actionButton.implicitWidth,
      control.showHotkey ? reservedLabel.implicitWidth + actionButton.horizontalPadding * 2 + 4 : actionButton.implicitWidth
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
      text: !control.showHotkey ? (control.compactActionText !== "" ? control.compactActionText : control.actionText)
          : (control.hotkeyText === "" ? control.actionText : control.actionText + "  " + control.hotkeyText)
      bordered: true
      focusable: true
      enabled: control.available
      onClicked: control.clicked()
    }
  }

  component ShortcutRecorder: Button {
    id: control
    property string actionKey: ""
    property string shortcut: ""
    property int settingsIndex: -1
    text: root.recordingAction === actionKey ? "Press a shortcut…" : shortcut
    bordered: true
    focusable: true
    Layout.preferredWidth: 210
    function beginRecording() {
      root.settingsError = ""
      if (settingsIndex >= 0) root.settingsSelectedIndex = settingsIndex
      root.recordingAction = actionKey
      forceActiveFocus()
    }
    onClicked: beginRecording()
    Keys.onPressed: function(event) {
      if (root.recordingAction !== actionKey) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          beginRecording()
          event.accepted = true
        }
        return
      }
      if (event.key === Qt.Key_Escape) {
        root.recordingAction = ""
        root.settingsError = ""
        root.focusSettingsSelection()
        event.accepted = true
        return
      }
      var sequence = root.shortcutForEvent(event)
      if (sequence === "") { event.accepted = true; return }
      root.setShortcut(actionKey, sequence)
      event.accepted = true
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
  function applyPreferences(data) {
    sourceLanguage = data.sourceLanguage || "en"
    targetLanguage = data.targetLanguage || "ja"
    shortcuts = data.shortcuts || shortcuts
    showBarIcon = data.showBarIcon !== false
    showHotkeys = data.showHotkeys !== false
    syncLanguageSelectors()
  }
  function savePreferences(params, done) {
    run("preferences.set", params, function(reply) {
      if (showReply(reply) && reply.data) applyPreferences(reply.data)
      if (done) done(reply)
    })
  }
  function saveLanguages() { savePreferences({sourceLanguage: sourceLanguage, targetLanguage: targetLanguage}) }
  function shortcutForEvent(event) {
    if (event.key === Qt.Key_Control || event.key === Qt.Key_Shift || event.key === Qt.Key_Alt || event.key === Qt.Key_Meta) return ""
    var keyNames = {}
    keyNames[Qt.Key_Return] = "Enter"; keyNames[Qt.Key_Enter] = "Enter"; keyNames[Qt.Key_Space] = "Space"
    keyNames[Qt.Key_Tab] = "Tab"; keyNames[Qt.Key_Backspace] = "Backspace"; keyNames[Qt.Key_Delete] = "Delete"
    keyNames[Qt.Key_Escape] = "Esc"
    var key = keyNames[event.key]
    if (!key && event.key >= Qt.Key_A && event.key <= Qt.Key_Z) key = String.fromCharCode(event.key)
    if (!key && event.key >= Qt.Key_0 && event.key <= Qt.Key_9) key = String.fromCharCode(event.key)
    if (!key && event.key >= Qt.Key_F1 && event.key <= Qt.Key_F35) key = "F" + (event.key - Qt.Key_F1 + 1)
    if (!key && event.text && event.text.length === 1) key = event.text.toUpperCase()
    if (!key) return ""
    var prefix = ""
    if (event.modifiers & Qt.ControlModifier) prefix += "Ctrl+"
    if (event.modifiers & Qt.AltModifier) prefix += "Alt+"
    if (event.modifiers & Qt.ShiftModifier) prefix += "Shift+"
    if (event.modifiers & Qt.MetaModifier) prefix += "Meta+"
    return prefix + key
  }
  function setShortcut(action, sequence) {
    var next = ({copy: shortcuts.copy, copyAll: shortcuts.copyAll, switch: shortcuts.switch, clear: shortcuts.clear, translate: shortcuts.translate, undo: shortcuts.undo})
    var reservedMessage = reservedShortcutMessage(sequence)
    if (reservedMessage !== "") { settingsError = reservedMessage; return }
    for (var key in next) if (key !== action && next[key] === sequence) { settingsError = "That shortcut is already assigned to another action."; return }
    next[action] = sequence
    savePreferences({shortcuts: next}, function(reply) {
      if (reply && reply.ok) { recordingAction = ""; settingsError = "" }
      else settingsError = reply && reply.error ? reply.error.message : "Could not save shortcut."
    })
  }
  function reservedShortcutMessage(sequence) {
    if (sequence === "Ctrl+Shift+U") return "Ctrl+Shift+U is reserved for Unicode input. Choose another shortcut."
    if (sequence === "Ctrl+?" || sequence === "Ctrl+Shift+?" || sequence === "Ctrl+Shift+/") return "Ctrl+? opens Setup. Choose another shortcut."
    if (sequence === "Ctrl+J" || sequence === "Ctrl+K") return "Ctrl+J and Ctrl+K navigate Setup. Choose another shortcut."
    if (sequence.indexOf("Meta+") >= 0) return "Super shortcuts are managed globally. Choose Ctrl or Alt instead."
    if (["Space", "Enter", "Tab", "Esc", "Backspace", "Delete"].indexOf(sequence) >= 0
        || (!sequence.startsWith("Ctrl+") && !sequence.startsWith("Alt+") && !sequence.startsWith("Meta+") && !sequence.startsWith("F")))
      return "Use Ctrl, Alt, or an F-key shortcut to avoid typing and navigation conflicts."
    return ""
  }
  function restoreShortcutDefaults() {
    if (!resetConfirmationVisible) { resetConfirmationVisible = true; return }
    savePreferences({shortcuts: {copy: "Ctrl+Y", copyAll: "Ctrl+Shift+Y", switch: "Ctrl+U", clear: "Ctrl+Shift+K", translate: "Ctrl+Enter", undo: "Ctrl+Z"}}, function(reply) {
      if (reply && reply.ok) { resetConfirmationVisible = false; settingsError = "" }
    })
  }
  function openSetup() {
    setupOpen = true
    settingsSelectedIndex = 0
    recordingAction = ""
    settingsError = ""
    resetConfirmationVisible = false
    focusSettingsSelection()
  }
  function closeSetup() {
    setupOpen = false
    recordingAction = ""
    settingsError = ""
    resetConfirmationVisible = false
    sourceBox.forceActiveFocus()
  }
  function moveSettingsSelection(direction) {
    settingsSelectedIndex = (settingsSelectedIndex + direction + 9) % 9
    focusSettingsSelection()
  }
  function focusSettingsSelection() {
    Qt.callLater(function() {
      if (!setupOpen) return
      if (settingsSelectedIndex === 0) barIconSwitch.forceActiveFocus()
      else if (settingsSelectedIndex === 1) hotkeysSwitch.forceActiveFocus()
      else if (settingsSelectedIndex === 2) copyRecorder.forceActiveFocus()
      else if (settingsSelectedIndex === 3) copyAllRecorder.forceActiveFocus()
      else if (settingsSelectedIndex === 4) switchRecorder.forceActiveFocus()
      else if (settingsSelectedIndex === 5) clearRecorder.forceActiveFocus()
      else if (settingsSelectedIndex === 6) translateRecorder.forceActiveFocus()
      else if (settingsSelectedIndex === 7) undoRecorder.forceActiveFocus()
      else restoreButton.forceActiveFocus()
    })
  }
  function activateSelectedSetting() {
    if (settingsSelectedIndex === 0) savePreferences({showBarIcon: !showBarIcon})
    else if (settingsSelectedIndex === 1) savePreferences({showHotkeys: !showHotkeys})
    else if (settingsSelectedIndex === 2) copyRecorder.beginRecording()
    else if (settingsSelectedIndex === 3) copyAllRecorder.beginRecording()
    else if (settingsSelectedIndex === 4) switchRecorder.beginRecording()
    else if (settingsSelectedIndex === 5) clearRecorder.beginRecording()
    else if (settingsSelectedIndex === 6) translateRecorder.beginRecording()
    else if (settingsSelectedIndex === 7) undoRecorder.beginRecording()
    else restoreShortcutDefaults()
  }
  function actionForShortcut(event) {
    if (setupOpen) return ""
    var sequence = shortcutForEvent(event)
    if (sequence === shortcuts.switch && !busy) return "switch"
    if (sequence === shortcuts.translate && canTranslate) return "translate"
    if (sequence === shortcuts.undo && clearUndoAvailable && !busy) return "undo"
    if (sequence === shortcuts.clear && !busy && (sourceBox.text.length > 0 || translatedText.length > 0)) return "clear"
    if (sequence === shortcuts.copy && !busy && translatedText.length > 0) return "copy"
    if (sequence === shortcuts.copyAll && !busy && translatedText.length > 0) return "copyAll"
    return ""
  }
  function handleActionShortcut(event) {
    var action = actionForShortcut(event)
    if (action === "switch") { swap(); return true }
    if (action === "translate") { translate(); return true }
    if (action === "undo") { undoClear(); return true }
    if (action === "clear") { clearAll(); return true }
    if (action === "copy") { copy(translatedText, "translation"); return true }
    if (action === "copyAll") { copy(sourceBox.text + "\n\n" + translatedText, "both"); return true }
    return false
  }
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
    saveLanguages()
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

  Component.onCompleted: run("preferences.get", {}, function(reply) { if (reply && reply.ok) applyPreferences(reply.data) })

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
      sequence: root.shortcuts.copy
      context: Qt.WindowShortcut
      enabled: !root.setupOpen && !root.busy && root.translatedText.length > 0
      onActivated: root.copy(root.translatedText, "translation")
    }
    Shortcut {
      sequence: root.shortcuts.copyAll
      context: Qt.WindowShortcut
      enabled: !root.setupOpen && !root.busy && root.translatedText.length > 0
      onActivated: root.copy(sourceBox.text + "\n\n" + root.translatedText, "both")
    }
    Shortcut {
      sequence: root.shortcuts.clear
      context: Qt.WindowShortcut
      enabled: !root.setupOpen && !root.busy && (sourceBox.text.length > 0 || root.translatedText.length > 0)
      onActivated: root.clearAll()
    }
    Shortcut {
      sequence: root.shortcuts.switch
      context: Qt.WindowShortcut
      enabled: !root.setupOpen && !root.busy
      onActivated: root.swap()
    }
    Shortcut {
      sequence: root.shortcuts.translate
      context: Qt.WindowShortcut
      enabled: !root.setupOpen && root.canTranslate
      onActivated: root.translate()
    }
    Shortcut {
      sequence: root.shortcuts.undo
      context: Qt.WindowShortcut
      enabled: !root.setupOpen && root.clearUndoAvailable && !root.busy
      onActivated: root.undoClear()
    }
    Shortcut {
      sequence: "Ctrl+?"
      context: Qt.WindowShortcut
      enabled: root.opened && root.recordingAction === ""
      onActivated: root.setupOpen ? root.closeSetup() : root.openSetup()
    }
    Shortcut {
      sequence: "Ctrl+J"
      context: Qt.WindowShortcut
      enabled: root.setupOpen && root.recordingAction === ""
      onActivated: root.moveSettingsSelection(1)
    }
    Shortcut {
      sequence: "Ctrl+K"
      context: Qt.WindowShortcut
      enabled: root.setupOpen && root.recordingAction === ""
      onActivated: root.moveSettingsSelection(-1)
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
        if (event.key === Qt.Key_Escape && root.recordingAction === "") { root.dismiss(); event.accepted = true }
        else if (root.handleActionShortcut(event)) event.accepted = true
      }
      ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset; anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset; anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md
        RowLayout {
          Layout.fillWidth: true
          Label { text: "󰗊"; color: Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading * 1.35; font.bold: true }
          Label { text: root.setupOpen ? "Quick Translate Setup" : "Quick Translate"; color: Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading; font.bold: true; Layout.fillWidth: true }
          Button {
            text: root.setupOpen ? (root.showHotkeys ? "󰁍  Ctrl+?" : "󰁍") : (!root.showHotkeys ? "󰒓" : "󰒓  Ctrl+?")
            onClicked: root.setupOpen ? root.closeSetup() : root.openSetup()
          }
          Button {
            text: "×"
            onClicked: root.dismiss()
          }
        }
        RowLayout {
          visible: !root.setupOpen
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
              root.saveLanguages()
            }
            onAccepted: {
              root.sourceLanguage = root.languages[currentIndex][0]
              root.syncLanguageSelectors()
              root.saveLanguages()
            }
          }
          HotkeyButton { actionText: "⇄"; hotkeyText: root.shortcuts.switch; available: !root.busy; onClicked: root.swap() }
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
              root.saveLanguages()
            }
            onAccepted: {
              root.targetLanguage = root.languages[currentIndex][0]
              root.syncLanguageSelectors()
              root.saveLanguages()
            }
          }
        }
        Label { visible: !root.setupOpen; text: "Type a language name in either selector to search. Text is only retained for this shell session."; color: Color.menu.text; opacity: .65; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        TextArea {
          id: sourceBox
          visible: !root.setupOpen
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
          Keys.onShortcutOverride: function(event) {
            if (root.actionForShortcut(event) !== "") event.accepted = true
          }
          Keys.onPressed: function(event) {
            // TextInput treats Ctrl+Shift+U as the start of a Unicode code
            // point entry. Intercept configured actions here before that
            // handler sees the key sequence.
            if (root.handleActionShortcut(event)) event.accepted = true
          }
        }
        Label { visible: !root.setupOpen; text: sourceBox.text.length + " / 5,000"; color: sourceBox.text.length > 5000 ? "#e06c75" : Color.menu.text; opacity: .75; Layout.alignment: Qt.AlignRight }
        TextArea { id: outputBox; visible: !root.setupOpen; Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 160; text: root.translatedText; readOnly: true; placeholderText: root.showHotkeys ? root.shortcuts.translate + " to translate" : "Translation"; wrapMode: TextEdit.Wrap; selectByMouse: true; color: Color.menu.text; font.family: Style.font.menuFamily }
        Label { visible: !root.setupOpen && root.message !== ""; text: root.message; color: root.messageError ? "#e06c75" : Color.menu.text; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        RowLayout {
          visible: !root.setupOpen
          Layout.fillWidth: true
          HotkeyButton { actionText: "󰆴  Clear"; compactActionText: "󰆴"; hotkeyText: root.shortcuts.clear; reservedText: "󰆴  Clear  " + root.shortcuts.clear; available: !root.busy && (sourceBox.text.length > 0 || root.translatedText.length > 0); visuallyMuted: sourceBox.text.length === 0 && root.translatedText.length === 0; onClicked: root.clearAll() }
          HotkeyButton { actionText: root.copiedAction === "translation" ? "󰆏  Copied ✓" : "󰆏  Copy translation"; compactActionText: "󰆏"; hotkeyText: root.copiedAction === "translation" ? "" : root.shortcuts.copy; reservedText: "󰆏  Copy translation  " + root.shortcuts.copy; available: !root.busy && root.translatedText.length > 0; visuallyMuted: root.translatedText.length === 0; onClicked: root.copy(root.translatedText, "translation") }
          HotkeyButton { actionText: root.copiedAction === "both" ? "󰆏 󰆏  Copied ✓" : "󰆏 󰆏  Copy both"; compactActionText: "󰆏 󰆏"; hotkeyText: root.copiedAction === "both" ? "" : root.shortcuts.copyAll; reservedText: "󰆏 󰆏  Copy both  " + root.shortcuts.copyAll; available: !root.busy && root.translatedText.length > 0; visuallyMuted: root.translatedText.length === 0; onClicked: root.copy(sourceBox.text + "\n\n" + root.translatedText, "both") }
          Item { Layout.fillWidth: true }
          HotkeyButton { actionText: root.translating ? "󰗊  Translating…" : "󰗊  Translate"; compactActionText: "󰗊"; hotkeyText: root.translating ? "" : root.shortcuts.translate; reservedText: "󰗊  Translate  " + root.shortcuts.translate; available: root.canTranslate; visuallyMuted: sourceBox.text.trim().length === 0 || sourceBox.text.length > 5000; onClicked: root.translate() }
        }
        ColumnLayout {
          visible: root.setupOpen
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.spacing.md
          RowLayout {
            Layout.fillWidth: true
            Label { text: "Settings"; color: Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.body; font.bold: true; Layout.fillWidth: true }
            Label { visible: root.showHotkeys; text: "Ctrl+J/K select"; color: Color.menu.text; opacity: .65; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
          }
          RowLayout {
            Layout.fillWidth: true
            Label { text: root.settingsSelectedIndex === 0 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Show in menu bar"; color: Color.menu.text; Layout.fillWidth: true }
            Switch {
              id: barIconSwitch
              checked: root.showBarIcon
              onToggled: if (checked !== root.showBarIcon) root.savePreferences({showBarIcon: checked})
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                  root.savePreferences({showBarIcon: !root.showBarIcon})
                  event.accepted = true
                }
              }
            }
          }
          RowLayout {
            Layout.fillWidth: true
            Label { text: root.settingsSelectedIndex === 1 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Show shortcut hints"; color: Color.menu.text; Layout.fillWidth: true }
            Switch {
              id: hotkeysSwitch
              checked: root.showHotkeys
              onToggled: if (checked !== root.showHotkeys) root.savePreferences({showHotkeys: checked})
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                  root.savePreferences({showHotkeys: !root.showHotkeys})
                  event.accepted = true
                }
              }
            }
          }
          GridLayout {
            columns: 3
            columnSpacing: Style.spacing.md
            rowSpacing: Style.spacing.sm
            Layout.fillWidth: true
            Label { text: root.settingsSelectedIndex === 2 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Copy translation"; color: Color.menu.text }
            ShortcutRecorder { id: copyRecorder; actionKey: "copy"; shortcut: root.shortcuts.copy; settingsIndex: 2 }
            Label { text: root.settingsSelectedIndex === 3 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Copy source and translation"; color: Color.menu.text }
            ShortcutRecorder { id: copyAllRecorder; actionKey: "copyAll"; shortcut: root.shortcuts.copyAll; settingsIndex: 3 }
            Label { text: root.settingsSelectedIndex === 4 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Switch languages"; color: Color.menu.text }
            ShortcutRecorder { id: switchRecorder; actionKey: "switch"; shortcut: root.shortcuts.switch; settingsIndex: 4 }
            Label { text: root.settingsSelectedIndex === 5 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Clear text"; color: Color.menu.text }
            ShortcutRecorder { id: clearRecorder; actionKey: "clear"; shortcut: root.shortcuts.clear; settingsIndex: 5 }
            Label { text: root.settingsSelectedIndex === 6 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Translate"; color: Color.menu.text }
            ShortcutRecorder { id: translateRecorder; actionKey: "translate"; shortcut: root.shortcuts.translate; settingsIndex: 6 }
            Label { text: root.settingsSelectedIndex === 7 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Undo Clear"; color: Color.menu.text }
            ShortcutRecorder { id: undoRecorder; actionKey: "undo"; shortcut: root.shortcuts.undo; settingsIndex: 7 }
          }
          Label { visible: root.settingsError !== ""; text: root.settingsError; color: "#e06c75"; wrapMode: Text.WordWrap; Layout.fillWidth: true }
          Item { Layout.fillHeight: true }
          RowLayout {
            Layout.fillWidth: true
            Label { text: root.settingsSelectedIndex === 8 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Button {
              id: restoreButton
              focusable: true
              text: root.resetConfirmationVisible ? "Confirm restore" : "Restore all default shortcuts"
              onClicked: root.restoreShortcutDefaults()
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                  root.restoreShortcutDefaults()
                  event.accepted = true
                }
              }
            }
          }
        }
      }
    }
  }
}
