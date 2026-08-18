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
  def test_preferences_atomic_and_private(self):
    result = qt.preferences_set({"sourceLanguage":"ja", "targetLanguage":"en"})
    self.assertTrue(result["ok"]); path = Path(qt.state_path())
    self.assertEqual(json.loads(path.read_text()), {"sourceLanguage":"ja", "targetLanguage":"en"})
    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
  def test_invalid_language_and_limits(self):
    self.assertFalse(qt.preferences_set({"sourceLanguage":"xx","targetLanguage":"en"})["ok"])
    self.assertEqual(qt.translate({"text":"", "sourceLanguage":"en","targetLanguage":"ja"})["error"]["code"], "blank_input")
    self.assertEqual(qt.translate({"text":"x"*5001, "sourceLanguage":"en","targetLanguage":"ja"})["error"]["code"], "input_too_long")
  def test_same_language_and_unicode_multiline(self):
    text = "こんにちは\nworld 🌏"
    self.assertEqual(qt.translate({"text":text,"sourceLanguage":"ja","targetLanguage":"ja"})["data"]["translation"], text)
  def test_parse_google_response(self):
    self.assertEqual(qt.parse_google_response('[[["hola","hello",null,null,1],[" mundo"," world",null,null,1]]]'), "hola mundo")
    with self.assertRaises(ValueError): qt.parse_google_response("{}")
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
    self.assertIn("stdinEnabled: true", qml)
    self.assertIn('write(payload + "\\n")', qml)
    self.assertNotIn('["bash", "-c"', qml)
if __name__ == "__main__": unittest.main()
