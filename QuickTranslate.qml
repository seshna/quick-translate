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
  property string translationPreview: ""
  property string translationStage: "translating"
  property bool translationReviewEnabled: false
  property int translationGeneratedCharacters: 0
  property var reviewRetryRequest: null
  readonly property bool canRetryReview: !busy && reviewRetryRequest !== null && translationRequestIsCurrent(reviewRetryRequest)
  property double translationStartedAt: 0
  property int translationElapsedSeconds: 0
  readonly property string translationStatus: (translationStage === "reviewing" ? "Reviewing translation… " : "Translating… ")
    + Math.floor(translationElapsedSeconds / 60) + ":" + (translationElapsedSeconds % 60).toString().padStart(2, "0")
    + (translationGeneratedCharacters > 0 ? " · " + translationGeneratedCharacters.toLocaleString()
      + (translationStage === "reviewing" ? " review characters generated" : " characters generated")
      : " · Waiting for the first text…")
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
  property bool reviewTranslation: false
  property bool openaiApiKeyConfigured: false
  property string openaiReasoningEffort: "minimal"
  property string activeProfileId: ""
  property var profiles: []
  property bool profilesOpen: false
  property bool creatingProfile: false
  property string editingProfileId: ""
  property string profileDraftTranslator: ""
  property string profileDraftSource: ""
  property string profileDraftTarget: ""
  readonly property bool editingProfile: editingProfileId !== ""
  readonly property bool profileFormOpen: creatingProfile || editingProfile
  property int profileSelectedIndex: 0
  property string profileDeleteConfirmationId: ""
  property string profilesError: ""
  readonly property var displayProfiles: groupedProfiles()
  readonly property var shownProfile: profileSelectedIndex < displayProfiles.length ? displayProfiles[profileSelectedIndex] : null
  readonly property int maxProfileInstructionChars: 11000
  readonly property int profileInstructionLength: Array.from(profileInstructionField.text).length
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

  component ProfileDetailRow: RowLayout {
    property string label: ""
    property string value: ""
    property string note: ""
    property int maxLines: 1000
    Layout.fillWidth: true
    spacing: Style.spacing.md
    Label {
      text: parent.label
      color: Color.menu.text
      opacity: .68
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
      Layout.preferredWidth: Style.space(96)
      Layout.alignment: Qt.AlignTop
    }
    Label {
      text: parent.value
      color: Color.menu.text
      wrapMode: Text.Wrap
      maximumLineCount: parent.maxLines
      elide: Text.ElideRight
      font.family: Style.font.menuFamily
      Layout.fillWidth: true
    }
    Label {
      visible: parent.note !== ""
      text: parent.note
      color: Color.menu.text
      opacity: parent.note === "changes" ? 1 : .68
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
      font.bold: parent.note === "changes"
      horizontalAlignment: Text.AlignRight
      Layout.preferredWidth: Style.space(72)
      Layout.alignment: Qt.AlignTop
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
    if (translator === "claude") return "Claude · Haiku"
    var engine = engineFor(translator)
    return engine ? engine.name : "Google"
  }
  function usesLlm() { return translatorUsesLlm(translator) }
  function newProfileId() { return "profile-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8) }
  function profileForId(id) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].id === id) return profiles[i]
    return null
  }
  function profilePairLabel(profile) { return nameFor(profile.sourceLanguage) + " → " + nameFor(profile.targetLanguage) }
  // Language pairs sort alphabetically; profiles keep their saved order within a pair.
  function groupedProfiles() {
    var entries = profiles.map(function(profile, index) { return {profile: profile, index: index, pair: profilePairLabel(profile)} })
    entries.sort(function(a, b) { return a.pair.localeCompare(b.pair) || a.index - b.index })
    return entries.map(function(entry) { return entry.profile })
  }
  function profileDisplayIndex(id) {
    for (var i = 0; i < displayProfiles.length; i++) if (displayProfiles[i].id === id) return i
    return displayProfiles.length
  }
  function profileStartsGroup(index) {
    return index === 0 || profilePairLabel(displayProfiles[index - 1]) !== profilePairLabel(displayProfiles[index])
  }
  function profilePairCount(profile) {
    var pair = profilePairLabel(profile)
    return profiles.filter(function(item) { return profilePairLabel(item) === pair }).length
  }
  function activeProfile() { return profileForId(activeProfileId) }
  function activeProfileInstruction() {
    var profile = activeProfile()
    return profile ? profile.instruction : ""
  }
  function activeProfileLabel() {
    var profile = activeProfile()
    if (!profile) return "No profile"
    return profile.name.length > 28 ? profile.name.slice(0, 27) + "…" : profile.name
  }
  function translatorUsesLlm(id) { return id === "ollama" || id === "openai" || id === "claude" }
  function reasoningEffortLabel(value) { return value.charAt(0).toUpperCase() + value.slice(1) }
  function openaiReasoningEffortIndex() { return openaiReasoningEfforts.indexOf(openaiReasoningEffort) }
  function translatorOptions() {
    var groups = [
      {title: "No key / public web", ids: ["google", "apertium", "bing", "reverso"]},
      {title: "Local model", ids: ["ollama"]},
      {title: "Claude Code sign-in", ids: ["claude"]},
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
  function pairsForEngine(engineId) { var engine = engineFor(engineId || translator); return engine && engine.pairs ? engine.pairs : [] }
  // An empty pairs list means either the engine has no pair restriction of
  // its own (e.g. Google, Bing) or engines/languages haven't loaded yet —
  // in both cases fall back to the full language catalogue rather than
  // showing no options.
  function sourceCodes(engineId) {
    var pairs = pairsForEngine(engineId)
    if (pairs.length === 0) return languages.map(function(item) { return item[0] })
    var result = []
    for (var i = 0; i < pairs.length; i++) if (result.indexOf(pairs[i][0]) < 0) result.push(pairs[i][0])
    return result
  }
  function targetCodes(source, engineId) {
    var pairs = pairsForEngine(engineId)
    if (pairs.length === 0) return languages.map(function(item) { return item[0] })
    var result = []
    for (var i = 0; i < pairs.length; i++) if (pairs[i][0] === source && result.indexOf(pairs[i][1]) < 0) result.push(pairs[i][1])
    if (sourceCodes(engineId).indexOf(source) >= 0 && result.indexOf(source) < 0) result.push(source)
    return result
  }
  function sourceLanguages(engineId) { var codes = sourceCodes(engineId); return languages.filter(function(item) { return codes.indexOf(item[0]) >= 0 }) }
  function targetLanguages(source, engineId) { var codes = targetCodes(source === undefined ? sourceLanguage : source, engineId); return languages.filter(function(item) { return codes.indexOf(item[0]) >= 0 }) }
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
    translating = operation === "translate" || operation === "review"
    if (translating) {
      translationPreview = ""
      translationStage = operation === "review" ? "reviewing" : "translating"
      translationReviewEnabled = operation === "review" || (params.reviewTranslation === true
        && translatorUsesLlm(params.translator) && params.sourceLanguage !== params.targetLanguage)
      translationGeneratedCharacters = 0
      if (translationReviewEnabled) translatedText = ""
      translationStartedAt = Date.now()
      translationElapsedSeconds = 0
    }
    bridge.responseText = ""
    bridge.stoppedReason = ""
    bridge.translationRequest = translating ? params : null
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
        && activeProfileId === request.activeProfileId
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
    reviewTranslation = data.reviewTranslation === true
    openaiApiKeyConfigured = data.openaiApiKeyConfigured === true
    openaiReasoningEffort = openaiReasoningEfforts.indexOf(data.openaiReasoningEffort) >= 0 ? data.openaiReasoningEffort : "minimal"
    profiles = Array.isArray(data.profiles) ? data.profiles : []
    activeProfileId = profileForId(data.activeProfileId) ? data.activeProfileId : ""
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
    var fields = ["sourceLanguage", "targetLanguage", "translator", "shortcuts", "showBarIcon", "showHotkeys", "reviewTranslation", "openaiReasoningEffort", "activeProfileId", "profiles"]
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
      if (reply && reply.ok) {
        if (reply.data) applyPreferenceResult(params, reply.data, responseRevisions)
        // A queued settings save must not erase the explanation for a failed review.
        if (reviewRetryRequest === null) showReply(reply)
      } else showReply(reply)
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
      reviewTranslation: reviewTranslation,
      openaiApiKeyConfigured: openaiApiKeyConfigured,
      openaiReasoningEffort: openaiReasoningEffort,
      activeProfileId: activeProfileId,
      profiles: profiles
    }
    var fields = ["sourceLanguage", "targetLanguage", "translator", "shortcuts", "showBarIcon", "showHotkeys", "reviewTranslation", "openaiReasoningEffort", "activeProfileId", "profiles"]
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
  function openProfiles() {
    setupOpen = false
    profilesOpen = true
    creatingProfile = false
    editingProfileId = ""
    profileSelectedIndex = 0
    profileDeleteConfirmationId = ""
    profilesError = ""
    focusProfileSelection()
  }
  function closeProfiles() {
    profilesOpen = false
    creatingProfile = false
    editingProfileId = ""
    profileSelectedIndex = 0
    profileDeleteConfirmationId = ""
    profilesError = ""
    Qt.callLater(function() { sourceBox.forceActiveFocus() })
  }
  function startNewProfile() {
    if (busy) return
    if (profiles.length >= 20) { profilesError = "Keep at most 20 profiles."; return }
    creatingProfile = true
    profileSelectedIndex = profiles.length
    openProfileForm("", translator, sourceLanguage, targetLanguage, activeProfileInstruction())
  }
  function openProfileForm(name, engine, source, target, instruction) {
    profileDeleteConfirmationId = ""
    profilesError = ""
    profileDraftTranslator = engine
    profileDraftSource = source
    profileDraftTarget = target
    profileNameField.text = name
    profileInstructionField.text = instruction
    syncProfileDraftPickers()
    Qt.callLater(function() { profileNameField.forceActiveFocus() })
  }
  function cancelProfileForm() {
    creatingProfile = false
    editingProfileId = ""
    profilesError = ""
    focusProfileSelection()
  }
  function profileNameTaken(name, exceptId) {
    var normalized = name.toLowerCase()
    return profiles.some(function(profile) { return profile.id !== exceptId && profile.name.toLowerCase() === normalized })
  }
  function startEditProfile() {
    var profile = shownProfile
    if (busy || !profile) return
    editingProfileId = profile.id
    openProfileForm(profile.name, profile.translator, profile.sourceLanguage, profile.targetLanguage, profile.instruction)
  }
  function profileDraftUsesLlm() { return translatorUsesLlm(profileDraftTranslator) }
  function languageDropdownOptions(items) { return items.map(function(item) { return {value: item[0], label: item[1]} }) }
  function profileTranslatorOptions() {
    return translatorOptions().filter(function(option) { return !option.section })
      .map(function(option) { return {value: option.id, label: option.label} })
  }
  function setProfileDraft(field, value) {
    if (field === "translator") profileDraftTranslator = value
    else if (field === "source") profileDraftSource = value
    else profileDraftTarget = value
    var sources = sourceCodes(profileDraftTranslator)
    if (sources.length > 0 && sources.indexOf(profileDraftSource) < 0) profileDraftSource = sources[0]
    var targets = targetCodes(profileDraftSource, profileDraftTranslator)
    if (targets.length > 0 && targets.indexOf(profileDraftTarget) < 0) profileDraftTarget = targets[0]
    syncProfileDraftPickers()
  }
  // The dropdowns overwrite a value binding on selection, so a change to one
  // draft field (a translator with fewer pairs) has to be pushed to the others.
  function syncProfileDraftPickers() {
    profileTranslatorDropdown.value = profileDraftTranslator
    profileSourceDropdown.value = profileDraftSource
    profileTargetDropdown.value = profileDraftTarget
  }
  function saveProfile() {
    var id = editingProfile ? editingProfileId : newProfileId()
    var name = profileNameField.text.trim()
    if (name === "") { profilesError = "Give the profile a short name."; return }
    if (profileNameTaken(name, id)) { profilesError = "Another profile already uses that name."; return }
    if (profileInstructionLength > maxProfileInstructionChars) { profilesError = "Shorten the instructions to 11,000 characters before saving."; return }
    var saved = {id: id, name: name, translator: profileDraftTranslator, sourceLanguage: profileDraftSource,
      targetLanguage: profileDraftTarget, instruction: profileInstructionField.text.trim()}
    var next = editingProfile
      ? profiles.map(function(profile) { return profile.id === id ? saved : profile })
      : profiles.concat([saved])
    savePreferences({profiles: next}, function(reply) {
      if (reply && reply.ok) {
        creatingProfile = false
        editingProfileId = ""
        profileSelectedIndex = profileDisplayIndex(id)
        profilesError = ""
        focusProfileSelection()
      }
      else profilesError = reply && reply.error ? reply.error.message : "Could not save profile."
    })
  }
  function loadProfile(id) {
    if (busy) return
    var profile = profileForId(id)
    if (!profile) return
    savePreferences({translator: profile.translator, sourceLanguage: profile.sourceLanguage,
      targetLanguage: profile.targetLanguage, activeProfileId: id}, function(reply) {
      if (reply && reply.ok) closeProfiles()
      else profilesError = reply && reply.error ? reply.error.message : "Could not load profile."
    })
  }
  function removeProfile(id) {
    if (busy) return
    if (profileDeleteConfirmationId !== id) { profileDeleteConfirmationId = id; return }
    var next = profiles.filter(function(profile) { return profile.id !== id })
    savePreferences({profiles: next, activeProfileId: activeProfileId === id ? "" : activeProfileId}, function(reply) {
      if (reply && reply.ok) {
        profileDeleteConfirmationId = ""
        profileSelectedIndex = Math.min(profileSelectedIndex, next.length)
        profilesError = ""
        focusProfileSelection()
      }
      else profilesError = reply && reply.error ? reply.error.message : "Could not remove profile."
    })
  }
  function clearActiveProfile() {
    if (busy) return
    savePreferences({activeProfileId: ""}, function(reply) {
      if (!reply || !reply.ok) profilesError = reply && reply.error ? reply.error.message : "Could not update the active profile."
    })
  }
  function setProfileSelection(index) {
    if (profileFormOpen) return
    if (index !== profileSelectedIndex) {
      profileDeleteConfirmationId = ""
      profilesError = ""
    }
    profileSelectedIndex = index
    ensureProfileVisible()
  }
  function ensureProfileVisible() {
    var item = profileRepeater.itemAt(profileSelectedIndex)
    if (!item) return
    if (item.y < profileListFlickable.contentY) profileListFlickable.contentY = item.y
    else if (item.y + item.height > profileListFlickable.contentY + profileListFlickable.height)
      profileListFlickable.contentY = item.y + item.height - profileListFlickable.height
  }
  function focusProfileSelection() {
    Qt.callLater(function() {
      var item = profileRepeater.itemAt(profileSelectedIndex)
      if (item) item.rowButton.forceActiveFocus()
      else newProfileButton.forceActiveFocus()
      ensureProfileVisible()
    })
  }
  function moveProfileSelection(direction) {
    if (!profilesOpen || profileFormOpen) return
    var count = profiles.length + 1
    setProfileSelection((profileSelectedIndex + direction + count) % count)
    focusProfileSelection()
  }
  function selectedProfile() { return shownProfile }
  function profileChangeNote(field) {
    var profile = shownProfile
    if (!profile) return ""
    var changed = false
    if (field === "translator") changed = profile.translator !== translator
    else if (field === "languages") changed = profile.sourceLanguage !== sourceLanguage || profile.targetLanguage !== targetLanguage
    else changed = profile.instruction !== activeProfileInstruction()
    return changed ? "changes" : "same"
  }
  function activateProfilePrimary() {
    if (profileFormOpen) saveProfile()
    else if (shownProfile) loadProfile(shownProfile.id)
    else startNewProfile()
  }
  function setTranslator(value) {
    if (!engineFor(value)) return
    translator = value
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
      if (!opened || setupOpen || profilesOpen) return
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
    if (setupOpen || profilesOpen) return false
    if (action === "switch") return !busy
    if (action === "translate") return translating || canTranslate
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
    if (translating) { stopTranslation("cancelled"); return }
    if (!canTranslate) return
    if (commitDisplayedLanguages()) saveLanguages()
    message = ""
    reviewRetryRequest = null
    var request = {
      text: sourceBox.text,
      translator: translator,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      activeProfileId: activeProfileId,
      customContext: activeProfileInstruction(),
      reviewTranslation: reviewTranslation,
      openaiReasoningEffort: openaiReasoningEffort
    }
    run("translate", request, function(reply) {
      finishTranslation(request, reply)
    })
  }
  function finishTranslation(request, reply) {
      if (!translationRequestIsCurrent(request)) {
        message = "Translation discarded because the text or settings changed."
        messageError = false
        return
      }
      if (translationReviewEnabled && reply && reply.ok
          && (!reply.data || reply.data.reviewed !== true || typeof reply.data.translation !== "string" || reply.data.translation.trim() === "")) {
        reply = {ok: false, error: {code: "review_failed",
          message: "The helper did not return a validated review. Retry review without translating again."}}
      }
      if (reply && reply.ok) {
        if (showReply(reply)) {
          translatedText = String(reply.data.translation || "")
          if (reply.data.reviewed === true)
            message = reply.data.reviewChanged === true ? "Reviewed: accuracy corrections applied." : "Reviewed: no corrections needed."
        }
        reviewRetryRequest = null
      } else if (translationReviewEnabled) {
        translatedText = ""
        if (reply && reply.reviewRequest) reviewRetryRequest = Object.assign({}, request, reply.reviewRequest)
        var detail = reply && reply.error ? reply.error.message : "The helper did not return a valid response."
        if (reviewRetryRequest !== null) {
          message = reply && reply.error && reply.error.code === "review_failed" ? detail
            : "Translation succeeded, but review did not complete. " + detail + " Draft retained. Retry review without translating again."
        } else message = detail
        messageError = !(reply && reply.error && reply.error.code === "cancelled")
      } else if (reply && !reply.ok && reply.error && (reply.error.code === "cancelled" || reply.error.code === "timeout")) {
        if (translationPreview.length > 0) translatedText = translationPreview
        message = reply.error.message + (translationPreview.length > 0 ? " Partial translation shown." : "")
        messageError = reply.error.code !== "cancelled"
      } else showReply(reply)
  }
  function retryReview() {
    if (!canRetryReview) return
    var request = Object.assign({}, reviewRetryRequest)
    message = ""
    run("review", request, function(reply) { finishTranslation(request, reply) })
  }
  function stopTranslation(reason) {
    if (!translating || bridge.stoppedReason !== "") return
    bridge.stoppedReason = reason
    bridge.running = false
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
    reviewRetryRequest = null
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
    creatingProfile = false
    editingProfileId = ""
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
    mainControls = [fromPicker, switchButton, toPicker, sourceBox, activeProfileButton, clearButton, copyButton, copyAllButton, translateButton]
    settingsControls = [translatorPicker, openaiKeyField, removeOpenaiKeyButton, barIconSwitch, hotkeysSwitch, copyRecorder, copyAllRecorder, switchRecorder, clearRecorder, translateRecorder, undoRecorder, restoreButton, reviewTranslationSwitch]
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

  Timer {
    interval: 1000
    repeat: true
    running: root.translating
    onTriggered: root.translationElapsedSeconds = Math.floor((Date.now() - root.translationStartedAt) / 1000)
  }
  Timer {
    id: translationDeadline
    interval: root.translationStage === "reviewing" ? 900000 : 300000
    running: root.translating && bridge.translationRequest !== null && bridge.translationRequest.translator === "ollama"
    onTriggered: root.stopTranslation("timeout")
  }

  Process {
    id: bridge
    property string payload: ""
    property var done: null
    property string responseText: ""
    property string stoppedReason: ""
    property var translationRequest: null
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    stdout: SplitParser {
      onRead: function(data) {
        var event = null
        try { event = JSON.parse(data) } catch (e) { return }
        if (event && (event.event === "progress" || event.event === "draft" || event.event === "stage")) {
          if (root.translating && bridge.stoppedReason === "" && bridge.translationRequest
              && root.translationRequestIsCurrent(bridge.translationRequest)) {
            if (event.event === "draft" && root.translationReviewEnabled && typeof event.draft === "string") {
              root.reviewRetryRequest = Object.assign({}, bridge.translationRequest, {draft: event.draft, reviewTranslation: true})
            } else if (event.event === "stage" && event.stage === "reviewing") {
              root.translationStage = "reviewing"
              root.translationGeneratedCharacters = 0
              if (bridge.translationRequest.translator === "ollama") translationDeadline.restart()
            } else if (event.event === "progress") {
              if (typeof event.characters === "number") root.translationGeneratedCharacters = event.characters
              else if (typeof event.delta === "string") {
                root.translationGeneratedCharacters += Array.from(event.delta).length
                if (!root.translationReviewEnabled) root.translationPreview += event.delta
              }
            }
          }
        } else bridge.responseText = data
      }
    }
    onExited: function(code) {
      var reply = null
      if (bridge.stoppedReason !== "") {
        reply = {ok: false, error: {code: bridge.stoppedReason,
          message: bridge.stoppedReason === "cancelled" ? "Translation cancelled."
            : root.translationStage === "reviewing" ? "Review timed out after 15 minutes." : "Translation timed out after five minutes."}}
      } else if (code === 0) {
        try { reply = JSON.parse(bridge.responseText.trim()) } catch (e) { reply = null }
      } else {
        reply = {ok: false, error: {code: "helper_failed", message: "The translator helper failed to run."}}
      }
      var callback = bridge.done
      bridge.done = null
      bridge.responseText = ""
      root.busy = false
      root.translating = false
      if (code !== 0 && bridge.stoppedReason === "") {
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
      enabled: root.opened && root.recordingAction === ""
      onActivated: root.profilesOpen ? root.closeProfiles() : root.openProfiles()
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
      sequence: "E"
      context: Qt.WindowShortcut
      enabled: root.opened && root.profilesOpen && !root.profileFormOpen && !root.busy
        && root.shownProfile !== null && root.recordingAction === ""
      onActivated: root.startEditProfile()
    }
    Shortcut {
      sequence: "Ctrl+J"
      context: Qt.WindowShortcut
      enabled: root.profilesOpen && !root.profileFormOpen && root.recordingAction === ""
      onActivated: root.moveProfileSelection(1)
    }
    Shortcut {
      sequence: "Ctrl+K"
      context: Qt.WindowShortcut
      enabled: root.profilesOpen && !root.profileFormOpen && root.recordingAction === ""
      onActivated: root.moveProfileSelection(-1)
    }
    Shortcut {
      sequence: "Ctrl+J"
      context: Qt.WindowShortcut
      enabled: root.opened && !root.setupOpen && !root.profilesOpen && root.recordingAction === ""
      onActivated: root.moveMainSelection(1)
    }
    Shortcut {
      sequence: "Ctrl+K"
      context: Qt.WindowShortcut
      enabled: root.opened && !root.setupOpen && !root.profilesOpen && root.recordingAction === ""
      onActivated: root.moveMainSelection(-1)
    }
    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    BorderSurface {
      id: card
      width: Math.min(root.profileFormOpen ? 1100 : 900, panel.width - Style.gapsOut * 2)
      height: Math.min(root.profileFormOpen ? 960 : 690, panel.height - Style.gapsOut * 2, content.implicitHeight + contentTopInset + contentBottomInset)
      anchors.centerIn: parent
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      padding: Style.spacing.panelPadding
      MouseArea { anchors.fill: parent; onClicked: {} }
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape && root.recordingAction === "") {
          if (root.profilesOpen && root.profileFormOpen) root.cancelProfileForm()
          else if (root.profilesOpen && root.profileDeleteConfirmationId !== "") root.profileDeleteConfirmationId = ""
          else if (root.profilesOpen) root.closeProfiles()
          else if (root.setupOpen) root.closeSetup()
          else root.dismiss()
          event.accepted = true
        }
        else if (root.profilesOpen && !root.profileFormOpen && event.key === Qt.Key_Delete && root.selectedProfile()) {
          root.removeProfile(root.selectedProfile().id)
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
          Label { text: root.profilesOpen ? "Translation Profiles" : (root.setupOpen ? "Quick Translate Setup" : "Quick Translate"); color: Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading; font.bold: true; Layout.fillWidth: true }
          Label {
            visible: root.profilesOpen
            text: root.profiles.length + " of 20"
            color: Color.menu.text
            opacity: .68
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
          Button {
            visible: !root.setupOpen && !root.profilesOpen
            text: root.showHotkeys ? "󰀻  Ctrl+Shift+P" : "󰀻"
            onClicked: root.openProfiles()
          }
          Button {
            visible: !root.profilesOpen
            text: root.setupOpen ? (root.showHotkeys ? "󰁍  Ctrl+?" : "󰁍") : (!root.showHotkeys ? "󰒓" : "󰒓  Ctrl+?")
            onClicked: root.setupOpen ? root.closeSetup() : root.openSetup()
          }
          Button {
            text: "×"
            onClicked: root.dismiss()
          }
        }
        RowLayout {
          visible: !root.setupOpen && !root.profilesOpen
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
          visible: !root.setupOpen && !root.profilesOpen
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
          visible: !root.setupOpen && !root.profilesOpen
          Layout.fillWidth: true
          Item { Layout.fillWidth: true }
          Label { visible: root.showHotkeys; text: "Ctrl+J/K select"; color: Color.menu.text; opacity: .65; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
          Label { text: root.activeTranslatorLabel(); color: Color.menu.text; opacity: .75; font.family: Style.font.menuFamily }
          HotkeyButton {
            id: activeProfileButton
            visible: root.usesLlm()
            actionText: root.activeProfileLabel()
            compactActionText: root.activeProfileLabel()
            available: !root.busy
            onClicked: root.openProfiles()
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
          visible: !root.setupOpen && !root.profilesOpen
          Layout.fillWidth: true
          Layout.preferredHeight: Math.max(120, Math.min(220, panel.height * .28))
          opacity: .55
          TextArea { id: outputBox; text: root.translating ? (root.translationReviewEnabled ? root.translationStatus : (root.translationPreview || root.translationStatus)) : root.translatedText; textFormat: TextEdit.PlainText; readOnly: true; placeholderText: root.showHotkeys ? root.shortcut("translate") + " to translate" : "Translation"; wrapMode: TextEdit.Wrap; selectByMouse: true; color: Color.menu.text; font.family: Style.font.menuFamily }
        }
        Label {
          visible: root.translating && !root.setupOpen && !root.profilesOpen
          text: root.translationStatus + " · " + root.shortcut("translate") + " to cancel"
          color: Color.menu.text
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
        }
        Label { visible: !root.setupOpen && !root.profilesOpen && root.message !== ""; text: root.message; color: root.messageError ? "#e06c75" : Color.menu.text; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        Button {
          id: retryReviewButton
          visible: root.reviewRetryRequest !== null && !root.translating && !root.setupOpen && !root.profilesOpen
          text: "Retry review"
          bordered: true
          focusable: true
          enabled: root.canRetryReview
          onClicked: root.retryReview()
        }
        RowLayout {
          visible: !root.setupOpen && !root.profilesOpen
          Layout.fillWidth: true
          HotkeyButton { id: clearButton; actionText: "󰆴  Clear"; compactActionText: "󰆴"; hotkeyText: root.shortcut("clear"); reservedText: "󰆴  Clear  " + root.shortcut("clear"); available: !root.busy && (sourceBox.text.length > 0 || root.translatedText.length > 0); visuallyMuted: sourceBox.text.length === 0 && root.translatedText.length === 0; onClicked: root.clearAll() }
          HotkeyButton { id: copyButton; actionText: root.copiedAction === "translation" ? "󰆏  Copied ✓" : "󰆏  Copy translation"; compactActionText: root.copiedAction === "translation" ? "󰆏 ✓" : "󰆏"; hotkeyText: root.copiedAction === "translation" ? "" : root.shortcut("copy"); reservedText: "󰆏  Copy translation  " + root.shortcut("copy"); available: !root.busy && root.translatedText.length > 0; visuallyMuted: root.translatedText.length === 0; onClicked: root.copy(root.translatedText, "translation") }
          HotkeyButton { id: copyAllButton; actionText: root.copiedAction === "both" ? "󰆏 󰆏  Copied ✓" : "󰆏 󰆏  Copy both"; compactActionText: root.copiedAction === "both" ? "󰆏 󰆏 ✓" : "󰆏 󰆏"; hotkeyText: root.copiedAction === "both" ? "" : root.shortcut("copyAll"); reservedText: "󰆏 󰆏  Copy both  " + root.shortcut("copyAll"); available: !root.busy && root.translatedText.length > 0; visuallyMuted: root.translatedText.length === 0; onClicked: root.copy(sourceBox.text + "\n\n" + root.translatedText, "both") }
          Item { Layout.fillWidth: true }
          HotkeyButton { id: translateButton; actionText: root.translating ? "Cancel" : "󰗊  Translate"; compactActionText: root.translating ? "Cancel" : "󰗊"; hotkeyText: root.shortcut("translate"); reservedText: "󰗊  Translate  " + root.shortcut("translate"); available: root.translating || root.canTranslate; visuallyMuted: !root.translating && (sourceBox.text.trim().length === 0 || sourceBox.text.length > root.maxChars); onClicked: root.translate() }
        }
        ColumnLayout {
          visible: root.profilesOpen
          Layout.fillWidth: true
          spacing: Style.spacing.md
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md
            ColumnLayout {
              Layout.preferredWidth: Style.space(330)
              Layout.minimumWidth: Style.space(330)
              Layout.maximumWidth: Style.space(330)
              Layout.fillHeight: true
              enabled: !root.profileFormOpen
              opacity: enabled ? 1 : .55
              spacing: Style.spacing.sm
              Label {
                visible: root.profiles.length === 0
                text: "No profiles saved yet."
                color: Color.menu.text
                opacity: .75
                font.family: Style.font.menuFamily
              }
              Flickable {
                id: profileListFlickable
                visible: root.profiles.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(profileList.implicitHeight, Math.max(Style.space(180), Math.min(Style.space(440), panel.height * .55)))
                contentHeight: profileList.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ColumnLayout {
                  id: profileList
                  width: profileListFlickable.width - (profileListFlickable.contentHeight > profileListFlickable.height ? Style.space(12) : 0)
                  spacing: Style.spacing.sm
                  Repeater {
                    id: profileRepeater
                    model: root.displayProfiles
                    delegate: ColumnLayout {
                      id: profileEntry
                      required property var modelData
                      required property int index
                      readonly property var rowButton: profileRow
                      readonly property bool isSelected: root.profileSelectedIndex === index
                      Layout.fillWidth: true
                      spacing: Style.spacing.sm
                      RowLayout {
                        visible: root.profileStartsGroup(profileEntry.index)
                        Layout.fillWidth: true
                        Layout.topMargin: profileEntry.index > 0 ? Style.spacing.sm : 0
                        spacing: Style.spacing.sm
                        Label {
                          text: root.profilePairLabel(profileEntry.modelData)
                          color: Color.menu.text
                          font.family: Style.font.menuFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          elide: Text.ElideRight
                          Layout.maximumWidth: Style.space(260)
                        }
                        Rectangle {
                          color: Color.menu.text
                          opacity: .2
                          Layout.fillWidth: true
                          Layout.preferredHeight: 1
                        }
                        Label {
                          text: root.profilePairCount(profileEntry.modelData)
                          color: Color.menu.text
                          opacity: .68
                          font.family: Style.font.menuFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                      Button {
                        id: profileRow
                        Layout.fillWidth: true
                        implicitHeight: Math.max(Style.space(56), profileRowContent.implicitHeight + Style.spacing.sm * 2)
                        focusable: true
                        bordered: true
                        selected: profileEntry.isSelected
                        onClicked: root.setProfileSelection(index)
                        onActiveFocusChanged: if (activeFocus) root.setProfileSelection(index)
                        Keys.priority: Keys.BeforeItem
                        Keys.onPressed: function(event) {
                          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            root.loadProfile(modelData.id)
                            event.accepted = true
                          }
                        }
                        Shortcut {
                          sequence: index < 10 ? String((index + 1) % 10) : ""
                          context: Qt.WindowShortcut
                          enabled: root.opened && root.profilesOpen && !root.profileFormOpen
                            && !root.busy && root.recordingAction === "" && index < 10
                          onActivated: root.loadProfile(modelData.id)
                        }
                        RowLayout {
                          id: profileRowContent
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.leftMargin: Style.spacing.sm + Style.space(2)
                          anchors.rightMargin: Style.spacing.sm + Style.space(2)
                          spacing: Style.spacing.sm + Style.space(2)
                          Rectangle {
                            opacity: index < 10 ? 1 : 0
                            color: profileEntry.isSelected ? Color.menu.text : "transparent"
                            border.width: 1
                            border.color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, .35)
                            radius: Style.cornerRadius
                            Layout.preferredWidth: Style.space(26)
                            Layout.preferredHeight: Style.space(26)
                            Label {
                              anchors.centerIn: parent
                              text: String((index + 1) % 10)
                              color: profileEntry.isSelected ? Color.menu.background : Color.menu.text
                              font.family: Style.font.menuFamily
                              font.bold: true
                            }
                          }
                          Label {
                            text: modelData.name
                            color: Color.menu.text
                            font.family: Style.font.menuFamily
                            font.bold: true
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                          }
                          Label {
                            visible: modelData.id === root.activeProfileId
                            text: "active"
                            color: Color.menu.text
                            opacity: .68
                            font.family: Style.font.menuFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }
                    }
                  }
                }
              }
              Item { Layout.fillHeight: true }
              Button {
                id: newProfileButton
                Layout.fillWidth: true
                focusable: true
                text: "+ New from current settings"
                bordered: true
                leftAlign: true
                selected: root.profileSelectedIndex === root.profiles.length
                onClicked: root.startNewProfile()
                onActiveFocusChanged: if (activeFocus) root.setProfileSelection(root.profiles.length)
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    root.startNewProfile()
                    event.accepted = true
                  }
                }
              }
            }
            Rectangle {
              color: Color.menu.text
              opacity: .2
              Layout.preferredWidth: 1
              Layout.fillHeight: true
            }
            ColumnLayout {
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.minimumHeight: Style.space(230)
              spacing: Style.spacing.md
              Label {
                Layout.fillWidth: true
                text: root.editingProfile ? "Edit profile" : (root.shownProfile ? root.shownProfile.name : "New profile")
                color: Color.menu.text
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body * 1.15
                font.bold: true
                wrapMode: Text.Wrap
              }
              Label {
                visible: !root.shownProfile && !root.profileFormOpen
                Layout.fillWidth: true
                text: "Save the current translator, languages, and instructions under a short name."
                color: Color.menu.text
                opacity: .68
                wrapMode: Text.WordWrap
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
              }
              Label {
                visible: !root.profileFormOpen && root.shownProfile !== null && root.shownProfile.id === root.activeProfileId
                text: "Active profile"
                color: Color.menu.text
                opacity: .68
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
              }
              ProfileDetailRow {
                visible: !root.profileFormOpen
                label: "Translator"
                value: root.shownProfile ? root.shownProfile.translator : root.translator
                note: root.profileChangeNote("translator")
              }
              ProfileDetailRow {
                visible: !root.profileFormOpen
                label: "Languages"
                value: root.shownProfile ? root.profilePairLabel(root.shownProfile) : root.nameFor(root.sourceLanguage) + " → " + root.nameFor(root.targetLanguage)
                note: root.profileChangeNote("languages")
              }
              ProfileDetailRow {
                visible: !root.profileFormOpen && root.translatorUsesLlm(root.shownProfile ? root.shownProfile.translator : root.translator)
                label: "Instructions"
                value: (root.shownProfile ? root.shownProfile.instruction : root.activeProfileInstruction()) || "None"
                note: root.profileChangeNote("instruction")
                maxLines: 4
              }
              ColumnLayout {
                visible: root.profileFormOpen
                Layout.fillWidth: true
                spacing: Style.spacing.sm
                Label { text: "Profile name"; color: Color.menu.text; font.family: Style.font.menuFamily }
                TextField {
                  id: profileNameField
                  Layout.fillWidth: true
                  maximumLength: 64
                  placeholderText: "e.g. Formal Japanese"
                  onAccepted: root.activateProfilePrimary()
                }
              }
              GridLayout {
                visible: root.profileFormOpen
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Style.spacing.md
                rowSpacing: Style.spacing.sm
                Label { text: "Translator"; color: Color.menu.text; font.family: Style.font.menuFamily; Layout.preferredWidth: Style.space(96) }
                Dropdown {
                  id: profileTranslatorDropdown
                  Layout.fillWidth: true
                  showLabel: false
                  fontFamily: Style.font.menuFamily
                  options: root.profileTranslatorOptions()
                  onChanged: function(value) { root.setProfileDraft("translator", value) }
                }
                Label { text: "From"; color: Color.menu.text; font.family: Style.font.menuFamily }
                SearchableDropdown {
                  id: profileSourceDropdown
                  Layout.fillWidth: true
                  showLabel: false
                  fontFamily: Style.font.menuFamily
                  placeholderText: "Search languages..."
                  options: root.languageDropdownOptions(root.sourceLanguages(root.profileDraftTranslator))
                  onChanged: function(value) { root.setProfileDraft("source", value) }
                }
                Label { text: "To"; color: Color.menu.text; font.family: Style.font.menuFamily }
                SearchableDropdown {
                  id: profileTargetDropdown
                  Layout.fillWidth: true
                  showLabel: false
                  fontFamily: Style.font.menuFamily
                  placeholderText: "Search languages..."
                  options: root.languageDropdownOptions(root.targetLanguages(root.profileDraftSource, root.profileDraftTranslator))
                  onChanged: function(value) { root.setProfileDraft("target", value) }
                }
              }
              ColumnLayout {
                visible: root.profileFormOpen && root.profileDraftUsesLlm()
                Layout.fillWidth: true
                spacing: Style.spacing.sm
                Label { text: "Instructions (optional)"; color: Color.menu.text; font.family: Style.font.menuFamily }
                ScrollView {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Math.min(Math.max(Style.space(240), profileInstructionField.implicitHeight), Math.max(Style.space(180), Math.min(Style.space(420), panel.height * .4)))
                  contentWidth: availableWidth
                  TextArea {
                    id: profileInstructionField
                    textFormat: TextEdit.PlainText
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    color: Color.menu.text
                    font.family: Style.font.menuFamily
                    placeholderText: "e.g. Use polite Japanese and preserve product names."
                  }
                }
                Label {
                  Layout.fillWidth: true
                  text: root.profileInstructionLength.toLocaleString() + " / " + root.maxProfileInstructionChars.toLocaleString() + " characters"
                    + (root.profileInstructionLength > root.maxProfileInstructionChars ? " · Over the limit. Shorten the instructions to save."
                      : root.profileInstructionLength === root.maxProfileInstructionChars ? " · Character limit reached." : "")
                  color: root.profileInstructionLength >= root.maxProfileInstructionChars ? "#e06c75" : Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
              Item { Layout.fillHeight: true }
              Label {
                visible: root.profilesError !== ""
                Layout.fillWidth: true
                text: root.profilesError
                color: "#e06c75"
                wrapMode: Text.WordWrap
                font.family: Style.font.menuFamily
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.sm
                Button {
                  id: profilePrimaryButton
                  text: root.profileFormOpen ? "Save" : (root.shownProfile ? "Load profile" : "Create profile")
                  bordered: true
                  selected: true
                  enabled: !root.busy
                  onClicked: root.activateProfilePrimary()
                }
                Button {
                  id: profileEditButton
                  visible: root.shownProfile !== null && !root.profileFormOpen
                  text: "Edit"
                  bordered: true
                  enabled: !root.busy
                  onClicked: root.startEditProfile()
                }
                Button {
                  id: profileDeleteButton
                  visible: root.shownProfile !== null && !root.profileFormOpen
                  text: root.shownProfile && root.profileDeleteConfirmationId === root.shownProfile.id ? "Confirm delete" : "Delete"
                  foreground: root.shownProfile && root.profileDeleteConfirmationId === root.shownProfile.id ? "#e06c75" : Color.menu.text
                  bordered: true
                  enabled: !root.busy
                  onClicked: root.removeProfile(root.shownProfile.id)
                }
                Button {
                  visible: !root.profileFormOpen && root.shownProfile !== null && root.shownProfile.id === root.activeProfileId
                  text: "Stop using"
                  bordered: true
                  enabled: !root.busy
                  onClicked: root.clearActiveProfile()
                }
                Item { Layout.fillWidth: true }
                Button {
                  visible: root.profileFormOpen
                  text: "Cancel"
                  bordered: true
                  onClicked: root.cancelProfileForm()
                }
                Button {
                  id: backProfileButton
                  visible: !root.profileFormOpen
                  text: "Back"
                  bordered: true
                  onClicked: root.closeProfiles()
                }
              }
            }
          }
          Label {
            visible: root.showHotkeys
            text: root.profileFormOpen ? "Enter in name saves · Esc cancel"
              : (root.profiles.length === 0 ? "Enter create · Esc back" : "1–9 / 0 load · Ctrl+J/K select · Enter load/create · E edit · Delete remove · Esc back")
            color: Color.menu.text
            opacity: .65
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
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
          RowLayout {
            Layout.fillWidth: true
            Label { text: root.settingsSelectedIndex === 12 ? "󰁔" : ""; color: Color.menu.text; Layout.preferredWidth: Style.space(16) }
            ColumnLayout {
              Layout.fillWidth: true
              Label { text: "Review Translation"; color: Color.menu.text }
              Label {
                Layout.fillWidth: true
                text: "Check AI translations for missing information, changed meaning, invented details and incorrect terminology before displaying the result. Correct wording is left unchanged. Uses an additional AI request."
                color: Color.menu.text
                opacity: .80
                wrapMode: Text.WordWrap
                font.pixelSize: Style.font.caption
              }
            }
            Switch {
              id: reviewTranslationSwitch
              checked: root.reviewTranslation
              function activateSetting() { root.savePreferences({reviewTranslation: !root.reviewTranslation}) }
              onToggled: if (checked !== root.reviewTranslation) root.savePreferences({reviewTranslation: checked})
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                  activateSetting()
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
