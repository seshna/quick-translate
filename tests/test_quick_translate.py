import importlib.util, io, json, os, stat, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("quick_translate", HERE / "quick_translate.py")
qt = importlib.util.module_from_spec(spec); spec.loader.exec_module(qt)

class QuickTranslateTests(unittest.TestCase):
  def setUp(self): self.tmp = tempfile.TemporaryDirectory(); self.env = patch.dict(os.environ, {"XDG_STATE_HOME": self.tmp.name}); self.env.start()
  def tearDown(self): self.env.stop(); self.tmp.cleanup()
  def test_defaults_and_corrupt_state(self):
    self.assertEqual(qt.preferences_get()["data"], qt.DEFAULTS)
    path = Path(qt.state_path()); path.parent.mkdir(parents=True); path.write_text("bad")
    self.assertEqual(qt.preferences_get()["data"], qt.DEFAULTS)
  def test_preferences_do_not_share_mutable_defaults(self):
    preferences = qt.preferences_get()["data"]
    preferences["shortcuts"]["copy"] = "Alt+C"
    self.assertEqual(qt.preferences_get()["data"]["shortcuts"], qt.DEFAULT_SHORTCUTS)
  def test_invalid_stored_shortcuts_fall_back_to_a_complete_default_map(self):
    path = Path(qt.state_path()); path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"shortcuts": {**qt.DEFAULT_SHORTCUTS, "copy": "Ctrl+U"}}))
    self.assertEqual(qt.preferences_get()["data"]["shortcuts"], qt.DEFAULT_SHORTCUTS)
  def test_preferences_atomic_and_private(self):
    result = qt.preferences_set({"sourceLanguage":"ja", "targetLanguage":"en", "openaiApiKey":"sk-test"})
    self.assertTrue(result["ok"]); path = Path(qt.state_path())
    self.assertEqual(json.loads(path.read_text())["sourceLanguage"], "ja")
    self.assertEqual(json.loads(path.read_text())["openaiApiKey"], "sk-test")
    self.assertNotIn("openaiApiKey", result["data"])
    self.assertTrue(result["data"]["openaiApiKeyConfigured"])
    self.assertEqual(json.loads(path.read_text())["shortcuts"], qt.DEFAULT_SHORTCUTS)
    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
    self.assertTrue(qt.preferences_set({"clearOpenaiApiKey": True})["ok"])
    self.assertFalse(qt.preferences_get()["data"]["openaiApiKeyConfigured"])
  def test_shortcut_and_bar_preferences(self):
    result = qt.preferences_set({"shortcuts": {"copy": "Alt+C"}, "translator": "reverso", "showBarIcon": False, "showHotkeys": False})
    self.assertTrue(result["ok"])
    self.assertEqual(result["data"]["shortcuts"]["copy"], "Alt+C")
    self.assertFalse(result["data"]["showBarIcon"])
    self.assertEqual(result["data"]["translator"], "reverso")
    self.assertFalse(result["data"]["showHotkeys"])
    self.assertEqual(qt.preferences_get()["data"]["shortcuts"]["translate"], "Ctrl+Enter")
  def test_translation_context_preferences(self):
    self.assertTrue(qt.preferences_set({"sourceLanguage": "ja", "targetLanguage": "en"})["ok"])
    contexts = [{"id": "formal-ja", "name": "Formal Japanese", "instruction": "Use formal Japanese."}]
    result = qt.preferences_set({"translationContexts": contexts, "selectedContextId": "formal-ja"})
    self.assertTrue(result["ok"])
    self.assertEqual(result["data"]["translationContexts"], contexts)
    self.assertEqual(result["data"]["selectedContextId"], "formal-ja")
    self.assertEqual((result["data"]["sourceLanguage"], result["data"]["targetLanguage"]), ("ja", "en"))
    self.assertEqual(qt.preferences_set({"selectedContextId": "missing"})["error"]["code"], "invalid_context")
    self.assertEqual(qt.preferences_set({"translationContexts": [{"id": "bad id", "name": "x", "instruction": "y"}]})["error"]["code"], "invalid_context")
    duplicate = contexts + [{"id": "casual-ja", "name": "formal japanese", "instruction": "Use casual Japanese."}]
    self.assertEqual(qt.preferences_set({"translationContexts": duplicate})["error"]["code"], "invalid_context")
  def test_editing_or_removing_contexts_preserves_languages(self):
    self.assertTrue(qt.preferences_set({"sourceLanguage": "de", "targetLanguage": "en"})["ok"])
    contexts = [
      {"id": "formal", "name": "Formal", "instruction": "Use formal wording."},
      {"id": "casual", "name": "Casual", "instruction": "Use casual wording."},
    ]
    self.assertTrue(qt.preferences_set({"translationContexts": contexts, "selectedContextId": "formal"})["ok"])
    edited = [{"id": "formal", "name": "Formal", "instruction": "Preserve honorifics."}, contexts[1]]
    result = qt.preferences_set({"translationContexts": edited, "selectedContextId": "formal"})
    self.assertTrue(result["ok"])
    self.assertEqual((result["data"]["sourceLanguage"], result["data"]["targetLanguage"]), ("de", "en"))
    result = qt.preferences_set({"translationContexts": [edited[0]], "selectedContextId": ""})
    self.assertTrue(result["ok"])
    self.assertEqual((result["data"]["sourceLanguage"], result["data"]["targetLanguage"]), ("de", "en"))
  def test_profile_preferences_and_deleted_context_references(self):
    profile = {"id": "formal-ja", "name": "Formal Japanese", "translator": "openai",
               "sourceLanguage": "en", "targetLanguage": "ja", "selectedContextId": "formal-context"}
    result = qt.preferences_set({"profiles": [profile]})
    self.assertTrue(result["ok"])
    self.assertEqual(result["data"]["profiles"], [profile])
    self.assertEqual(qt.preferences_get()["data"]["profiles"], [profile])
    path = Path(qt.state_path())
    path.write_text(json.dumps({"profiles": [profile, {"id": "bad profile", "name": "Broken"}]}))
    self.assertEqual(qt.preferences_get()["data"]["profiles"], [profile])
    duplicate = [profile, {**profile, "id": "casual-ja", "name": "formal japanese"}]
    self.assertEqual(qt.preferences_set({"profiles": duplicate})["error"]["code"], "invalid_profile")
    invalid_pair = [{**profile, "translator": "apertium", "sourceLanguage": "en", "targetLanguage": "ja"}]
    self.assertEqual(qt.preferences_set({"profiles": invalid_pair})["error"]["code"], "invalid_profile")
    too_many = [{**profile, "id": "profile-%d" % index, "name": "Profile %d" % index} for index in range(qt.MAX_PROFILES + 1)]
    self.assertEqual(qt.preferences_set({"profiles": too_many})["error"]["code"], "invalid_profile")
  def test_rejects_duplicate_shortcuts_and_allows_reassigning_undo(self):
    self.assertTrue(qt.preferences_set({"shortcuts": {"undo": "Alt+Z"}})["ok"])
    self.assertTrue(qt.preferences_set({"shortcuts": {"copy": "Ctrl+Z"}})["ok"])
    self.assertEqual(qt.preferences_set({"shortcuts": {"copy": "Ctrl+U"}})["error"]["code"], "duplicate_shortcut")
  def test_rejects_unicode_input_shortcut(self):
    result = qt.preferences_set({"shortcuts": {"switch": "Ctrl+Shift+U"}})
    self.assertEqual(result["error"]["code"], "reserved_shortcut")
    self.assertEqual(qt.preferences_get()["data"]["shortcuts"]["switch"], "Ctrl+U")
  def test_rejects_reserved_navigation_editing_and_super_shortcuts(self):
    for shortcut in ("Ctrl+Shift+?", "Ctrl+Shift+/", "Ctrl+Shift+P", "Ctrl+Shift+X", "Ctrl+J", "A", "Enter", "Meta+U"):
      with self.subTest(shortcut=shortcut):
        self.assertEqual(qt.preferences_set({"shortcuts": {"switch": shortcut}})["error"]["code"], "reserved_shortcut")
  def test_rejects_malformed_shortcuts_and_allows_function_keys(self):
    for shortcut in ("Ctrl+", "Ctrl+AA", "Ctrl+Ctrl+A", "Shift+A", "F36"):
      with self.subTest(shortcut=shortcut):
        self.assertFalse(qt.preferences_set({"shortcuts": {"switch": shortcut}})["ok"])
    self.assertTrue(qt.preferences_set({"shortcuts": {"switch": "F12"}})["ok"])
  def test_reset_shortcuts_uses_helper_defaults(self):
    self.assertTrue(qt.preferences_set({"shortcuts": {"copy": "Alt+C"}})["ok"])
    result = qt.handle({"operation": "preferences.resetShortcuts", "params": {}})
    self.assertTrue(result["ok"])
    self.assertEqual(result["data"]["shortcuts"], qt.DEFAULT_SHORTCUTS)
  def test_invalid_language_and_limits(self):
    self.assertFalse(qt.preferences_set({"sourceLanguage":"xx","targetLanguage":"en"})["ok"])
    self.assertEqual(qt.translate({"text":"", "sourceLanguage":"en","targetLanguage":"ja"})["error"]["code"], "blank_input")
    self.assertEqual(qt.translate({"text":"x"*5001, "sourceLanguage":"en","targetLanguage":"ja"})["error"]["code"], "input_too_long")
    self.assertEqual(qt.preferences_set({"translator": "unknown"})["error"]["code"], "invalid_translator")
    self.assertEqual(qt.translate({"text":"x", "translator":"apertium", "sourceLanguage":"en", "targetLanguage":"ja"})["error"]["code"], "unsupported_language_pair")
  def test_engine_catalogue_and_public_adapter_parsers(self):
    engines = {entry["id"]: entry for entry in qt.engine_data()["data"]}
    self.assertEqual(list(engines), ["google", "apertium", "bing", "reverso", "ollama", "openai"])
    self.assertEqual(engines["bing"]["maxChars"], 1000)
    self.assertIn(("en", "es"), [tuple(pair) for pair in engines["apertium"]["pairs"]])
    self.assertTrue(qt.pair_supported("reverso", "en", "ja"))
    self.assertFalse(qt.pair_supported("apertium", "en", "ja"))
    with patch("urllib.request.urlopen") as opener:
      page = MagicMock(); page.read.return_value = b'<script>IG:"ig" data-iid="iid" params_AbusePreventionHelper = [-123,"token",1]</script>'
      opener.return_value.__enter__.return_value = page
      self.assertEqual(qt.bing_credentials(), ("ig", "iid", "-123", "token"))
  @patch("urllib.request.urlopen")
  def test_llm_adapters_and_missing_openai_key(self, opener):
    self.assertEqual(qt.translate({"text":"hello", "translator":"openai", "sourceLanguage":"en", "targetLanguage":"es"})["error"]["code"], "openai_api_key_missing")
    contexts = [{"id": "formal-ja", "name": "Formal Japanese", "instruction": "Use formal Japanese."}]
    self.assertTrue(qt.preferences_set({"openaiApiKey":"sk-test", "openaiReasoningEffort":"low", "translationContexts": contexts, "selectedContextId": "formal-ja"})["ok"])
    response = MagicMock(); response.read.return_value = b'{"output":[{"type":"message","content":[{"type":"output_text","text":"hola"}]}]}'
    opener.return_value.__enter__.return_value = response
    result = qt.translate({"text":"hello", "translator":"openai", "sourceLanguage":"en", "targetLanguage":"es"})
    self.assertEqual(result["data"]["translation"], "hola")
    request = opener.call_args.args[0]
    self.assertEqual(request.get_header("Authorization"), "Bearer sk-test")
    payload = json.loads(request.data)
    self.assertEqual(payload["reasoning"], {"effort": "low"})
    self.assertIn("Translate the user's text from English to Spanish", payload["input"][0]["content"])
    self.assertIn("Additional translation context:\nUse formal Japanese.", payload["input"][0]["content"])
    self.assertEqual(payload["input"][1]["content"], "hello")
    response.read.return_value = b'{"message":{"content":"hola"}}'
    result = qt.translate({"text":"hello", "translator":"ollama", "sourceLanguage":"en", "targetLanguage":"es"})
    self.assertEqual(result["data"]["translation"], "hola")
    ollama_payload = json.loads(opener.call_args.args[0].data)
    self.assertEqual(ollama_payload["model"], "gemma3")
    self.assertFalse(ollama_payload["stream"])
    self.assertIn("Additional translation context:\nUse formal Japanese.", ollama_payload["messages"][0]["content"])
    self.assertTrue(qt.preferences_set({"selectedContextId": ""})["ok"])
    result = qt.translate({"text":"hello", "translator":"ollama", "sourceLanguage":"en", "targetLanguage":"es"})
    self.assertEqual(result["data"]["translation"], "hola")
    self.assertNotIn("Additional translation context:", json.loads(opener.call_args.args[0].data)["messages"][0]["content"])
  def test_same_language_and_unicode_multiline(self):
    text = "こんにちは\nworld 🌏"
    self.assertEqual(qt.translate({"text":text,"sourceLanguage":"ja","targetLanguage":"ja"})["data"]["translation"], text)
  def test_parse_google_response(self):
    self.assertEqual(qt.parse_google_response('[[["hola","hello",null,null,1],[" mundo"," world",null,null,1]]]'), "hola mundo")
    with self.assertRaises(ValueError): qt.parse_google_response("{}")
  def test_language_catalogue_is_shared_with_the_ui(self):
    catalogue = json.loads((HERE / "languages.json").read_text())
    self.assertEqual(qt.LANGUAGE_CODES, {row[0] for row in catalogue})
  def test_helper_version_uses_the_manifest_version(self):
    manifest = json.loads((HERE / "manifest.json").read_text())
    self.assertEqual(qt.PLUGIN_VERSION, manifest["version"])
  def test_response_size_is_bounded(self):
    payload = b'[[["hola","hello",null,null,1]]]'
    self.assertEqual(qt.read_google_response(io.BytesIO(payload)), "hola")
    with self.assertRaises(ValueError):
      qt.read_google_response(io.BytesIO(b"x" * (qt.MAX_RESPONSE_BYTES + 1)))
  @patch("urllib.request.urlopen")
  def test_network_failures(self, opener):
    import urllib.error
    opener.side_effect = urllib.error.URLError("offline")
    self.assertEqual(qt.translate({"text":"x","sourceLanguage":"en","targetLanguage":"ja"})["error"]["code"], "offline")
    http_error = urllib.error.HTTPError("u",429,"",{},None)
    try:
      opener.side_effect = http_error
      self.assertEqual(qt.translate({"text":"x","sourceLanguage":"en","targetLanguage":"ja"})["error"]["code"], "rate_limited")
    finally:
      http_error.close()
  @patch("urllib.request.urlopen")
  def test_openai_quota_and_rate_limit_errors(self, opener):
    import urllib.error
    self.assertTrue(qt.preferences_set({"openaiApiKey": "sk-test"})["ok"])
    quota_error = urllib.error.HTTPError("u", 429, "", {}, io.BytesIO(b'{"error":{"code":"insufficient_quota"}}'))
    opener.side_effect = quota_error
    result = qt.translate({"text":"hello", "translator":"openai", "sourceLanguage":"en", "targetLanguage":"es"})
    self.assertEqual(result["error"]["code"], "openai_quota")
    quota_error.close()
    rate_error = urllib.error.HTTPError("u", 429, "", {}, io.BytesIO(b'{"error":{"code":"rate_limit_exceeded"}}'))
    opener.side_effect = rate_error
    result = qt.translate({"text":"hello", "translator":"openai", "sourceLanguage":"en", "targetLanguage":"es"})
    self.assertEqual(result["error"]["code"], "openai_rate_limited")
    rate_error.close()
  @patch("urllib.request.urlopen")
  def test_translation_text_is_in_post_body_not_url(self, opener):
    response = MagicMock()
    response.read.return_value = b'[[["secret translation","secret source",null,null,1]]]'
    opener.return_value.__enter__.return_value = response
    result = qt.translate({"text":"secret source","sourceLanguage":"en","targetLanguage":"ja"})
    self.assertTrue(result["ok"])
    request = opener.call_args.args[0]
    self.assertNotIn("secret", request.full_url)
    self.assertEqual(request.data, b"q=secret+source")
  @patch("subprocess.run")
  def test_clipboard_error(self, run):
    run.side_effect = OSError()
    self.assertEqual(qt.copy_text({"text":"x"})["error"]["code"], "clipboard")
  @patch("subprocess.run")
  def test_clipboard_success_does_not_capture_forked_wl_copy_streams(self, run):
    run.return_value.returncode = 0
    self.assertTrue(qt.copy_text({"text":"x"})["ok"])
    self.assertEqual(run.call_args.args[0], ["wl-copy"])
    self.assertEqual(run.call_args.kwargs["input"], "x")
    self.assertTrue(run.call_args.kwargs["text"])
    self.assertEqual(run.call_args.kwargs["timeout"], 5)
    self.assertEqual(run.call_args.kwargs["stdout"], qt.subprocess.DEVNULL)
    self.assertEqual(run.call_args.kwargs["stderr"], qt.subprocess.DEVNULL)
  def test_single_request_stdio_protocol_exits_without_eof(self):
    request = json.dumps({"operation":"preferences.get", "params":{}}) + "\nignored\n"
    process = subprocess.Popen(
      [sys.executable, str(HERE / "quick_translate.py")],
      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
      text=True
    )
    try:
      process.stdin.write(request)
      process.stdin.flush()
      self.assertEqual(process.wait(timeout=2), 0)
      self.assertEqual(json.loads(process.stdout.read())["data"], qt.DEFAULTS)
    finally:
      if process.poll() is None:
        process.kill()
        process.wait()
      process.stdin.close()
      process.stdout.close()
      process.stderr.close()
  def test_qml_bridge_uses_stdin_without_a_shell(self):
    qml = (HERE / "QuickTranslate.qml").read_text()
    self.assertIn('bridge.command = ["python3", helperPath]', qml)
    self.assertIn('Qt.resolvedUrl("languages.json")', qml)
    self.assertIn('function loadLanguages(text)', qml)
    self.assertIn('Flickable {', qml)
    self.assertIn('contentHeight: content.implicitHeight', qml)
    self.assertGreaterEqual(qml.count('ScrollView {'), 2)
    self.assertIn('text: root.translating ? "Translating…" : root.translatedText', qml)
    self.assertNotIn('Label { visible: root.translating; text: "Translating…"', qml)
    self.assertIn('opacity: .55', qml)
    self.assertIn("stdinEnabled: true", qml)
    self.assertIn('write(payload + "\\n")', qml)
    self.assertNotIn('["bash", "-c"', qml)
  def test_qml_exposes_configurable_shortcuts_and_icons(self):
    qml = (HERE / "QuickTranslate.qml").read_text()
    self.assertIn('sequence: root.shortcut("translate")', qml)
    self.assertIn('Show in menu bar', qml)
    self.assertIn('Show shortcut hints', qml)
    self.assertIn('text: "About"', qml)
    self.assertIn('text: "Settings"', qml)
    self.assertIn('Item { Layout.preferredHeight: Style.spacing.md }', qml)
    self.assertNotIn('How translation works', qml)
    self.assertIn('Google, Apertium, Bing, Reverso, Ollama Local, or OpenAI', qml)
    self.assertIn('id: openaiReasoningPicker', qml)
    self.assertIn('id: contextButton', qml)
    self.assertIn('function openContexts()', qml)
    self.assertIn('function moveContextSelection(direction)', qml)
    self.assertIn('function saveContext()', qml)
    self.assertIn('label: root.reasoningEffortLabel(effort)', qml)
    self.assertIn('function activeTranslatorLabel()', qml)
    self.assertIn('Ollama Local · Gemma 3', qml)
    self.assertIn('OpenAI · GPT-5 mini', qml)
    self.assertIn('unofficial, may change or rate-limit requests', qml)
    self.assertIn('sequence: "Ctrl+?"', qml)
    self.assertIn('sequence: "Ctrl+Shift+P"', qml)
    self.assertIn('sequence: "Ctrl+Shift+X"', qml)
    self.assertIn('onActivated: root.contextsOpen ? root.closeContexts() : root.openContexts()', qml)
    self.assertIn('"󰒓  Ctrl+?"', qml)
    self.assertIn('"󰁍  Ctrl+?"', qml)
    self.assertIn('root.showHotkeys ? "󰁍  Ctrl+?" : "󰁍"', qml)
    self.assertIn('root.setupOpen ? root.closeSetup() : root.openSetup()', qml)
    self.assertIn('sequence: "Ctrl+J"', qml)
    self.assertIn('sequence: "Ctrl+K"', qml)
    self.assertIn('text: "Ctrl+J/K select"', qml)
    self.assertNotIn('Enter or Space change', qml)
    self.assertIn('settingsControls = [translatorPicker, openaiKeyField, removeOpenaiKeyButton', qml)
    self.assertIn('mainControls = [fromPicker, switchButton, toPicker, sourceBox, contextButton, clearButton, copyButton, copyAllButton, translateButton]', qml)
    self.assertIn('function moveMainSelection(direction)', qml)
    self.assertIn('function focusMainSelection()', qml)
    self.assertIn('onActivated: root.moveMainSelection(1)', qml)
    self.assertIn('onActivated: root.moveMainSelection(-1)', qml)
    self.assertIn('text: "Ctrl+J/K select"', qml)
    self.assertIn('settingsControls.length', qml)
    self.assertIn('control.forceActiveFocus()', qml)
    self.assertIn('"Restore all default shortcuts"', qml)
    self.assertIn('id: restoreButton\n              focusable: true\n              bordered: true', qml)
    self.assertIn('event.key === Qt.Key_Space', qml)
    self.assertIn('function handleActionShortcut(event)', qml)
    self.assertIn('function actionForShortcut(event)', qml)
    self.assertIn('function performAction(action)', qml)
    self.assertIn('function syncBarIconVisibility()', qml)
    self.assertIn('shell.bar.moduleWidgets(pluginId)', qml)
    self.assertIn('preferences.resetShortcuts', qml)
    self.assertIn('text: "Translator"', qml)
    self.assertIn('function translatorOptions()', qml)
    self.assertIn('No key / public web', qml)
    self.assertIn('Local model', qml)
    self.assertIn('API key required', qml)
    self.assertIn('enabled: !model.section', qml)
    self.assertIn('root.maxChars.toLocaleString()', qml)
    self.assertIn('echoMode: TextInput.Password', qml)
    self.assertIn('function saveOpenaiKey()', qml)
    self.assertIn('clearOpenaiApiKey: true', qml)
    self.assertNotIn('function reservedShortcutMessage(sequence)', qml)
    self.assertIn('root.recordingAction = ""', qml)
    self.assertIn('root.focusSettingsSelection()', qml)
    self.assertIn('Keys.onShortcutOverride', qml)
    self.assertIn('root.handleActionShortcut(event)', qml)
    self.assertIn('TextInput treats Ctrl+Shift+U as the start of a Unicode code', qml)
    self.assertIn('text: "󰗊"', qml)
    self.assertIn('󰆴  Clear', qml)
    self.assertIn('󰗊  Translate', qml)
    self.assertIn('actionText: "⇄"', qml)
    self.assertIn('compactActionText: root.copiedAction === "translation" ? "󰆏 ✓" : "󰆏"', qml)
    self.assertIn('compactActionText: root.copiedAction === "both" ? "󰆏 󰆏 ✓" : "󰆏 󰆏"', qml)
    self.assertIn('compactActionText: root.translating ? "󰗊 …" : "󰗊"', qml)
    self.assertIn('!control.showHotkey ? (control.compactActionText !== "" ? control.compactActionText : control.actionText)', qml)
  def test_qml_context_manager_selects_edits_and_deletes(self):
    qml = (HERE / "QuickTranslate.qml").read_text()
    for function in ("function openContexts()", "function startNewContext()", "function editContext(id)", "function selectContext(id)", "function saveContext()", "function removeContext(id)"):
      self.assertIn(function, qml)
    self.assertIn('id: newContextButton', qml)
    self.assertIn('id: backContextButton', qml)
    self.assertIn('id: noContextButton', qml)
    self.assertIn('id: savedContextSelectButton', qml)
    self.assertIn('id: savedContextEditButton', qml)
    self.assertIn('id: savedContextDeleteButton', qml)
    self.assertIn('text: root.contextDeleteConfirmationId === modelData.id ? "Confirm delete" : "Delete"', qml)
    self.assertIn('root.selectContext("")', qml)
    self.assertIn('root.moveContextSelection(1)', qml)
    self.assertIn('root.moveContextSelection(-1)', qml)
    self.assertIn('if (commitDisplayedLanguages()) saveLanguages()', qml)
  def test_qml_profiles_create_load_and_delete(self):
    qml = (HERE / "QuickTranslate.qml").read_text()
    for function in ("function openProfiles()", "function startNewProfile()", "function saveProfile()", "function loadProfile(id)", "function removeProfile(id)"):
      self.assertIn(function, qml)
    self.assertIn('profiles: profiles', qml)
    self.assertIn('savePreferences({profiles: next}', qml)
    self.assertIn('text: root.profileDeleteConfirmationId === modelData.id ? "Confirm delete" : "Delete"', qml)
    self.assertIn('text: root.showHotkeys ? "󰀻  Ctrl+Shift+P" : "󰀻"', qml)
    self.assertIn("function moveProfileSelection(direction)", qml)
    self.assertIn("profileRepeater.itemAt(profileIndex)", qml)
    self.assertIn("id: newProfileButton\n              focus:", qml)
    self.assertIn('text: root.profileSelectedIndex === 0 ? "󰁔" : ""', qml)
    self.assertIn("id: backProfileButton", qml)
    self.assertIn("id: profileLoadButton", qml)
    self.assertIn("id: profileDeleteButton", qml)
    self.assertIn("focusable: true", qml)
    self.assertIn('enabled: root.profilesOpen && !root.creatingProfile && root.recordingAction === ""', qml)
    self.assertIn('text: "Ctrl+J/K select · Enter load/create · Delete remove"', qml)
    self.assertIn("event.key === Qt.Key_Delete && root.selectedProfile()", qml)
  def test_qml_reopens_on_the_main_translation_page(self):
    qml = (HERE / "QuickTranslate.qml").read_text()
    open_function = qml.split("function open(payload)", 1)[1].split("function close()", 1)[0]
    self.assertIn("setupOpen = false", open_function)
    self.assertIn("opened = true", open_function)
  def test_qml_queues_operations_and_applies_only_saved_preference_fields(self):
    qml = (HERE / "QuickTranslate.qml").read_text()
    self.assertIn("pendingOperations = pendingOperations.concat", qml)
    self.assertIn("function startNextOperation()", qml)
    self.assertIn("root.startNextOperation()", qml)
    self.assertIn("function applyPreferenceResult(params, data, responseRevisions)", qml)
    self.assertIn("property int preferenceGeneration: 0", qml)
    self.assertIn("property var preferenceFieldRevisions: ({})", qml)
    self.assertIn("preferenceFieldRevisions[field] === responseRevisions[field]", qml)
    self.assertIn("initialGeneration === preferenceGeneration", qml)
    self.assertIn("applyPreferenceResult(params, reply.data, responseRevisions)", qml)
    self.assertIn('code: "helper_failed"', qml)
    self.assertIn("if (callback)", qml)
    self.assertNotIn("else if (callback)", qml)
  def test_qml_discards_a_translation_when_its_inputs_change(self):
    qml = (HERE / "QuickTranslate.qml").read_text()
    matcher = qml.split("function translationRequestIsCurrent(request)", 1)[1].split("function applyPreferences", 1)[0]
    for field in ("text", "translator", "sourceLanguage", "targetLanguage", "selectedContextId", "openaiReasoningEffort"):
      self.assertIn("request." + field, matcher)
    translate_function = qml.split("function translate()", 1)[1].split("function swap()", 1)[0]
    self.assertIn("if (!translationRequestIsCurrent(request))", translate_function)
    self.assertIn("Translation discarded because the text or settings changed.", translate_function)
  def test_qml_commits_displayed_languages_before_translation(self):
    qml = (HERE / "QuickTranslate.qml").read_text()
    self.assertIn("function commitDisplayedLanguages()", qml)
    translate_function = qml.split("function translate()", 1)[1].split("function swap()", 1)[0]
    self.assertIn("if (commitDisplayedLanguages()) saveLanguages()", translate_function)
    self.assertIn("function setSelectedContext(value)", qml)
    self.assertGreaterEqual(qml.count("if (commitDisplayedLanguages()) saveLanguages()"), 2)
    source_picker = qml.split("id: fromPicker", 1)[1].split("id: toPicker", 1)[0]
    target_picker = qml.split("id: toPicker", 1)[1].split("Item { Layout.preferredHeight", 1)[0]
    self.assertIn("onActiveFocusChanged:", source_picker)
    self.assertIn("onActiveFocusChanged:", target_picker)
    self.assertIn("onActivated: root.selectSourceLanguage(currentIndex)", qml)
    self.assertIn("onActivated: root.selectTargetLanguage(currentIndex)", qml)
  def test_bar_widget_uses_matching_icon(self):
    qml = (HERE / "BarWidget.qml").read_text()
    self.assertIn('text: "󰗊"', qml)
    self.assertIn('omarchy-shell shell toggle shaun.quick-translate', qml)
    self.assertIn('FileView {', qml)
    self.assertIn('import Quickshell', qml)
    self.assertIn('watchChanges: true', qml)
    self.assertIn('function setBarIconVisible(value)', qml)
    self.assertIn('interval: 30000', qml)
    self.assertIn('onTriggered: preferencesFile.reload()', qml)
    self.assertNotIn('Process {', qml)
if __name__ == "__main__": unittest.main()
