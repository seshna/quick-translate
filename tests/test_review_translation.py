import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("review_helper", HERE / "quick_translate.py")
qt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qt)


class ReviewTranslationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {"XDG_STATE_HOME": self.directory.name})
        self.environment.start()
        self.params = {"text": "Translate this sentence.",
                       "sourceLanguage": "en", "targetLanguage": "fr", "translator": "ollama"}
        self.context = "Keep BrewKeeper and personal names. Use professional brewing terminology. For Japanese only: use です／ます."

    def tearDown(self):
        self.environment.stop()
        self.directory.cleanup()

    @staticmethod
    def brewing_profile(instruction):
        return {"id": "brew", "name": "Brewing", "translator": "ollama", "sourceLanguage": "en",
                "targetLanguage": "fr", "instruction": instruction}

    def save_context(self, **preferences):
        values = {"profiles": [self.brewing_profile(self.context)], "activeProfileId": "brew", **preferences}
        self.assertTrue(qt.preferences_set(values)["ok"])

    @staticmethod
    def response(text, provider="ollama", stream=False, review=False, source="Translate this sentence.", draft=""):
        # The focused reviewer replies with plain text: a correction or the unchanged signal.
        if stream:
            chunks = [{"message": {"content": text}, "done": False}, {"done": True}]
            return io.BytesIO(b"".join((json.dumps(chunk, ensure_ascii=False) + "\n").encode() for chunk in chunks))
        payload = {"message": {"content": text}, "done": True} if provider == "ollama" else {"output_text": text, "status": "completed"}
        return io.BytesIO(json.dumps(payload, ensure_ascii=False).encode())

    def test_defaults_existing_preferences_and_round_trip(self):
        self.assertFalse(qt.preferences_get()["data"]["reviewTranslation"])
        self.save_context(showBarIcon=False, sourceLanguage="de", targetLanguage="es", openaiApiKey="test-key")
        before = qt.read_preferences()
        self.assertFalse(before["reviewTranslation"])
        result = qt.preferences_set({"reviewTranslation": True})
        self.assertTrue(result["data"]["reviewTranslation"])
        after = qt.read_preferences()
        self.assertEqual({key: value for key, value in after.items() if key != "reviewTranslation"},
                         {key: value for key, value in before.items() if key != "reviewTranslation"})
        self.assertTrue(qt.preferences_get()["data"]["reviewTranslation"])
        self.assertNotIn("openaiApiKey", result["data"])
        self.assertEqual(qt.preferences_set({"reviewTranslation": "true"})["error"]["code"], "invalid_preference")
        path = Path(qt.state_path())
        old = dict(after)
        del old["reviewTranslation"]
        path.write_text(json.dumps(old))
        self.assertFalse(qt.preferences_get()["data"]["reviewTranslation"])
        old["reviewTranslation"] = "bad"
        path.write_text(json.dumps(old))
        self.assertFalse(qt.preferences_get()["data"]["reviewTranslation"])

    @patch("urllib.request.urlopen")
    def test_off_keeps_one_request_for_both_ai_providers(self, opener):
        for provider in ("ollama", "openai"):
            with self.subTest(provider=provider):
                self.save_context(openaiApiKey="test-key", reviewTranslation=False)
                opener.reset_mock()
                opener.return_value = self.response("single pass", provider)
                result = qt.translate({**self.params, "translator": provider})
                self.assertEqual(result["data"]["translation"], "single pass")
                self.assertEqual(opener.call_count, 1)

    @patch("urllib.request.urlopen")
    def test_two_separate_calls_receive_complete_multilingual_inputs(self, opener):
        self.params["text"] = "Alice may transfer 12.5 L of wort.\n\n1. Open BrewKeeper."
        for provider in ("ollama", "openai"):
            for source, target in (("en", "fr"), ("de", "es"), ("fr", "de"), ("en", "ja"), ("ja", "en"), ("ar", "ko")):
                with self.subTest(provider=provider, source=source, target=target):
                    self.save_context(openaiApiKey="test-key", reviewTranslation=True)
                    before = qt.read_preferences()
                    draft = "BROKEN: Alice transfers 125 L.\nInvented greeting."
                    final = "CORRECTED: Alice may transfer 12.5 L of wort.\n\n1. Open BrewKeeper."
                    opener.reset_mock()
                    opener.side_effect = [self.response(draft, provider), self.response(final, provider, review=True, draft=draft, source=self.params["text"])]
                    result = qt.translate({**self.params, "translator": provider, "sourceLanguage": source, "targetLanguage": target})
                    self.assertEqual(result["data"], {"translation": final, "reviewed": True, "reviewChanged": True})
                    self.assertEqual(opener.call_count, 2)
                    first, second = [json.loads(call.args[0].data) for call in opener.call_args_list]
                    field = "messages" if provider == "ollama" else "input"
                    if provider == "ollama": self.assertEqual(first["model"], second["model"])
                    else: self.assertNotEqual(first["model"], second["model"])
                    self.assertIn("\n" + self.params["text"] + "\n", first[field][2]["content"])
                    self.assertIn(qt.LANGUAGE_NAMES[source], first[field][0]["content"])
                    self.assertIn(qt.LANGUAGE_NAMES[target], first[field][0]["content"])
                    self.assertIn(self.context, first[field][1]["content"])
                    self.assertIn("only to the language it concerns", first[field][1]["content"])
                    self.assertEqual(second[field][0]["content"], (HERE / "review_prompt.txt").read_text().strip())
                    message = second[field][1]["content"]
                    content = qt.review_sections(message)
                    self.assertEqual(content["original"], self.params["text"])
                    self.assertEqual(content["draft"], draft)
                    self.assertEqual(content["context"], self.context)
                    self.assertIn("Source language: %s (%s)" % (qt.LANGUAGE_NAMES[source], source), message)
                    self.assertIn("Target language: %s (%s)" % (qt.LANGUAGE_NAMES[target], target), message)
                    self.assertIn("Reply with exactly <<UNCHANGED>>", message)
                    self.assertIn("- BrewKeeper", message)
                    self.assertIn("The numbers do not match the original.", message)
                    self.assertNotIn("format", second)
                    self.assertNotIn("text", second)
                    self.assertEqual(qt.read_preferences(), before)
                    if provider == "ollama":
                        self.assertFalse(second["truncate"])
                        self.assertFalse(second["shift"])
                    else:
                        self.assertEqual(second["truncation"], "disabled")
                        self.assertNotIn("previous_response_id", second)

    def test_review_prompt_has_conditional_language_and_fidelity_rules(self):
        prompt = (HERE / "review_prompt.txt").read_text()
        for phrase in ("never assume English or Japanese", "only when they concern the selected target language",
                       "Missing information", "Changed meaning", "Invented details", "Incorrect terminology",
                       "Do not rewrite for fluency", "reply with exactly <<UNCHANGED>> and nothing else",
                       "reply with only the complete corrected translation", "Never convert a Roman-alphabet name"):
            self.assertIn(phrase, prompt)
        for removed in ("JSON", "schema", "coverage", "issues", "source_segments"):
            self.assertNotIn(removed, prompt)

    @patch("urllib.request.urlopen")
    def test_review_hides_streamed_draft_and_unfinished_review(self, opener):
        self.save_context(reviewTranslation=True)
        events = []
        opener.side_effect = [self.response("PRIVATE DRAFT", stream=True), self.response("FINAL REVIEW", stream=True, review=True, draft="PRIVATE DRAFT")]
        result = qt.translate(self.params, events.append)
        self.assertEqual(result["data"]["translation"], "FINAL REVIEW")
        self.assertEqual([event["draft"] for event in events if event["event"] == "draft"], ["PRIVATE DRAFT"])
        progress = [event for event in events if event["event"] == "progress"]
        self.assertEqual(progress[0], {"event": "progress", "characters": 13})
        self.assertEqual(progress[1]["characters"], len("FINAL REVIEW"))
        self.assertTrue(all("delta" not in event for event in progress))
        self.assertLess(next(i for i, event in enumerate(events) if event["event"] == "draft"),
                        next(i for i, event in enumerate(events) if event["event"] == "stage"))

    @patch("urllib.request.urlopen")
    def test_first_pass_failure_does_not_review(self, opener):
        self.save_context(reviewTranslation=True)
        opener.side_effect = TimeoutError()
        result = qt.translate(self.params)
        self.assertEqual(result["error"]["code"], "timeout")
        self.assertEqual(opener.call_count, 1)
        self.assertNotIn("reviewRequest", result)

    @patch("urllib.request.urlopen")
    def test_failed_review_retains_draft_and_retry_only_calls_reviewer(self, opener):
        self.save_context(openaiApiKey="test-key", reviewTranslation=True)
        opener.side_effect = [self.response("DRAFT"), TimeoutError()]
        failed = qt.translate(self.params)
        self.assertFalse(failed["ok"])
        self.assertEqual(failed["error"]["code"], "review_failed")
        self.assertIn("Translation succeeded, but review failed", failed["error"]["message"])
        self.assertEqual(failed["error"]["cause"], "timeout")
        self.assertNotIn("data", failed)
        retry = failed["reviewRequest"]
        self.assertEqual(retry["text"], self.params["text"])
        self.assertEqual(retry["draft"], "DRAFT")
        self.assertEqual(retry["customContext"], self.context)
        self.assertNotIn("openaiApiKey", retry)
        self.save_context(reviewTranslation=False)
        opener.reset_mock()
        opener.side_effect = None
        opener.return_value = self.response("REVIEWED", review=True, draft="DRAFT")
        result = qt.handle({"operation": "review", "params": retry})
        self.assertEqual(result["data"], {"translation": "REVIEWED", "reviewed": True, "reviewChanged": True})
        self.assertEqual(opener.call_count, 1)
        self.assertEqual(qt.review_sections(json.loads(opener.call_args.args[0].data)["messages"][1]["content"])["draft"], "DRAFT")

    @patch("urllib.request.urlopen")
    def test_job_uses_original_context_setting_and_provider_configuration(self, opener):
        self.save_context(reviewTranslation=True, openaiApiKey="initial-key", openaiReasoningEffort="low")
        calls = []
        def respond(request, **kwargs):
            calls.append(json.loads(request.data))
            if len(calls) == 1:
                self.assertTrue(qt.preferences_set({"reviewTranslation": False, "openaiApiKey": "new-key",
                    "openaiReasoningEffort": "high", "profiles": [self.brewing_profile("NEW CONTEXT")]})["ok"])
                return self.response("draft", "openai")
            self.assertEqual(request.get_header("Authorization"), "Bearer initial-key")
            return self.response("reviewed", "openai", review=True, draft="draft")
        opener.side_effect = respond
        result = qt.translate({**self.params, "translator": "openai"})
        self.assertTrue(result["ok"])
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1]["reasoning"], {"effort": "medium"})
        self.assertEqual(qt.review_sections(calls[1]["input"][1]["content"])["context"], self.context)

    @patch("urllib.request.urlopen")
    def test_review_snapshot_overrides_later_preferences_without_mutating_them(self, opener):
        self.save_context(reviewTranslation=False)
        opener.side_effect = [self.response("draft"), self.response("final", review=True, draft="draft")]
        result = qt.translate({**self.params, "reviewTranslation": True, "customContext": "SNAPSHOT"})
        self.assertTrue(result["data"]["reviewed"])
        content = qt.review_sections(json.loads(opener.call_args.args[0].data)["messages"][1]["content"])
        self.assertEqual(content["context"], "SNAPSHOT")
        self.assertFalse(qt.preferences_get()["data"]["reviewTranslation"])
        self.assertEqual(qt.active_profile_instruction(qt.read_preferences()), self.context)

    @patch("urllib.request.urlopen")
    def test_non_ai_and_same_language_keep_existing_behavior(self, opener):
        self.save_context(reviewTranslation=True)
        opener.return_value = io.BytesIO(b'[[["bonjour","hello",null,null,1]]]')
        result = qt.translate({**self.params, "translator": "google"})
        self.assertTrue(result["ok"])
        self.assertEqual(opener.call_count, 1)
        opener.reset_mock()
        result = qt.translate({**self.params, "targetLanguage": "en"})
        self.assertEqual(result["data"]["translation"], self.params["text"])
        opener.assert_not_called()

    @patch("urllib.request.urlopen")
    def test_incomplete_review_is_not_accepted(self, opener):
        self.save_context(reviewTranslation=True, openaiApiKey="test-key")
        for provider, bad in (("ollama", {"message": {"content": "partial"}, "done_reason": "length"}),
                              ("openai", {"output_text": "partial", "status": "incomplete"})):
            with self.subTest(provider=provider):
                opener.side_effect = [self.response("draft", provider), io.BytesIO(json.dumps(bad).encode())]
                result = qt.translate({**self.params, "translator": provider})
                self.assertEqual(result["error"]["code"], "review_failed")
                self.assertEqual(result["reviewRequest"]["draft"], "draft")

    @patch("urllib.request.urlopen")
    def test_invalid_review_responses_preserve_the_draft(self, opener):
        self.save_context(reviewTranslation=True, openaiApiKey="test-key")
        for provider, bad in (("ollama", b'not-json'), ("ollama", b'[]'), ("openai", b'[]'),
                              ("ollama", b'{"error":"failed","message":{"content":"partial"}}'),
                              ("openai", b'{"output_text":"partial","status":"failed"}')):
            with self.subTest(provider=provider, bad=bad):
                opener.side_effect = [self.response("draft", provider), io.BytesIO(bad)]
                result = qt.translate({**self.params, "translator": provider})
                self.assertEqual(result["error"]["code"], "review_failed")
                self.assertEqual(result["reviewRequest"]["draft"], "draft")

    @patch("urllib.request.urlopen")
    def test_empty_review_prompt_is_an_explicit_retryable_failure(self, opener):
        self.save_context(reviewTranslation=True)
        opener.return_value = self.response("draft")
        with patch.object(Path, "read_text", return_value=""):
            result = qt.translate(self.params)
        self.assertEqual(result["error"]["code"], "review_failed")
        self.assertEqual(result["error"]["cause"], "review_prompt")
        self.assertEqual(result["reviewRequest"]["draft"], "draft")
        self.assertEqual(opener.call_count, 1)

    @patch("urllib.request.urlopen")
    def test_long_original_draft_and_context_are_never_sliced(self, opener):
        context = "context " * 1375
        draft = "翻訳🌏\n" * 4000
        params = {**self.params, "text": "X\n" * 2500, "draft": draft, "customContext": context}
        params.update(translator="openai")
        self.save_context(openaiApiKey="test-key")
        opener.return_value = self.response(qt.UNCHANGED, "openai")
        result = qt.review_translation(params)
        self.assertEqual(result["data"], {"translation": draft, "reviewed": True, "reviewChanged": False})
        content = qt.review_sections(json.loads(opener.call_args.args[0].data)["input"][1]["content"])
        self.assertEqual(content, {"original": params["text"].strip(), "draft": draft, "context": context})

    def test_settings_and_review_ui_are_wired_to_existing_storage(self):
        qml = (HERE / "QuickTranslate.qml").read_text()
        for phrase in ('text: "Review Translation"', 'id: reviewTranslationSwitch',
                       'reviewTranslation = data.reviewTranslation === true', 'reviewTranslation: reviewTranslation',
                       'root.savePreferences({reviewTranslation: checked})', 'id: retryReviewButton',
                       'run("review", request', 'Reviewing translation…', 'translationDeadline.restart()',
                       'if (!canRetryReview) return', 'if (!root.translationReviewEnabled) root.translationPreview += event.delta'):
            self.assertIn(phrase, qml)
        self.assertIn("Check AI translations for missing information, changed meaning, invented details and incorrect terminology before displaying the result. Correct wording is left unchanged. Uses an additional AI request.", qml)
        self.assertIn('"Reviewed: no corrections needed."', qml)
        self.assertIn('" review characters generated"', qml)


if __name__ == "__main__":
    unittest.main()
