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
    contexts = [{"id": "formal-ja", "name": "Formal Japanese", "instruction": "Use formal Japanese."}]
    result = qt.preferences_set({"translationContexts": contexts, "selectedContextId": "formal-ja"})
    self.assertTrue(result["ok"])
    self.assertEqual(result["data"]["translationContexts"], contexts)
    self.assertEqual(result["data"]["selectedContextId"], "formal-ja")
    self.assertEqual(qt.preferences_set({"selectedContextId": "missing"})["error"]["code"], "invalid_context")
    self.assertEqual(qt.preferences_set({"translationContexts": [{"id": "bad id", "name": "x", "instruction": "y"}]})["error"]["code"], "invalid_context")
    duplicate = contexts + [{"id": "casual-ja", "name": "formal japanese", "instruction": "Use casual Japanese."}]
    self.assertEqual(qt.preferences_set({"translationContexts": duplicate})["error"]["code"], "invalid_context")
  def test_rejects_duplicate_shortcuts_and_allows_reassigning_undo(self):
    self.assertTrue(qt.preferences_set({"shortcuts": {"undo": "Alt+Z"}})["ok"])
    self.assertTrue(qt.preferences_set({"shortcuts": {"copy": "Ctrl+Z"}})["ok"])
    self.assertEqual(qt.preferences_set({"shortcuts": {"copy": "Ctrl+U"}})["error"]["code"], "duplicate_shortcut")
  def test_rejects_unicode_input_shortcut(self):
    result = qt.preferences_set({"shortcuts": {"switch": "Ctrl+Shift+U"}})
    self.assertEqual(result["error"]["code"], "reserved_shortcut")
    self.assertEqual(qt.preferences_get()["data"]["shortcuts"]["switch"], "Ctrl+U")
  def test_rejects_reserved_navigation_editing_and_super_shortcuts(self):
    for shortcut in ("Ctrl+Shift+?", "Ctrl+Shift+/", "Ctrl+J", "A", "Enter", "Meta+U"):
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
    self.assertEqual(run.call_args.kwargs["stdout"], qt.subprocess.DEVNULL)
    self.assertEqual(run.call_args.kwargs["stderr"], qt.subprocess.DEVNULL)
  def test_clipboard_formats(self):
    self.assertEqual("translated", "translated")
    self.assertEqual("source" + "\n\n" + "translated", "source\n\ntranslated")
  def test_swap_populated_empty_and_multiline(self):
    def swap(source_language, target_language, source, output):
      return target_language, source_language, output, source
    self.assertEqual(swap("en", "ja", "hello", "こんにちは"), ("ja", "en", "こんにちは", "hello"))
    self.assertEqual(swap("en", "ja", "", ""), ("ja", "en", "", ""))
    self.assertEqual(swap("en", "ja", "one\ntwo", "一\n二"), ("ja", "en", "一\n二", "one\ntwo"))
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
    self.assertIn('text: "Translating…"', qml)
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
    self.assertIn('id: contextPicker', qml)
    self.assertIn('id: contextEditorPicker', qml)
    self.assertIn('text: (root.contextEditorOpen ? "󰅂" : "󰅀") + "  Translation contexts"', qml)
    self.assertIn('visible: root.usesLlm() && root.contextEditorOpen', qml)
    self.assertIn('function saveContext()', qml)
    self.assertIn('label: root.reasoningEffortLabel(effort)', qml)
    self.assertIn('function activeTranslatorLabel()', qml)
    self.assertIn('Ollama Local · Gemma 3', qml)
    self.assertIn('OpenAI · GPT-5 mini', qml)
    self.assertIn('unofficial, may change or rate-limit requests', qml)
    self.assertIn('sequence: "Ctrl+?"', qml)
    self.assertIn('"󰒓  Ctrl+?"', qml)
    self.assertIn('"󰁍  Ctrl+?"', qml)
    self.assertIn('root.showHotkeys ? "󰁍  Ctrl+?" : "󰁍"', qml)
    self.assertIn('root.setupOpen ? root.closeSetup() : root.openSetup()', qml)
    self.assertIn('sequence: "Ctrl+J"', qml)
    self.assertIn('sequence: "Ctrl+K"', qml)
    self.assertIn('text: "Ctrl+J/K select"', qml)
    self.assertNotIn('Enter or Space change', qml)
    self.assertIn('settingsControls = [translatorPicker, openaiKeyField, removeOpenaiKeyButton', qml)
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
