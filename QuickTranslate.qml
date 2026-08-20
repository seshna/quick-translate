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
  property var shortcuts: ({})
  readonly property var shortcutActions: ["copy", "copyAll", "switch", "clear", "translate", "undo"]
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
  property var settingsControls: []
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("quick_translate.py").toString().replace(/^file:\/\//, ""))
  property var languages: []
  readonly property string languagesPath: decodeURIComponent(Qt.resolvedUrl("languages.json").toString().replace(/^file:\/\//, ""))
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
    function activateSetting() { beginRecording() }
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
  function loadLanguages(text) {
    try {
      var parsed = JSON.parse(text)
      if (!Array.isArray(parsed) || parsed.length === 0) throw new Error("empty language catalogue")
      languages = parsed
      syncLanguageSelectors()
    } catch (e) {
      message = "Could not load the language catalogue."
      messageError = true
    }
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
    syncBarIconVisibility()
  }
  function syncBarIconVisibility() {
    if (!shell || !shell.bar || typeof shell.bar.moduleWidgets !== "function") return
    var pluginId = (manifest && manifest.id) || "shaun.quick-translate"
    var widgets = shell.bar.moduleWidgets(pluginId)
    for (var i = 0; i < widgets.length; i++) {
      if (widgets[i] && typeof widgets[i].setBarIconVisible === "function")
        widgets[i].setBarIconVisible(showBarIcon)
    }
  }
  function savePreferences(params, done) {
    run("preferences.set", params, function(reply) {
      if (showReply(reply) && reply.data) applyPreferences(reply.data)
      if (done) done(reply)
    })
  }
  function saveLanguages() { savePreferences({sourceLanguage: sourceLanguage, targetLanguage: targetLanguage}) }
  function shortcut(action) { return shortcuts[action] || "" }
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
    var next = {}
    for (var key in shortcuts) next[key] = shortcuts[key]
    next[action] = sequence
    savePreferences({shortcuts: next}, function(reply) {
      if (reply && reply.ok) { recordingAction = ""; settingsError = "" }
      else settingsError = reply && reply.error ? reply.error.message : "Could not save shortcut."
    })
  }
  function restoreShortcutDefaults() {
    if (!resetConfirmationVisible) { resetConfirmationVisible = true; return }
    run("preferences.resetShortcuts", {}, function(reply) {
      if (showReply(reply) && reply.data) {
        applyPreferences(reply.data)
        resetConfirmationVisible = false
        settingsError = ""
      }
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
    settingsSelectedIndex = (settingsSelectedIndex + direction + settingsControls.length) % settingsControls.length
    focusSettingsSelection()
  }
  function focusSettingsSelection() {
    Qt.callLater(function() {
      if (!setupOpen) return
      var control = settingsControls[settingsSelectedIndex]
      if (control) control.forceActiveFocus()
    })
  }
  function canPerform(action) {
    if (setupOpen) return false
    if (action === "switch") return !busy
    if (action === "translate") return canTranslate
    if (action === "undo") return clearUndoAvailable && !busy
    if (action === "clear") return !busy && (sourceBox.text.length > 0 || translatedText.length > 0)
    if (action === "copy" || action === "copyAll") return !busy && translatedText.length > 0
    return false
  }
  function actionForShortcut(event) {
    var sequence = shortcutForEvent(event)
    for (var i = 0; i < shortcutActions.length; i++) {
      var action = shortcutActions[i]
      if (sequence === shortcuts[action] && canPerform(action)) return action
    }
    return ""
  }
  function performAction(action) {
    if (!canPerform(action)) return false
    if (action === "switch") { swap(); return true }
    if (action === "translate") { translate(); return true }
    if (action === "undo") { undoClear(); return true }
    if (action === "clear") { clearAll(); return true }
    if (action === "copy") { copy(translatedText, "translation"); return true }
    if (action === "copyAll") { copy(sourceBox.text + "\n\n" + translatedText, "both"); return true }
    return false
  }
  function handleActionShortcut(event) { return performAction(actionForShortcut(event)) }
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

  Component.onCompleted: {
    settingsControls = [barIconSwitch, hotkeysSwitch, copyRecorder, copyAllRecorder, switchRecorder, clearRecorder, translateRecorder, undoRecorder, restoreButton]
    run("preferences.get", {}, function(reply) { if (reply && reply.ok) applyPreferences(reply.data) })
  }

  FileView {
    path: root.languagesPath
    onLoaded: root.loadLanguages(text())
    onLoadFailed: {
      root.message = "Could not load the language catalogue."
      root.messageError = true
    }
  }

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
      sequence: root.shortcut("copy")
      context: Qt.WindowShortcut
      enabled: root.canPerform("copy")
      onActivated: root.performAction("copy")
    }
    Shortcut {
      sequence: root.shortcut("copyAll")
      context: Qt.WindowShortcut
      enabled: root.canPerform("copyAll")
      onActivated: root.performAction("copyAll")
    }
    Shortcut {
      sequence: root.shortcut("clear")
      context: Qt.WindowShortcut
      enabled: root.canPerform("clear")
      onActivated: root.performAction("clear")
    }
    Shortcut {
      sequence: root.shortcut("switch")
      context: Qt.WindowShortcut
      enabled: root.canPerform("switch")
      onActivated: root.performAction("switch")
    }
    Shortcut {
      sequence: root.shortcut("translate")
      context: Qt.WindowShortcut
      enabled: root.canPerform("translate")
      onActivated: root.performAction("translate")
    }
    Shortcut {
      sequence: root.shortcut("undo")
      context: Qt.WindowShortcut
      enabled: root.canPerform("undo")
      onActivated: root.performAction("undo")
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
      height: Math.min(690, panel.height - Style.gapsOut * 2, content.implicitHeight + contentTopInset + contentBottomInset)
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
      Flickable {
        id: contentFlickable
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset; anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset; anchors.leftMargin: card.contentLeftInset
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
        id: content
        width: contentFlickable.width
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
          HotkeyButton { actionText: "⇄"; hotkeyText: root.shortcut("switch"); available: !root.busy; onClicked: root.swap() }
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
        Item { Layout.preferredHeight: Style.spacing.md }
        ScrollView {
          visible: !root.setupOpen
          Layout.fillWidth: true
          Layout.preferredHeight: Math.max(120, Math.min(220, panel.height * .28))
          TextArea {
            id: sourceBox
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
        }
        RowLayout {
          visible: !root.setupOpen
          Layout.fillWidth: true
          Label { visible: root.translating; text: "Translating…"; color: Color.menu.text; opacity: .75; font.family: Style.font.menuFamily }
          Item { Layout.fillWidth: true }
          Label { text: sourceBox.text.length + " / 5,000"; color: sourceBox.text.length > 5000 ? "#e06c75" : Color.menu.text; opacity: .75 }
        }
        ScrollView {
          visible: !root.setupOpen
          Layout.fillWidth: true
          Layout.preferredHeight: Math.max(120, Math.min(220, panel.height * .28))
          opacity: .55
          TextArea { id: outputBox; text: root.translatedText; readOnly: true; placeholderText: root.showHotkeys ? root.shortcut("translate") + " to translate" : "Translation"; wrapMode: TextEdit.Wrap; selectByMouse: true; color: Color.menu.text; font.family: Style.font.menuFamily }
        }
        Label { visible: !root.setupOpen && root.message !== ""; text: root.message; color: root.messageError ? "#e06c75" : Color.menu.text; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        RowLayout {
          visible: !root.setupOpen
          Layout.fillWidth: true
          HotkeyButton { actionText: "󰆴  Clear"; compactActionText: "󰆴"; hotkeyText: root.shortcut("clear"); reservedText: "󰆴  Clear  " + root.shortcut("clear"); available: !root.busy && (sourceBox.text.length > 0 || root.translatedText.length > 0); visuallyMuted: sourceBox.text.length === 0 && root.translatedText.length === 0; onClicked: root.clearAll() }
          HotkeyButton { actionText: root.copiedAction === "translation" ? "󰆏  Copied ✓" : "󰆏  Copy translation"; compactActionText: root.copiedAction === "translation" ? "󰆏 ✓" : "󰆏"; hotkeyText: root.copiedAction === "translation" ? "" : root.shortcut("copy"); reservedText: "󰆏  Copy translation  " + root.shortcut("copy"); available: !root.busy && root.translatedText.length > 0; visuallyMuted: root.translatedText.length === 0; onClicked: root.copy(root.translatedText, "translation") }
          HotkeyButton { actionText: root.copiedAction === "both" ? "󰆏 󰆏  Copied ✓" : "󰆏 󰆏  Copy both"; compactActionText: root.copiedAction === "both" ? "󰆏 󰆏 ✓" : "󰆏 󰆏"; hotkeyText: root.copiedAction === "both" ? "" : root.shortcut("copyAll"); reservedText: "󰆏 󰆏  Copy both  " + root.shortcut("copyAll"); available: !root.busy && root.translatedText.length > 0; visuallyMuted: root.translatedText.length === 0; onClicked: root.copy(sourceBox.text + "\n\n" + root.translatedText, "both") }
          Item { Layout.fillWidth: true }
          HotkeyButton { actionText: root.translating ? "󰗊  Translating…" : "󰗊  Translate"; compactActionText: root.translating ? "󰗊 …" : "󰗊"; hotkeyText: root.translating ? "" : root.shortcut("translate"); reservedText: "󰗊  Translate  " + root.shortcut("translate"); available: root.canTranslate; visuallyMuted: sourceBox.text.trim().length === 0 || sourceBox.text.length > 5000; onClicked: root.translate() }
        }
        ColumnLayout {
          visible: root.setupOpen
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.spacing.md
          RowLayout {
            Layout.fillWidth: true
            Label { text: "About"; color: Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.body; font.bold: true; Layout.fillWidth: true }
          }
          Label {
            Layout.fillWidth: true
            text: "Quick Translate uses Google’s unofficial no-key Translate endpoint in an HTTPS request body.\nThis plugin does not save your text, but it’s still best to avoid sending sensitive content to Google.\n"
            color: Color.menu.text
            opacity: .80
            wrapMode: Text.WordWrap
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }
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
              function activateSetting() { root.savePreferences({showBarIcon: !root.showBarIcon}) }
              onToggled: if (checked !== root.showBarIcon) root.savePreferences({showBarIcon: checked})
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                  activateSetting()
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
              function activateSetting() { root.savePreferences({showHotkeys: !root.showHotkeys}) }
              onToggled: if (checked !== root.showHotkeys) root.savePreferences({showHotkeys: checked})
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                  activateSetting()
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
            ShortcutRecorder { id: copyRecorder; actionKey: "copy"; shortcut: root.shortcut("copy"); settingsIndex: 2 }
            Label { text: root.settingsSelectedIndex === 3 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Copy source and translation"; color: Color.menu.text }
            ShortcutRecorder { id: copyAllRecorder; actionKey: "copyAll"; shortcut: root.shortcut("copyAll"); settingsIndex: 3 }
            Label { text: root.settingsSelectedIndex === 4 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Switch languages"; color: Color.menu.text }
            ShortcutRecorder { id: switchRecorder; actionKey: "switch"; shortcut: root.shortcut("switch"); settingsIndex: 4 }
            Label { text: root.settingsSelectedIndex === 5 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Clear text"; color: Color.menu.text }
            ShortcutRecorder { id: clearRecorder; actionKey: "clear"; shortcut: root.shortcut("clear"); settingsIndex: 5 }
            Label { text: root.settingsSelectedIndex === 6 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Translate"; color: Color.menu.text }
            ShortcutRecorder { id: translateRecorder; actionKey: "translate"; shortcut: root.shortcut("translate"); settingsIndex: 6 }
            Label { text: root.settingsSelectedIndex === 7 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Undo Clear"; color: Color.menu.text }
            ShortcutRecorder { id: undoRecorder; actionKey: "undo"; shortcut: root.shortcut("undo"); settingsIndex: 7 }
          }
          Label { visible: root.settingsError !== ""; text: root.settingsError; color: "#e06c75"; wrapMode: Text.WordWrap; Layout.fillWidth: true }
          RowLayout {
            Layout.fillWidth: true
            Label { text: root.settingsSelectedIndex === 8 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Button {
              id: restoreButton
              focusable: true
              bordered: true
              function activateSetting() { root.restoreShortcutDefaults() }
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
}
