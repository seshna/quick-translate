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
  property var pendingOperations: []
  property string copiedAction: ""
  property string sourceLanguage: "en"
  property string targetLanguage: "ja"
  property bool syncingLanguageSelectors: false
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
  property var profiles: []
  property bool profilesOpen: false
  property bool creatingProfile: false
  property int profileSelectedIndex: 0
  property string profileDeleteConfirmationId: ""
  property string profilesError: ""
  property bool contextsOpen: false
  property bool contextEditorOpen: false
  property int contextSelectedIndex: 0
  property string contextDeleteConfirmationId: ""
  property string contextsError: ""
  property string editingContextId: ""
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
  property int preferenceGeneration: 0
  property var preferenceFieldRevisions: ({})
  property var mainControls: []
  property int mainSelectedIndex: 3
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
    function focusControl() { actionButton.forceActiveFocus() }

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
  function syncLanguageSelectors() {
    if (!fromPicker || !toPicker) return
    syncingLanguageSelectors = true
    fromPicker.currentIndex = sourceLanguages().map(function(item) { return item[0] }).indexOf(sourceLanguage)
    toPicker.currentIndex = targetLanguages().map(function(item) { return item[0] }).indexOf(targetLanguage)
    fromPicker.editText = nameFor(sourceLanguage)
    toPicker.editText = nameFor(targetLanguage)
    syncingLanguageSelectors = false
  }
  function exactLanguageIndex(options, label) {
    var normalized = String(label || "").trim().toLowerCase()
    for (var i = 0; i < options.length; i++)
      if (String(options[i][1]).toLowerCase() === normalized) return i
    return -1
  }
  function selectSourceLanguage(index) {
    var options = sourceLanguages()
    if (index < 0 || index >= options.length) return
    sourceLanguage = options[index][0]
    normalizeLanguagePair()
    syncLanguageSelectors()
    saveLanguages()
  }
  function selectTargetLanguage(index) {
    var options = targetLanguages()
    if (index < 0 || index >= options.length) return
    targetLanguage = options[index][0]
    syncLanguageSelectors()
    saveLanguages()
  }
  function commitDisplayedLanguages() {
    var previousSource = sourceLanguage
    var previousTarget = targetLanguage
    var sourceLabel = fromPicker.editText
    var targetLabel = toPicker.editText
    var sourceOptions = sourceLanguages()
    var sourceIndex = exactLanguageIndex(sourceOptions, sourceLabel)
    if (sourceIndex >= 0) sourceLanguage = sourceOptions[sourceIndex][0]
    var targetOptions = targetLanguages()
    var targetIndex = exactLanguageIndex(targetOptions, targetLabel)
    if (targetIndex >= 0) targetLanguage = targetOptions[targetIndex][0]
    normalizeLanguagePair()
    syncLanguageSelectors()
    return sourceLanguage !== previousSource || targetLanguage !== previousTarget
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
  function newProfileId() { return "profile-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8) }
  function profileForId(id) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].id === id) return profiles[i]
    return null
  }
  function profileContextLabel(id) {
    var context = contextForId(id)
    return context ? context.name : "No context"
  }
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
  function startOperation(operation, params, done) {
    busy = true
    translating = operation === "translate"
    bridge.payload = JSON.stringify({operation: operation, params: params || {}})
    bridge.done = done
    bridge.command = ["python3", helperPath]
    bridge.running = true
  }
  function run(operation, params, done) {
    if (busy) {
      pendingOperations = pendingOperations.concat([{operation: operation, params: params || {}, done: done}])
      return
    }
    startOperation(operation, params, done)
  }
  function startNextOperation() {
    if (busy || pendingOperations.length === 0) return
    var next = pendingOperations[0]
    pendingOperations = pendingOperations.slice(1)
    startOperation(next.operation, next.params, next.done)
  }
  function showReply(reply) {
    if (reply && reply.ok) { message = ""; messageError = false; return true }
    message = reply && reply.error ? reply.error.message : "The helper did not return a valid response."
    messageError = true; return false
  }
  function translationRequestIsCurrent(request) {
    return sourceBox.text === request.text
        && translator === request.translator
        && sourceLanguage === request.sourceLanguage
        && targetLanguage === request.targetLanguage
        && selectedContextId === request.selectedContextId
        && openaiReasoningEffort === request.openaiReasoningEffort
        && fromPicker.editText === nameFor(sourceLanguage)
        && toPicker.editText === nameFor(targetLanguage)
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
    profiles = Array.isArray(data.profiles) ? data.profiles : []
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
    preferenceGeneration += 1
    var responseRevisions = ({})
    var fields = ["sourceLanguage", "targetLanguage", "translator", "shortcuts", "showBarIcon", "showHotkeys", "openaiReasoningEffort", "translationContexts", "selectedContextId", "profiles"]
    for (var i = 0; i < fields.length; i++) {
      var field = fields[i]
      if (!Object.prototype.hasOwnProperty.call(params, field)) continue
      preferenceFieldRevisions[field] = (preferenceFieldRevisions[field] || 0) + 1
      responseRevisions[field] = preferenceFieldRevisions[field]
    }
    if (Object.prototype.hasOwnProperty.call(params, "openaiApiKey") || params.clearOpenaiApiKey === true) {
      preferenceFieldRevisions.openaiApiKey = (preferenceFieldRevisions.openaiApiKey || 0) + 1
      responseRevisions.openaiApiKey = preferenceFieldRevisions.openaiApiKey
    }
    run("preferences.set", params, function(reply) {
      if (showReply(reply) && reply.data) applyPreferenceResult(params, reply.data, responseRevisions)
      if (done) done(reply)
    })
  }
  function applyPreferenceResult(params, data, responseRevisions) {
    var merged = {
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      translator: translator,
      shortcuts: shortcuts,
      showBarIcon: showBarIcon,
      showHotkeys: showHotkeys,
      openaiApiKeyConfigured: openaiApiKeyConfigured,
      openaiReasoningEffort: openaiReasoningEffort,
      translationContexts: translationContexts,
      selectedContextId: selectedContextId,
      profiles: profiles
    }
    var fields = ["sourceLanguage", "targetLanguage", "translator", "shortcuts", "showBarIcon", "showHotkeys", "openaiReasoningEffort", "translationContexts", "selectedContextId", "profiles"]
    for (var i = 0; i < fields.length; i++) {
      var field = fields[i]
      // A later queued save may already have changed this field locally.
      // Only the newest request for a field may update it.
      if (Object.prototype.hasOwnProperty.call(params, field)
          && preferenceFieldRevisions[field] === responseRevisions[field]) merged[field] = data[field]
    }
    if (Object.prototype.hasOwnProperty.call(params, "openaiApiKey") || params.clearOpenaiApiKey === true)
      if (preferenceFieldRevisions.openaiApiKey === responseRevisions.openaiApiKey)
        merged.openaiApiKeyConfigured = data.openaiApiKeyConfigured === true
    applyPreferences(merged)
  }
  function saveLanguages() { savePreferences({translator: translator, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage}) }
  function setOpenaiReasoningEffort(value) {
    if (openaiReasoningEfforts.indexOf(value) < 0) return
    openaiReasoningEffort = value
    savePreferences({openaiReasoningEffort: value})
  }
  function setSelectedContext(value) {
    if (value !== "" && !contextForId(value)) return
    if (commitDisplayedLanguages()) saveLanguages()
    selectedContextId = value
    savePreferences({selectedContextId: value})
  }
  function openContexts() {
    if (!usesLlm()) return
    setupOpen = false
    profilesOpen = false
    contextsOpen = true
    contextEditorOpen = false
    contextSelectedIndex = 0
    contextDeleteConfirmationId = ""
    contextsError = ""
    Qt.callLater(function() { newContextButton.forceActiveFocus() })
  }
  function closeContexts() {
    contextsOpen = false
    contextEditorOpen = false
    contextSelectedIndex = 0
    contextDeleteConfirmationId = ""
    contextsError = ""
    Qt.callLater(function() { sourceBox.forceActiveFocus() })
  }
  function startNewContext() {
    if (translationContexts.length >= 20) { contextsError = "Keep at most 20 contexts."; return }
    editingContextId = ""
    contextEditorOpen = true
    contextDeleteConfirmationId = ""
    contextsError = ""
    contextNameField.text = ""
    contextInstructionField.text = ""
    Qt.callLater(function() { contextNameField.forceActiveFocus() })
  }
  function editContext(id) {
    var context = contextForId(id)
    if (!context) return
    editingContextId = context.id
    contextEditorOpen = true
    contextDeleteConfirmationId = ""
    contextsError = ""
    contextNameField.text = context.name
    contextInstructionField.text = context.instruction
    Qt.callLater(function() { contextNameField.forceActiveFocus() })
  }
  function selectContext(id) {
    if (id !== "" && !contextForId(id)) return
    setSelectedContext(id)
    closeContexts()
  }
  function saveContext() {
    var name = contextNameField.text.trim()
    var instruction = contextInstructionField.text.trim()
    if (name === "" || instruction === "") { contextsError = "Give the context both a name and an instruction."; return }
    if (commitDisplayedLanguages()) saveLanguages()
    var id = editingContextId === "" ? newContextId() : editingContextId
    var contexts = []
    for (var i = 0; i < translationContexts.length; i++)
      if (translationContexts[i].id !== id) contexts.push(translationContexts[i])
    contexts.push({id: id, name: name, instruction: instruction})
    selectedContextId = id
    savePreferences({translationContexts: contexts, selectedContextId: id}, function(reply) {
      if (reply && reply.ok) {
        contextEditorOpen = false
        contextSelectedIndex = 3 + translationContexts.findIndex(function(context) { return context.id === id }) * 3
        contextsError = ""
      } else contextsError = reply && reply.error ? reply.error.message : "Could not save translation context."
    })
  }
  function removeContext(id) {
    if (contextDeleteConfirmationId !== id) { contextDeleteConfirmationId = id; return }
    var contexts = translationContexts.filter(function(context) { return context.id !== id })
    var nextSelectedId = selectedContextId === id ? "" : selectedContextId
    savePreferences({translationContexts: contexts, selectedContextId: nextSelectedId}, function(reply) {
      if (reply && reply.ok) {
        contextDeleteConfirmationId = ""
        contextSelectedIndex = Math.min(contextSelectedIndex, 2 + translationContexts.length * 3)
        contextsError = ""
      } else contextsError = reply && reply.error ? reply.error.message : "Could not remove translation context."
    })
  }
  function moveContextSelection(direction) {
    if (!contextsOpen || contextEditorOpen) return
    var count = 3 + translationContexts.length * 3
    contextSelectedIndex = (contextSelectedIndex + direction + count) % count
    Qt.callLater(function() {
      if (contextSelectedIndex === 0) newContextButton.forceActiveFocus()
      else if (contextSelectedIndex === 1) backContextButton.forceActiveFocus()
      else if (contextSelectedIndex === 2) noContextButton.forceActiveFocus()
      else {
        var contextIndex = Math.floor((contextSelectedIndex - 3) / 3)
        var item = contextRepeater.itemAt(contextIndex)
        if (!item) return
        var action = (contextSelectedIndex - 3) % 3
        if (action === 0 && item.selectButton) item.selectButton.forceActiveFocus()
        else if (action === 1 && item.editButton) item.editButton.forceActiveFocus()
        else if (action === 2 && item.deleteButton) item.deleteButton.forceActiveFocus()
      }
    })
  }
  function openProfiles() {
    setupOpen = false
    contextsOpen = false
    profilesOpen = true
    creatingProfile = false
    profileSelectedIndex = 0
    profileDeleteConfirmationId = ""
    profilesError = ""
    Qt.callLater(function() { newProfileButton.forceActiveFocus() })
  }
  function closeProfiles() {
    profilesOpen = false
    creatingProfile = false
    profileSelectedIndex = 0
    profileDeleteConfirmationId = ""
    profilesError = ""
    Qt.callLater(function() { sourceBox.forceActiveFocus() })
  }
  function startNewProfile() {
    if (profiles.length >= 20) { profilesError = "Keep at most 20 profiles."; return }
    creatingProfile = true
    profileDeleteConfirmationId = ""
    profilesError = ""
    profileNameField.text = ""
    Qt.callLater(function() { profileNameField.forceActiveFocus() })
  }
  function saveProfile() {
    var name = profileNameField.text.trim()
    if (name === "") { profilesError = "Give the profile a short name."; return }
    var next = profiles.concat([{id: newProfileId(), name: name, translator: translator,
      sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, selectedContextId: selectedContextId}])
    savePreferences({profiles: next}, function(reply) {
      if (reply && reply.ok) { creatingProfile = false; profilesError = "" }
      else profilesError = reply && reply.error ? reply.error.message : "Could not save profile."
    })
  }
  function loadProfile(id) {
    var profile = profileForId(id)
    if (!profile) return
    var contextId = contextForId(profile.selectedContextId) ? profile.selectedContextId : ""
    savePreferences({translator: profile.translator, sourceLanguage: profile.sourceLanguage,
      targetLanguage: profile.targetLanguage, selectedContextId: contextId}, function(reply) {
      if (reply && reply.ok) closeProfiles()
      else profilesError = reply && reply.error ? reply.error.message : "Could not load profile."
    })
  }
  function removeProfile(id) {
    if (profileDeleteConfirmationId !== id) { profileDeleteConfirmationId = id; return }
    var next = profiles.filter(function(profile) { return profile.id !== id })
    savePreferences({profiles: next}, function(reply) {
      if (reply && reply.ok) {
        profileDeleteConfirmationId = ""
        profileSelectedIndex = Math.min(profileSelectedIndex, 1 + next.length * 2)
        profilesError = ""
      }
      else profilesError = reply && reply.error ? reply.error.message : "Could not remove profile."
    })
  }
  function moveProfileSelection(direction) {
    if (!profilesOpen || creatingProfile) return
    var count = 2 + profiles.length * 2
    profileSelectedIndex = (profileSelectedIndex + direction + count) % count
    Qt.callLater(function() {
      if (profileSelectedIndex === 0) newProfileButton.forceActiveFocus()
      else if (profileSelectedIndex === 1) backProfileButton.forceActiveFocus()
      else {
        var profileIndex = Math.floor((profileSelectedIndex - 2) / 2)
        var item = profileRepeater.itemAt(profileIndex)
        if (!item) return
        if ((profileSelectedIndex - 2) % 2 === 0 && item.loadButton) item.loadButton.forceActiveFocus()
        else if (item.deleteButton) item.deleteButton.forceActiveFocus()
      }
    })
  }
  function selectedProfile() {
    return profileSelectedIndex >= 2 ? profiles[Math.floor((profileSelectedIndex - 2) / 2)] : null
  }
  function setTranslator(value) {
    if (!engineFor(value)) return
    translator = value
    if (!usesLlm() && contextsOpen) closeContexts()
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
    profilesOpen = false
    contextsOpen = false
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
  function moveMainSelection(direction) {
    if (mainControls.length === 0) return
    var initialIndex = mainSelectedIndex
    do {
      mainSelectedIndex = (mainSelectedIndex + direction + mainControls.length) % mainControls.length
      var control = mainControls[mainSelectedIndex]
      var unavailable = typeof control.available !== "undefined" && !control.available
    } while ((!control.visible || unavailable) && mainSelectedIndex !== initialIndex)
    focusMainSelection()
  }
  function focusMainSelection() {
    Qt.callLater(function() {
      if (!opened || setupOpen || profilesOpen || contextsOpen) return
      var control = mainControls[mainSelectedIndex]
      if (!control) return
      if (typeof control.focusControl === "function") control.focusControl()
      else control.forceActiveFocus()
    })
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
    if (setupOpen || profilesOpen || contextsOpen) return false
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
    if (commitDisplayedLanguages()) saveLanguages()
    message = ""
    var request = {
      text: sourceBox.text,
      translator: translator,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      selectedContextId: selectedContextId,
      openaiReasoningEffort: openaiReasoningEffort
    }
    run("translate", request, function(reply) {
      if (!translationRequestIsCurrent(request)) {
        message = "Translation discarded because the text or settings changed."
        messageError = false
        return
      }
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
  function open(payload) {
    setupOpen = false
    profilesOpen = false
    contextsOpen = false
    creatingProfile = false
    profileDeleteConfirmationId = ""
    profilesError = ""
    mainSelectedIndex = 3
    recordingAction = ""
    settingsError = ""
    resetConfirmationVisible = false
    opened = true
    focusMainSelection()
  }
  function close() { opened = false }
  function dismiss() { opened = false; if (shell) shell.hide((manifest && manifest.id) || "shaun.quick-translate") }
  function toggle() { opened ? dismiss() : open("{}") }

  Component.onCompleted: {
    mainControls = [fromPicker, switchButton, toPicker, sourceBox, contextButton, clearButton, copyButton, copyAllButton, translateButton]
    settingsControls = [translatorPicker, openaiKeyField, removeOpenaiKeyButton, barIconSwitch, hotkeysSwitch, copyRecorder, copyAllRecorder, switchRecorder, clearRecorder, translateRecorder, undoRecorder, restoreButton]
    run("engines.get", {}, function(reply) {
      if (reply && reply.ok) engines = reply.data || []
      var initialGeneration = preferenceGeneration
      run("preferences.get", {}, function(preferences) {
        if (preferences && preferences.ok && initialGeneration === preferenceGeneration) applyPreferences(preferences.data)
      })
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
      } else {
        reply = {ok: false, error: {code: "helper_failed", message: "The translator helper failed to run."}}
      }
      var callback = bridge.done
      bridge.done = null
      bridge.responseText = ""
      root.busy = false
      root.translating = false
      if (code !== 0) {
        root.message = reply.error.message
        root.messageError = true
      }
      if (callback) {
        callback(reply)
      }
      root.startNextOperation()
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
      enabled: root.opened && !root.profilesOpen && root.recordingAction === ""
      onActivated: root.setupOpen ? root.closeSetup() : root.openSetup()
    }
    Shortcut {
      sequence: "Ctrl+Shift+P"
      context: Qt.WindowShortcut
      enabled: root.opened && !root.contextsOpen && root.recordingAction === ""
      onActivated: root.profilesOpen ? root.closeProfiles() : root.openProfiles()
    }
    Shortcut {
      sequence: "Ctrl+Shift+X"
      context: Qt.WindowShortcut
      enabled: root.opened && !root.setupOpen && !root.profilesOpen && root.usesLlm() && !root.busy
      onActivated: root.contextsOpen ? root.closeContexts() : root.openContexts()
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
    Shortcut {
      sequence: "Ctrl+J"
      context: Qt.WindowShortcut
      enabled: root.contextsOpen && !root.contextEditorOpen && root.recordingAction === ""
      onActivated: root.moveContextSelection(1)
    }
    Shortcut {
      sequence: "Ctrl+K"
      context: Qt.WindowShortcut
      enabled: root.contextsOpen && !root.contextEditorOpen && root.recordingAction === ""
      onActivated: root.moveContextSelection(-1)
    }
    Shortcut {
      sequence: "Ctrl+J"
      context: Qt.WindowShortcut
      enabled: root.profilesOpen && !root.creatingProfile && root.recordingAction === ""
      onActivated: root.moveProfileSelection(1)
    }
    Shortcut {
      sequence: "Ctrl+K"
      context: Qt.WindowShortcut
      enabled: root.profilesOpen && !root.creatingProfile && root.recordingAction === ""
      onActivated: root.moveProfileSelection(-1)
    }
    Shortcut {
      sequence: "Ctrl+J"
      context: Qt.WindowShortcut
      enabled: root.opened && !root.setupOpen && !root.profilesOpen && !root.contextsOpen && root.recordingAction === ""
      onActivated: root.moveMainSelection(1)
    }
    Shortcut {
      sequence: "Ctrl+K"
      context: Qt.WindowShortcut
      enabled: root.opened && !root.setupOpen && !root.profilesOpen && !root.contextsOpen && root.recordingAction === ""
      onActivated: root.moveMainSelection(-1)
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
        if (event.key === Qt.Key_Escape && root.recordingAction === "") {
          if (root.profilesOpen) root.closeProfiles()
          else if (root.contextsOpen) root.closeContexts()
          else if (root.setupOpen) root.closeSetup()
          else root.dismiss()
          event.accepted = true
        }
        else if (root.profilesOpen && !root.creatingProfile && event.key === Qt.Key_Delete && root.selectedProfile()) {
          root.removeProfile(root.selectedProfile().id)
          event.accepted = true
        }
        else if (root.contextsOpen && !root.contextEditorOpen && event.key === Qt.Key_Delete && root.contextSelectedIndex >= 3) {
          var item = root.translationContexts[Math.floor((root.contextSelectedIndex - 3) / 3)]
          if (item) root.removeContext(item.id)
          event.accepted = true
        }
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
          Label { text: root.profilesOpen ? "Translation Profiles" : (root.contextsOpen ? "Translation Contexts" : (root.setupOpen ? "Quick Translate Setup" : "Quick Translate")); color: Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading; font.bold: true; Layout.fillWidth: true }
          Button {
            visible: !root.setupOpen && !root.profilesOpen && !root.contextsOpen
            text: root.showHotkeys ? "󰀻  Ctrl+Shift+P" : "󰀻"
            onClicked: root.openProfiles()
          }
          Button {
            visible: !root.profilesOpen && !root.contextsOpen
            text: root.setupOpen ? (root.showHotkeys ? "󰁍  Ctrl+?" : "󰁍") : (!root.showHotkeys ? "󰒓" : "󰒓  Ctrl+?")
            onClicked: root.setupOpen ? root.closeSetup() : root.openSetup()
          }
          Button {
            text: "×"
            onClicked: root.dismiss()
          }
        }
        RowLayout {
          visible: !root.setupOpen && !root.profilesOpen && !root.contextsOpen
          Layout.fillWidth: true
          ComboBox {
            id: fromPicker
            Layout.fillWidth: true
            editable: true
            model: root.sourceLanguages().map(function(x) { return x[1] })
            currentIndex: 0
            onEditTextChanged: {
              if (root.syncingLanguageSelectors) return
              var match = find(editText, Qt.MatchContains)
              if (match >= 0) currentIndex = match
            }
            onActivated: root.selectSourceLanguage(currentIndex)
            onAccepted: {
              var exact = root.exactLanguageIndex(root.sourceLanguages(), editText)
              root.selectSourceLanguage(exact >= 0 ? exact : currentIndex)
            }
            onActiveFocusChanged: {
              if (!activeFocus && !root.syncingLanguageSelectors && root.commitDisplayedLanguages()) root.saveLanguages()
            }
          }
          HotkeyButton { id: switchButton; actionText: "⇄"; hotkeyText: root.shortcut("switch"); available: !root.busy; onClicked: root.swap() }
          ComboBox {
            id: toPicker
            Layout.fillWidth: true
            editable: true
            model: root.targetLanguages().map(function(x) { return x[1] })
            currentIndex: 1
            onEditTextChanged: {
              if (root.syncingLanguageSelectors) return
              var match = find(editText, Qt.MatchContains)
              if (match >= 0) currentIndex = match
            }
            onActivated: root.selectTargetLanguage(currentIndex)
            onAccepted: {
              var exact = root.exactLanguageIndex(root.targetLanguages(), editText)
              root.selectTargetLanguage(exact >= 0 ? exact : currentIndex)
            }
            onActiveFocusChanged: {
              if (!activeFocus && !root.syncingLanguageSelectors && root.commitDisplayedLanguages()) root.saveLanguages()
            }
          }
        }
        Item { Layout.preferredHeight: Style.spacing.md }
        ScrollView {
          visible: !root.setupOpen && !root.profilesOpen && !root.contextsOpen
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
          visible: !root.setupOpen && !root.profilesOpen && !root.contextsOpen
          Layout.fillWidth: true
          Item { Layout.fillWidth: true }
          Label { visible: root.showHotkeys; text: "Ctrl+J/K select"; color: Color.menu.text; opacity: .65; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
          Label { text: root.activeTranslatorLabel(); color: Color.menu.text; opacity: .75; font.family: Style.font.menuFamily }
          Label { visible: root.usesLlm() && root.showHotkeys; text: "Ctrl+Shift+X"; color: Color.menu.text; opacity: .65; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
          HotkeyButton {
            id: contextButton
            visible: root.usesLlm()
            actionText: root.profileContextLabel(root.selectedContextId)
            compactActionText: root.profileContextLabel(root.selectedContextId)
            available: !root.busy
            onClicked: root.openContexts()
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
          visible: !root.setupOpen && !root.profilesOpen && !root.contextsOpen
          Layout.fillWidth: true
          Layout.preferredHeight: Math.max(120, Math.min(220, panel.height * .28))
          opacity: .55
          TextArea { id: outputBox; text: root.translating ? "Translating…" : root.translatedText; readOnly: true; placeholderText: root.showHotkeys ? root.shortcut("translate") + " to translate" : "Translation"; wrapMode: TextEdit.Wrap; selectByMouse: true; color: Color.menu.text; font.family: Style.font.menuFamily }
        }
        Label { visible: !root.setupOpen && !root.profilesOpen && !root.contextsOpen && root.message !== ""; text: root.message; color: root.messageError ? "#e06c75" : Color.menu.text; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        RowLayout {
          visible: !root.setupOpen && !root.profilesOpen && !root.contextsOpen
          Layout.fillWidth: true
          HotkeyButton { id: clearButton; actionText: "󰆴  Clear"; compactActionText: "󰆴"; hotkeyText: root.shortcut("clear"); reservedText: "󰆴  Clear  " + root.shortcut("clear"); available: !root.busy && (sourceBox.text.length > 0 || root.translatedText.length > 0); visuallyMuted: sourceBox.text.length === 0 && root.translatedText.length === 0; onClicked: root.clearAll() }
          HotkeyButton { id: copyButton; actionText: root.copiedAction === "translation" ? "󰆏  Copied ✓" : "󰆏  Copy translation"; compactActionText: root.copiedAction === "translation" ? "󰆏 ✓" : "󰆏"; hotkeyText: root.copiedAction === "translation" ? "" : root.shortcut("copy"); reservedText: "󰆏  Copy translation  " + root.shortcut("copy"); available: !root.busy && root.translatedText.length > 0; visuallyMuted: root.translatedText.length === 0; onClicked: root.copy(root.translatedText, "translation") }
          HotkeyButton { id: copyAllButton; actionText: root.copiedAction === "both" ? "󰆏 󰆏  Copied ✓" : "󰆏 󰆏  Copy both"; compactActionText: root.copiedAction === "both" ? "󰆏 󰆏 ✓" : "󰆏 󰆏"; hotkeyText: root.copiedAction === "both" ? "" : root.shortcut("copyAll"); reservedText: "󰆏 󰆏  Copy both  " + root.shortcut("copyAll"); available: !root.busy && root.translatedText.length > 0; visuallyMuted: root.translatedText.length === 0; onClicked: root.copy(sourceBox.text + "\n\n" + root.translatedText, "both") }
          Item { Layout.fillWidth: true }
          HotkeyButton { id: translateButton; actionText: root.translating ? "󰗊  Translating…" : "󰗊  Translate"; compactActionText: root.translating ? "󰗊 …" : "󰗊"; hotkeyText: root.translating ? "" : root.shortcut("translate"); reservedText: "󰗊  Translate  " + root.shortcut("translate"); available: root.canTranslate; visuallyMuted: sourceBox.text.trim().length === 0 || sourceBox.text.length > root.maxChars; onClicked: root.translate() }
        }
        ColumnLayout {
          visible: root.profilesOpen
          Layout.fillWidth: true
          spacing: Style.spacing.md
          Label {
            Layout.fillWidth: true
            text: "Save the current translator, languages, and translation context under a short name."
            color: Color.menu.text
            opacity: .80
            wrapMode: Text.WordWrap
            font.family: Style.font.menuFamily
          }
          Label {
            visible: root.showHotkeys && !root.creatingProfile
            text: "Ctrl+J/K select · Enter load/create · Delete remove"
            color: Color.menu.text
            opacity: .65
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
          RowLayout {
            Layout.fillWidth: true
            Label {
              text: root.profileSelectedIndex === 0 ? "󰁔" : ""
              color: Color.menu.text
              font.family: Style.font.menuFamily
              Layout.preferredWidth: Style.space(16)
            }
            Button {
              id: newProfileButton
              focus: root.profilesOpen && !root.creatingProfile && root.profileSelectedIndex === 0
              focusable: true
              text: "New from current settings"
              bordered: true
              enabled: !root.busy && root.profiles.length < 20
              onClicked: root.startNewProfile()
              onActiveFocusChanged: if (activeFocus) root.profileSelectedIndex = 0
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                  root.startNewProfile()
                  event.accepted = true
                }
              }
            }
            Item { Layout.fillWidth: true }
            Label {
              text: root.profileSelectedIndex === 1 ? "󰁔" : ""
              color: Color.menu.text
              font.family: Style.font.menuFamily
              Layout.preferredWidth: Style.space(16)
            }
            Button {
              id: backProfileButton
              focus: root.profilesOpen && !root.creatingProfile && root.profileSelectedIndex === 1
              focusable: true
              text: "Back"
              bordered: true
              onClicked: root.closeProfiles()
              onActiveFocusChanged: if (activeFocus) root.profileSelectedIndex = 1
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                  root.closeProfiles()
                  event.accepted = true
                }
              }
            }
          }
          ColumnLayout {
            visible: root.creatingProfile
            Layout.fillWidth: true
            spacing: Style.spacing.sm
            Label { text: "Profile name"; color: Color.menu.text; font.family: Style.font.menuFamily }
            RowLayout {
              Layout.fillWidth: true
              TextField {
                id: profileNameField
                Layout.fillWidth: true
                maximumLength: 64
                placeholderText: "e.g. Formal Japanese"
                onAccepted: root.saveProfile()
              }
              Button { text: "Save"; bordered: true; enabled: !root.busy; onClicked: root.saveProfile() }
              Button { text: "Cancel"; bordered: true; onClicked: { root.creatingProfile = false; root.profilesError = "" } }
            }
          }
          Label {
            visible: root.profiles.length === 0 && !root.creatingProfile
            text: "No profiles saved yet."
            color: Color.menu.text
            opacity: .75
            font.family: Style.font.menuFamily
          }
          Repeater {
            id: profileRepeater
            model: root.profiles
            delegate: RowLayout {
              required property var modelData
              required property int index
              property var loadButton: profileLoadButton
              property var deleteButton: profileDeleteButton
              Layout.fillWidth: true
              spacing: Style.spacing.sm
              Label {
                text: root.profileSelectedIndex === 2 + index * 2 || root.profileSelectedIndex === 3 + index * 2 ? "󰁔" : ""
                color: Color.menu.text
                font.family: Style.font.menuFamily
                Layout.preferredWidth: Style.space(16)
              }
              Button {
                id: profileLoadButton
                focus: root.profilesOpen && !root.creatingProfile && root.profileSelectedIndex === 2 + index * 2
                focusable: true
                Layout.fillWidth: true
                text: modelData.name + "  ·  " + modelData.translator + "  ·  "
                  + root.nameFor(modelData.sourceLanguage) + " → " + root.nameFor(modelData.targetLanguage)
                  + "  ·  " + root.profileContextLabel(modelData.selectedContextId)
                bordered: true
                enabled: !root.busy
                onClicked: root.loadProfile(modelData.id)
                onActiveFocusChanged: if (activeFocus) root.profileSelectedIndex = 2 + index * 2
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    root.loadProfile(modelData.id)
                    event.accepted = true
                  }
                }
              }
              Button {
                id: profileDeleteButton
                focus: root.profilesOpen && !root.creatingProfile && root.profileSelectedIndex === 3 + index * 2
                focusable: true
                text: root.profileDeleteConfirmationId === modelData.id ? "Confirm delete" : "Delete"
                bordered: true
                enabled: !root.busy
                onClicked: root.removeProfile(modelData.id)
                onActiveFocusChanged: if (activeFocus) root.profileSelectedIndex = 3 + index * 2
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    root.removeProfile(modelData.id)
                    event.accepted = true
                  }
                }
              }
            }
          }
          Label {
            visible: root.profilesError !== ""
            Layout.fillWidth: true
            text: root.profilesError
            color: "#e06c75"
            wrapMode: Text.WordWrap
          }
        }
        ColumnLayout {
          visible: root.contextsOpen
          Layout.fillWidth: true
          spacing: Style.spacing.md
          Label {
            Layout.fillWidth: true
            text: "Contexts guide Gemma locally and are sent to OpenAI when it is selected."
            color: Color.menu.text
            opacity: .80
            wrapMode: Text.WordWrap
            font.family: Style.font.menuFamily
          }
          Label {
            visible: root.showHotkeys && !root.contextEditorOpen
            text: "Ctrl+J/K select · Enter select/edit · Delete remove"
            color: Color.menu.text
            opacity: .65
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
          RowLayout {
            visible: !root.contextEditorOpen
            Layout.fillWidth: true
            Label { text: root.contextSelectedIndex === 0 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Button {
              id: newContextButton
              focus: root.contextsOpen && !root.contextEditorOpen && root.contextSelectedIndex === 0
              focusable: true
              text: "New context"
              bordered: true
              enabled: !root.busy && root.translationContexts.length < 20
              onClicked: root.startNewContext()
              onActiveFocusChanged: if (activeFocus) root.contextSelectedIndex = 0
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { root.startNewContext(); event.accepted = true }
              }
            }
            Item { Layout.fillWidth: true }
            Label { text: root.contextSelectedIndex === 1 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Button {
              id: backContextButton
              focus: root.contextsOpen && !root.contextEditorOpen && root.contextSelectedIndex === 1
              focusable: true
              text: "Back"
              bordered: true
              onClicked: root.closeContexts()
              onActiveFocusChanged: if (activeFocus) root.contextSelectedIndex = 1
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { root.closeContexts(); event.accepted = true }
              }
            }
          }
          RowLayout {
            visible: !root.contextEditorOpen
            Layout.fillWidth: true
            Label { text: root.contextSelectedIndex === 2 ? "󰁔" : ""; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(16) }
            Button {
              id: noContextButton
              focus: root.contextsOpen && !root.contextEditorOpen && root.contextSelectedIndex === 2
              focusable: true
              Layout.fillWidth: true
              text: "No context"
              bordered: true
              enabled: !root.busy
              onClicked: root.selectContext("")
              onActiveFocusChanged: if (activeFocus) root.contextSelectedIndex = 2
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { root.selectContext(""); event.accepted = true }
              }
            }
          }
          ColumnLayout {
            visible: root.contextEditorOpen
            Layout.fillWidth: true
            spacing: Style.spacing.sm
            Label { text: root.editingContextId === "" ? "New context" : "Edit context"; color: Color.menu.text; font.family: Style.font.menuFamily; font.bold: true }
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
              Layout.preferredHeight: 120
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
              Button { text: "Save context"; bordered: true; enabled: !root.busy; onClicked: root.saveContext() }
              Button { text: "Cancel"; bordered: true; onClicked: { root.contextEditorOpen = false; root.contextsError = ""; Qt.callLater(function() { root.moveContextSelection(0) }) } }
            }
          }
          Label {
            visible: root.translationContexts.length === 0 && !root.contextEditorOpen
            text: "No contexts saved yet."
            color: Color.menu.text
            opacity: .75
            font.family: Style.font.menuFamily
          }
          Repeater {
            id: contextRepeater
            model: root.contextEditorOpen ? [] : root.translationContexts
            delegate: RowLayout {
              required property var modelData
              required property int index
              property var selectButton: savedContextSelectButton
              property var editButton: savedContextEditButton
              property var deleteButton: savedContextDeleteButton
              Layout.fillWidth: true
              spacing: Style.spacing.sm
              Label {
                text: root.contextSelectedIndex >= 3 + index * 3 && root.contextSelectedIndex <= 5 + index * 3 ? "󰁔" : ""
                color: Color.menu.text
                font.family: Style.font.menuFamily
                Layout.preferredWidth: Style.space(16)
              }
              Button {
                id: savedContextSelectButton
                focus: root.contextsOpen && !root.contextEditorOpen && root.contextSelectedIndex === 3 + index * 3
                focusable: true
                Layout.fillWidth: true
                text: modelData.name
                bordered: true
                enabled: !root.busy
                onClicked: root.selectContext(modelData.id)
                onActiveFocusChanged: if (activeFocus) root.contextSelectedIndex = 3 + index * 3
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { root.selectContext(modelData.id); event.accepted = true }
                }
              }
              Button {
                id: savedContextEditButton
                focus: root.contextsOpen && !root.contextEditorOpen && root.contextSelectedIndex === 4 + index * 3
                focusable: true
                text: "Edit"
                bordered: true
                enabled: !root.busy
                onClicked: root.editContext(modelData.id)
                onActiveFocusChanged: if (activeFocus) root.contextSelectedIndex = 4 + index * 3
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { root.editContext(modelData.id); event.accepted = true }
                }
              }
              Button {
                id: savedContextDeleteButton
                focus: root.contextsOpen && !root.contextEditorOpen && root.contextSelectedIndex === 5 + index * 3
                focusable: true
                text: root.contextDeleteConfirmationId === modelData.id ? "Confirm delete" : "Delete"
                bordered: true
                enabled: !root.busy
                onClicked: root.removeContext(modelData.id)
                onActiveFocusChanged: if (activeFocus) root.contextSelectedIndex = 5 + index * 3
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { root.removeContext(modelData.id); event.accepted = true }
                }
              }
            }
          }
          Label {
            visible: root.contextsError !== ""
            Layout.fillWidth: true
            text: root.contextsError
            color: "#e06c75"
            wrapMode: Text.WordWrap
          }
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
