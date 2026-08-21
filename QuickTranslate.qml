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
  property string translator: "google"
  property string translatedText: ""
  property var shortcuts: ({})
  readonly property var shortcutActions: ["copy", "copyAll", "switch", "clear", "translate", "undo"]
  property bool showBarIcon: true
  property bool showHotkeys: true
  property bool openaiApiKeyConfigured: false
  property string openaiReasoningEffort: "minimal"
  property var translationContexts: []
  property string selectedContextId: ""
  property string editingContextId: ""
  property bool contextEditorOpen: false
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
  property var engines: []
  readonly property var openaiReasoningEfforts: ["minimal", "low", "medium", "high"]
  readonly property string languagesPath: decodeURIComponent(Qt.resolvedUrl("languages.json").toString().replace(/^file:\/\//, ""))
  readonly property int maxChars: {
    var engine = engineFor(translator)
    return engine && engine.maxChars ? engine.maxChars : 5000
  }
  readonly property bool canTranslate: !busy && sourceBox.text.trim().length > 0 && sourceBox.text.length <= maxChars

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
    fromPicker.currentIndex = sourceLanguages().map(function(item) { return item[0] }).indexOf(sourceLanguage)
    toPicker.currentIndex = targetLanguages().map(function(item) { return item[0] }).indexOf(targetLanguage)
    fromPicker.editText = nameFor(sourceLanguage)
    toPicker.editText = nameFor(targetLanguage)
  }
  function engineFor(id) { for (var i = 0; i < engines.length; i++) if (engines[i].id === id) return engines[i]; return null }
  function activeTranslatorLabel() {
    if (translator === "ollama") return "Ollama Local · Gemma 3"
    if (translator === "openai") return "OpenAI · GPT-5 mini"
    var engine = engineFor(translator)
    return engine ? engine.name : "Google"
  }
  function usesLlm() { return translator === "ollama" || translator === "openai" }
  function contextOptions() {
    var options = [{id: "", label: "No context"}]
    for (var i = 0; i < translationContexts.length; i++)
      options.push({id: translationContexts[i].id, label: translationContexts[i].name})
    return options
  }
  function contextIndex(id) {
    var options = contextOptions()
    for (var i = 0; i < options.length; i++) if (options[i].id === id) return i
    return 0
  }
  function contextForId(id) {
    for (var i = 0; i < translationContexts.length; i++)
      if (translationContexts[i].id === id) return translationContexts[i]
    return null
  }
  function newContextId() { return "context-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8) }
  function reasoningEffortLabel(value) { return value.charAt(0).toUpperCase() + value.slice(1) }
  function openaiReasoningEffortIndex() { return openaiReasoningEfforts.indexOf(openaiReasoningEffort) }
  function translatorOptions() {
    var groups = [
      {title: "No key / public web", ids: ["google", "apertium", "bing", "reverso"]},
      {title: "Local model", ids: ["ollama"]},
      {title: "API key required", ids: ["openai"]}
    ]
    var options = []
    for (var i = 0; i < groups.length; i++) {
      var group = groups[i]
      var groupEngines = []
      for (var j = 0; j < group.ids.length; j++) {
        var engine = engineFor(group.ids[j])
        if (engine) groupEngines.push(engine)
      }
      if (groupEngines.length === 0) continue
      options.push({section: true, label: group.title})
      for (var k = 0; k < groupEngines.length; k++)
        options.push({section: false, id: groupEngines[k].id, label: groupEngines[k].name})
    }
    return options
  }
  function translatorOptionIndex() {
    var options = translatorOptions()
    for (var i = 0; i < options.length; i++) if (options[i].id === translator) return i
    return 0
  }
  function pairsForEngine() { var engine = engineFor(translator); return engine && engine.pairs ? engine.pairs : [] }
  // An empty pairs list means either the engine has no pair restriction of
  // its own (e.g. Google, Bing) or engines/languages haven't loaded yet —
  // in both cases fall back to the full language catalogue rather than
  // showing no options.
  function sourceCodes() {
    var pairs = pairsForEngine()
    if (pairs.length === 0) return languages.map(function(item) { return item[0] })
    var result = []
    for (var i = 0; i < pairs.length; i++) if (result.indexOf(pairs[i][0]) < 0) result.push(pairs[i][0])
    return result
  }
  function targetCodes(source) {
    var pairs = pairsForEngine()
    if (pairs.length === 0) return languages.map(function(item) { return item[0] })
    var result = []
    for (var i = 0; i < pairs.length; i++) if (pairs[i][0] === source && result.indexOf(pairs[i][1]) < 0) result.push(pairs[i][1])
    if (sourceCodes().indexOf(source) >= 0 && result.indexOf(source) < 0) result.push(source)
    return result
  }
  function sourceLanguages() { var codes = sourceCodes(); return languages.filter(function(item) { return codes.indexOf(item[0]) >= 0 }) }
  function targetLanguages() { var codes = targetCodes(sourceLanguage); return languages.filter(function(item) { return codes.indexOf(item[0]) >= 0 }) }
  function normalizeLanguagePair() {
    var sources = sourceCodes()
    if (sources.length === 0) return
    if (sources.indexOf(sourceLanguage) < 0) sourceLanguage = sources[0]
    var targets = targetCodes(sourceLanguage)
    if (targets.indexOf(targetLanguage) < 0) targetLanguage = targets[0]
    syncLanguageSelectors()
  }
  function loadLanguages(text) {
    try {
      var parsed = JSON.parse(text)
      if (!Array.isArray(parsed) || parsed.length === 0) throw new Error("empty language catalogue")
      languages = parsed
      normalizeLanguagePair()
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
    translator = data.translator || "google"
    shortcuts = data.shortcuts || shortcuts
    showBarIcon = data.showBarIcon !== false
    showHotkeys = data.showHotkeys !== false
    openaiApiKeyConfigured = data.openaiApiKeyConfigured === true
    openaiReasoningEffort = openaiReasoningEfforts.indexOf(data.openaiReasoningEffort) >= 0 ? data.openaiReasoningEffort : "minimal"
    translationContexts = Array.isArray(data.translationContexts) ? data.translationContexts : []
    selectedContextId = contextForId(data.selectedContextId) ? data.selectedContextId : ""
    normalizeLanguagePair()
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
  function saveLanguages() { savePreferences({translator: translator, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage}) }
  function setOpenaiReasoningEffort(value) {
    if (openaiReasoningEfforts.indexOf(value) < 0) return
    openaiReasoningEffort = value
    savePreferences({openaiReasoningEffort: value})
  }
  function setSelectedContext(value) {
    if (value !== "" && !contextForId(value)) return
    selectedContextId = value
    savePreferences({selectedContextId: value})
  }
  function startNewContext() {
    editingContextId = ""
    contextNameField.text = ""
    contextInstructionField.text = ""
    contextNameField.forceActiveFocus()
  }
  function loadContextForEditing(value) {
    var context = contextForId(value)
    editingContextId = context ? context.id : ""
    contextNameField.text = context ? context.name : ""
    contextInstructionField.text = context ? context.instruction : ""
  }
  function saveContext() {
    var name = contextNameField.text.trim()
    var instruction = contextInstructionField.text.trim()
    if (name === "" || instruction === "") { settingsError = "Give the context both a name and an instruction."; return }
    var id = editingContextId === "" ? newContextId() : editingContextId
    var contexts = []
    for (var i = 0; i < translationContexts.length; i++)
      if (translationContexts[i].id !== id) contexts.push(translationContexts[i])
    contexts.push({id: id, name: name, instruction: instruction})
    selectedContextId = id
    editingContextId = id
    savePreferences({translationContexts: contexts, selectedContextId: id}, function(reply) {
      if (reply && reply.ok) { settingsError = ""; loadContextForEditing(id) }
      else settingsError = reply && reply.error ? reply.error.message : "Could not save translation context."
    })
  }
  function removeContext() {
    if (editingContextId === "") return
    var id = editingContextId
    var contexts = translationContexts.filter(function(context) { return context.id !== id })
    selectedContextId = selectedContextId === id ? "" : selectedContextId
    startNewContext()
    savePreferences({translationContexts: contexts, selectedContextId: selectedContextId}, function(reply) {
      if (reply && reply.ok) settingsError = ""
      else settingsError = reply && reply.error ? reply.error.message : "Could not remove translation context."
    })
  }
  function setTranslator(value) {
    if (!engineFor(value)) return
    translator = value
    if (!usesLlm()) contextEditorOpen = false
    if (settingsControls[settingsSelectedIndex] && !settingsControls[settingsSelectedIndex].visible)
      settingsSelectedIndex = 0
    normalizeLanguagePair()
    saveLanguages()
  }
  function saveOpenaiKey() {
    var key = openaiKeyField.text.trim()
    if (key === "") { settingsError = "Enter an OpenAI API key, or use Remove key."; return }
    savePreferences({openaiApiKey: key}, function(reply) {
      if (reply && reply.ok) { openaiKeyField.text = ""; settingsError = "" }
      else settingsError = reply && reply.error ? reply.error.message : "Could not save OpenAI API key."
    })
  }
  function clearOpenaiKey() {
    savePreferences({clearOpenaiApiKey: true}, function(reply) {
      if (reply && reply.ok) { openaiKeyField.text = ""; settingsError = "" }
      else settingsError = reply && reply.error ? reply.error.message : "Could not remove OpenAI API key."
    })
  }
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
    if (settingsControls.length === 0) return
    var initialIndex = settingsSelectedIndex
    do {
      settingsSelectedIndex = (settingsSelectedIndex + direction + settingsControls.length) % settingsControls.length
    } while (!settingsControls[settingsSelectedIndex].visible && settingsSelectedIndex !== initialIndex)
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
    run("translate", {text: sourceBox.text, translator: translator, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage}, function(reply) {
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
    settingsControls = [translatorPicker, openaiKeyField, removeOpenaiKeyButton, barIconSwitch, hotkeysSwitch, copyRecorder, copyAllRecorder, switchRecorder, clearRecorder, translateRecorder, undoRecorder, restoreButton]
    run("engines.get", {}, function(reply) {
      if (reply && reply.ok) engines = reply.data || []
      run("preferences.get", {}, function(preferences) { if (preferences && preferences.ok) applyPreferences(preferences.data) })
    })
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
            model: root.sourceLanguages().map(function(x) { return x[1] })
            currentIndex: 0
            onEditTextChanged: {
              var match = find(editText, Qt.MatchContains)
              if (match >= 0) currentIndex = match
            }
            onActivated: {
              root.sourceLanguage = root.sourceLanguages()[currentIndex][0]
              root.normalizeLanguagePair()
              root.syncLanguageSelectors()
              root.saveLanguages()
            }
            onAccepted: {
              root.sourceLanguage = root.sourceLanguages()[currentIndex][0]
              root.normalizeLanguagePair()
              root.syncLanguageSelectors()
              root.saveLanguages()
            }
          }
          HotkeyButton { actionText: "⇄"; hotkeyText: root.shortcut("switch"); available: !root.busy; onClicked: root.swap() }
          ComboBox {
            id: toPicker
            Layout.fillWidth: true
            editable: true
            model: root.targetLanguages().map(function(x) { return x[1] })
            currentIndex: 1
            onEditTextChanged: {
              var match = find(editText, Qt.MatchContains)
              if (match >= 0) currentIndex = match
            }
            onActivated: {
              root.targetLanguage = root.targetLanguages()[currentIndex][0]
              root.syncLanguageSelectors()
              root.saveLanguages()
            }
            onAccepted: {
              root.targetLanguage = root.targetLanguages()[currentIndex][0]
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
              if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                var forward = event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier)
                var next = sourceBox.nextItemInFocusChain(forward)
                if (next) next.forceActiveFocus()
                event.accepted = true
                return
              }
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
          Label { text: root.activeTranslatorLabel(); color: Color.menu.text; opacity: .75; font.family: Style.font.menuFamily }
          ComboBox {
            id: contextPicker
            visible: root.usesLlm()
            Layout.preferredWidth: 260
            model: root.contextOptions()
            textRole: "label"
            currentIndex: root.contextIndex(root.selectedContextId)
            delegate: MenuItem {
              required property var model
              required property int index
              width: ListView.view.width
              text: model.label
              highlighted: contextPicker.highlightedIndex === index
            }
            onActivated: root.setSelectedContext(root.contextOptions()[currentIndex].id)
          }
          ComboBox {
            id: openaiReasoningPicker
            visible: root.translator === "openai"
            model: root.openaiReasoningEfforts.map(function(effort) { return { label: root.reasoningEffortLabel(effort), value: effort } })
            textRole: "label"
            currentIndex: root.openaiReasoningEffortIndex()
            delegate: MenuItem {
              required property var model
              required property int index
              width: ListView.view.width
              text: model.label
              highlighted: openaiReasoningPicker.highlightedIndex === index
            }
            onActivated: root.setOpenaiReasoningEffort(root.openaiReasoningEfforts[currentIndex])
          }
          Label { text: sourceBox.text.length + " / " + root.maxChars.toLocaleString(); color: sourceBox.text.length > root.maxChars ? "#e06c75" : Color.menu.text; opacity: .75 }
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
          HotkeyButton { actionText: root.translating ? "󰗊  Translating…" : "󰗊  Translate"; compactActionText: root.translating ? "󰗊 …" : "󰗊"; hotkeyText: root.translating ? "" : root.shortcut("translate"); reservedText: "󰗊  Translate  " + root.shortcut("translate"); available: root.canTranslate; visuallyMuted: sourceBox.text.trim().length === 0 || sourceBox.text.length > root.maxChars; onClicked: root.translate() }
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
            text: "Choose Google, Apertium, Bing, Reverso, Ollama Local, or OpenAI. Your text is sent to the selected service.\nOllama Local uses localhost; OpenAI sends text to OpenAI. Public no-key web endpoints are unofficial, may change or rate-limit requests, and are not suitable for sensitive text.\n"
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
            Label { text: "Translator"; color: Color.menu.text; Layout.fillWidth: true }
            ComboBox {
              id: translatorPicker
              Layout.minimumWidth: Style.space(260)
              Layout.preferredWidth: Style.space(260)
              model: root.translatorOptions()
              textRole: "label"
              currentIndex: root.translatorOptionIndex()
              delegate: MenuItem {
                required property var model
                required property int index
                width: ListView.view.width
                text: model.label
                enabled: !model.section
                opacity: model.section ? .65 : 1
                highlighted: !model.section && translatorPicker.highlightedIndex === index
              }
              onActivated: {
                var option = root.translatorOptions()[currentIndex]
                if (option && !option.section) root.setTranslator(option.id)
              }
            }
          }
          Label {
            visible: root.translator === "ollama" || root.translator === "openai"
            Layout.fillWidth: true
            text: root.translator === "ollama"
              ? "Ollama setup: install and start Ollama, then run: ollama pull gemma3 (about 3.3 GB)"
              : "OpenAI setup: create an API key at platform.openai.com/api-keys, then paste it below."
            color: Color.menu.text
            opacity: .80
            wrapMode: Text.WordWrap
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
          Button {
            visible: root.usesLlm()
            Layout.fillWidth: true
            bordered: true
            text: (root.contextEditorOpen ? "󰅂" : "󰅀") + "  Translation contexts"
            onClicked: root.contextEditorOpen = !root.contextEditorOpen
          }
          ColumnLayout {
            visible: root.usesLlm() && root.contextEditorOpen
            Layout.fillWidth: true
            spacing: Style.spacing.sm
            Label {
              Layout.fillWidth: true
              text: "Contexts guide Gemma locally and are sent to OpenAI when it is selected."
              color: Color.menu.text
              opacity: .80
              wrapMode: Text.WordWrap
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
            RowLayout {
              Layout.fillWidth: true
              Label { text: "Saved context"; color: Color.menu.text; Layout.fillWidth: true }
              ComboBox {
                id: contextEditorPicker
                Layout.preferredWidth: 260
                model: root.contextOptions()
                textRole: "label"
                currentIndex: root.contextIndex(root.editingContextId)
                delegate: MenuItem {
                  required property var model
                  required property int index
                  width: ListView.view.width
                  text: model.label
                  highlighted: contextEditorPicker.highlightedIndex === index
                }
                onActivated: root.loadContextForEditing(root.contextOptions()[currentIndex].id)
              }
              Button { text: "New"; bordered: true; onClicked: root.startNewContext() }
            }
            RowLayout {
              Layout.fillWidth: true
              Label { text: "Name"; color: Color.menu.text; Layout.preferredWidth: 120 }
              TextField {
                id: contextNameField
                Layout.fillWidth: true
                placeholderText: "e.g. Formal Japanese"
                maximumLength: 64
                onAccepted: root.saveContext()
              }
            }
            Label { text: "Instruction"; color: Color.menu.text; Layout.fillWidth: true }
            ScrollView {
              Layout.fillWidth: true
              Layout.preferredHeight: 96
              TextArea {
                id: contextInstructionField
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                color: Color.menu.text
                font.family: Style.font.menuFamily
                placeholderText: "e.g. Use polite Japanese and preserve product names."
                onTextChanged: if (text.length > 2000) text = text.slice(0, 2000)
              }
            }
            RowLayout {
              Layout.fillWidth: true
              Item { Layout.fillWidth: true }
              Button { text: "Save context"; bordered: true; onClicked: root.saveContext() }
              Button { text: "Remove"; bordered: true; enabled: root.editingContextId !== ""; onClicked: root.removeContext() }
            }
          }
          RowLayout {
            visible: root.translator === "openai"
            Layout.fillWidth: true
            Label { text: root.settingsSelectedIndex === 1 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "OpenAI API key"; color: Color.menu.text; Layout.fillWidth: true }
            TextField {
              id: openaiKeyField
              visible: root.translator === "openai"
              Layout.preferredWidth: 260
              echoMode: TextInput.Password
              placeholderText: root.openaiApiKeyConfigured ? "Configured — enter replacement" : "Required for OpenAI"
              onAccepted: root.saveOpenaiKey()
            }
          }
          RowLayout {
            visible: root.translator === "openai"
            Layout.fillWidth: true
            Label { text: root.settingsSelectedIndex === 2 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: root.openaiApiKeyConfigured ? "OpenAI key is configured" : "No OpenAI key configured"; color: Color.menu.text; Layout.fillWidth: true }
            Button { text: "Save key"; bordered: true; onClicked: root.saveOpenaiKey() }
            Button { id: removeOpenaiKeyButton; visible: root.translator === "openai"; text: "Remove key"; bordered: true; enabled: root.openaiApiKeyConfigured; onClicked: root.clearOpenaiKey() }
          }
          RowLayout {
            Layout.fillWidth: true
            Label { text: root.settingsSelectedIndex === 3 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
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
            Label { text: root.settingsSelectedIndex === 4 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
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
            Label { text: root.settingsSelectedIndex === 5 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Copy translation"; color: Color.menu.text }
            ShortcutRecorder { id: copyRecorder; actionKey: "copy"; shortcut: root.shortcut("copy"); settingsIndex: 5 }
            Label { text: root.settingsSelectedIndex === 6 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Copy source and translation"; color: Color.menu.text }
            ShortcutRecorder { id: copyAllRecorder; actionKey: "copyAll"; shortcut: root.shortcut("copyAll"); settingsIndex: 6 }
            Label { text: root.settingsSelectedIndex === 7 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Switch languages"; color: Color.menu.text }
            ShortcutRecorder { id: switchRecorder; actionKey: "switch"; shortcut: root.shortcut("switch"); settingsIndex: 7 }
            Label { text: root.settingsSelectedIndex === 8 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Clear text"; color: Color.menu.text }
            ShortcutRecorder { id: clearRecorder; actionKey: "clear"; shortcut: root.shortcut("clear"); settingsIndex: 8 }
            Label { text: root.settingsSelectedIndex === 9 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Translate"; color: Color.menu.text }
            ShortcutRecorder { id: translateRecorder; actionKey: "translate"; shortcut: root.shortcut("translate"); settingsIndex: 9 }
            Label { text: root.settingsSelectedIndex === 10 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Label { text: "Undo Clear"; color: Color.menu.text }
            ShortcutRecorder { id: undoRecorder; actionKey: "undo"; shortcut: root.shortcut("undo"); settingsIndex: 10 }
          }
          Label { visible: root.settingsError !== ""; text: root.settingsError; color: "#e06c75"; wrapMode: Text.WordWrap; Layout.fillWidth: true }
          RowLayout {
            Layout.fillWidth: true
            Label { text: root.settingsSelectedIndex === 11 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
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
