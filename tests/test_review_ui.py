"""Opt-in QML lifecycle regression test, using synthetic data and isolated preferences.

Run in a desktop session with RUN_QML_TESTS=1 python3 -m unittest discover -s tests.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get("RUN_QML_TESTS") == "1", "requires an Omarchy desktop session")
class ReviewUiTests(unittest.TestCase):
    def test_review_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="quick-translate-review-ui-") as directory:
            root = Path(directory)
            plugin = root / "plugin"
            plugin.mkdir()
            for name in ("Commons", "Ui", "services"):
                (root / name).symlink_to(Path("/usr/share/omarchy/shell") / name, target_is_directory=True)
            qml = (HERE / "QuickTranslate.qml").read_text()
            qml = qml.replace("  property bool opened: false", """  property int testTimeoutMs: 300000
  readonly property string testOutput: outputBox.text
  function setTestText(value) { sourceBox.text = value; syncLanguageSelectors() }
  function testToggleReview() { reviewTranslationSwitch.activateSetting() }
  property bool opened: false""").replace('interval: root.translationStage === "reviewing" ? 900000 : 300000', "interval: root.testTimeoutMs")
            (plugin / "QuickTranslate.qml").write_text(qml)
            shutil.copyfile(HERE / "languages.json", plugin / "languages.json")
            shutil.copyfile(HERE / "tests" / "qml" / "fake_review_provider.py", plugin / "quick_translate.py")
            shutil.copyfile(HERE / "tests" / "qml" / "review_lifecycle.qml", root / "shell.qml")
            environment = dict(os.environ, XDG_STATE_HOME=str(root / "state"), REVIEW_REAL_HELPER=str(HERE / "quick_translate.py"),
                               REVIEW_TEST_LOG=str(root / "calls.log"), QT_QUICK_CONTROLS_STYLE="Basic")
            result = subprocess.run(["quickshell", "--path", str(root), "--no-color"],
                                    env=environment, capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("PASS: review lifecycle", output)
            self.assertNotIn("FAIL:", output)
            calls = (root / "calls.log").read_text().splitlines()
            self.assertEqual(calls.count("review:failure"), 1, calls)
            self.assertEqual(calls.count("review:cancelreview"), 1, calls)
            self.assertEqual(calls.count("translate:single"), 1, calls)
            self.assertEqual(calls.count("copy:FINAL REVIEW"), 1, calls)
            self.assertNotIn("copy:PRIVATE DRAFT", calls)
            self.assertNotIn("translate:failure:review", calls)


if __name__ == "__main__":
    unittest.main()
