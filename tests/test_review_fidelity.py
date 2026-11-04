"""Contract/regression tests. Mock API tests verify enforcement, not model quality."""
import contextlib
import io
import json
import os
import unittest
import urllib.error
from unittest.mock import patch

import quick_translate as qt
from review_validation import UNCHANGED, interpret_review, preservation_errors


CASES = [
    ("Ayano-san", "綾野様", "Ayano-san"),
    ("Ayano-san", "青山様", "Ayano-san"),
    ("Kegging", "ケージング", "樽詰め"),
    ("Lauter", "ロイヤー", "麦汁ろ過"),
    ("Calculated Dilution Amount vs Actual Dilution Amount", "計算上の希釈量と蒸発後の実際の希釈量", "計算上の希釈量と実際の希釈量の比較"),
    ("Excise Tax Report", "減価税レポート", "酒税レポート"),
    ("Several meetings", "会議", "複数の会議"),
    ("Put aside for staff", "保管する", "スタッフ用に取り置きする"),
    ("Recipe cost information", "レシピ情報", "レシピ原価情報"),
    ("e-Tax", "電子申告", "e-Tax"),
]


def response(text, provider):
    body = {"message": {"content": text}, "done": True} if provider == "ollama" else {
        "status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}]}
    return io.BytesIO(json.dumps(body).encode())


class FidelityTests(unittest.TestCase):
    def test_known_errors_are_rejected_and_correct_forms_accepted(self):
        for source, broken, corrected in CASES:
            with self.subTest(source=source, broken=broken):
                self.assertTrue(preservation_errors(source, broken, "en", "ja"))
                # Returning the faulty draft, or claiming it is unchanged, is not a review.
                for raw in (broken, UNCHANGED):
                    with self.assertRaisesRegex(ValueError, "preservation checks"):
                        interpret_review(raw, source, broken, "en", "ja")
                self.assertEqual(interpret_review(corrected, source, broken, "en", "ja"), (corrected, True))
        for source, bad, good in CASES[:4] + [CASES[5]]:
            self.assertTrue(preservation_errors(source, good + "（" + bad + "）", "en", "ja"))

    def test_real_orchestrator_accepts_corrections_and_rejects_regressions(self):
        prefs = {**qt.default_preferences(), "openaiApiKey": "test-key", "requestContext": "Use brewing terminology."}
        for provider in ("ollama", "openai"):
            for source, broken, corrected in CASES:
                for result, accepted in ((corrected, True), (broken, False), (UNCHANGED, False)):
                    with self.subTest(provider=provider, source=source, result=result):
                        params = {"text": source, "sourceLanguage": "en", "targetLanguage": "ja",
                                  "translator": provider, "reviewTranslation": True}
                        with patch.object(qt, "request_preferences", return_value=dict(prefs)), patch("urllib.request.urlopen") as opener:
                            opener.side_effect = [response(broken, provider), response(result, provider)]
                            value = qt.translate(params)
                            # Exactly one review request; no hidden repair loop.
                            self.assertEqual(opener.call_count, 2)
                            self.assertEqual(value["ok"], accepted)
                            if accepted:
                                self.assertEqual(value["data"], {"translation": corrected, "reviewed": True, "reviewChanged": True})
                            else:
                                self.assertEqual(value["error"]["code"], "review_failed")
                                self.assertEqual(value["error"]["cause"], "invalid_review")
                                self.assertIn("review failed", value["error"]["message"])
                                self.assertEqual(value["reviewRequest"]["draft"], broken)

    def test_draft_check_results_and_terminology_reach_the_single_review_request(self):
        source = "Ayano-san\nKegging\nLauter\nCalculated Dilution Amount vs Actual Dilution Amount\nExcise Tax Report\nSeveral meetings\nPut aside for staff\nRecipe cost information\ne-Tax"
        draft = "綾野様\nケージング\nロイヤー\n計算上の希釈量と蒸発後の実際の希釈量\n減価税レポート\n会議\n保管する\nレシピ情報\n電子申告"
        message = qt.review_message(source, draft, "en", "ja", "Keep names.")
        for expected in ("- Ayano-san", "- e-Tax", "- Kegging → 樽詰め", "- Lauter → 麦汁ろ過", "- Excise Tax Report → 酒税レポート",
                         "- Several meetings → 複数の会議", "- Put aside for staff → スタッフ用に取り置き",
                         "- Recipe cost information → レシピ原価情報", "Replace 綾野様 with Ayano-san", "Replace ケージング with 樽詰め",
                         "Remove 蒸発 (evaporation)", "write exactly e-Tax instead"):
            self.assertIn(expected, message)
        self.assertEqual(qt.review_sections(message), {"original": source, "draft": draft, "context": "Keep names."})
        # Japanese rules never apply to other pairs.
        spanish = qt.review_message("Kegging", "Envasado en barriles", "en", "es", "")
        self.assertNotIn("樽詰め", spanish)
        self.assertIn("Automatic checks found these problems in the draft:\nNone", spanish)
        self.assertIn("<custom_instructions>\nNone\n</custom_instructions>", spanish)

    def test_unchanged_signal_displays_original_draft(self):
        source, draft = "Please send the report tomorrow.", "Por favor, envía el informe mañana."
        for raw in (UNCHANGED, "  " + UNCHANGED + "\n", draft, draft + "\n", "```\n" + UNCHANGED + "\n```"):
            with self.subTest(raw=raw):
                self.assertEqual(interpret_review(raw, source, draft, "en", "es"), (draft, False))
        layout_source, layout_draft = "Send it. Tomorrow.", "Envíalo.\nMañana."
        self.assertEqual(interpret_review("Envíalo. Mañana.", layout_source, layout_draft, "en", "es"), (layout_draft, False))
        prefs = {**qt.default_preferences(), "requestContext": ""}
        params = {"text": source, "draft": draft, "sourceLanguage": "en", "targetLanguage": "es", "translator": "ollama"}
        with patch("urllib.request.urlopen", return_value=response(UNCHANGED, "ollama")):
            self.assertEqual(qt.review_translation(params, preferences=prefs)["data"],
                             {"translation": draft, "reviewed": True, "reviewChanged": False})

    def test_invalid_ambiguous_and_incomplete_reviews_fail(self):
        source = "First sentence about brewing schedules.\n" * 8
        draft = "Primera frase sobre los horarios de elaboración.\n" * 8
        invalid = {"": "empty review", "   \n": "empty review", None: "invalid review",
                   UNCHANGED + "\nThe draft is fine.": "ambiguous", draft + "\n" + UNCHANGED: "ambiguous",
                   "Corrected translation:\n" + draft: "commentary", "Here is the corrected translation:\n" + draft: "commentary",
                   "<draft>\n" + draft + "</draft>": "commentary", draft[:60]: "incomplete review"}
        for raw, reason in invalid.items():
            with self.subTest(raw=raw), self.assertRaisesRegex(ValueError, reason):
                interpret_review(raw, source, draft, "en", "es")
        prefs = {**qt.default_preferences(), "requestContext": ""}
        params = {"text": source, "draft": draft, "sourceLanguage": "en", "targetLanguage": "es", "translator": "ollama"}
        with patch("urllib.request.urlopen", return_value=response(UNCHANGED + " but improve tone", "ollama")):
            result = qt.review_translation(params, preferences=prefs)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "review_failed")
        self.assertIn("ambiguous review signal", result["error"]["message"])
        self.assertEqual(result["reviewRequest"]["draft"], draft)
        for private in (source, draft):
            self.assertNotIn(private, result["error"]["message"])

    def test_spanish_translation_correction_without_japanese_rules(self):
        source = "Please send the report tomorrow."
        draft = "Por favor, envía el informe."
        corrected = "Por favor, envía el informe mañana."
        self.assertEqual(interpret_review(corrected, source, draft, "en", "es"), (corrected, True))
        self.assertEqual(preservation_errors("Kegging", "Envasado en barriles", "en", "es"), [])

    def test_numbers_units_features_and_headings(self):
        source = "# Recipe\nTransfer 12.5 L into BrewKeeper."
        final = "# レシピ\nBrewKeeperに12.5 Lを移してください。"
        self.assertEqual(interpret_review(final, source, "broken", "en", "ja")[0], final)
        for broken in (final.replace("12.5", "125"), final.replace("L", "kg"), final.replace("BrewKeeper", "醸造管理"), final.replace("# ", "")):
            self.assertTrue(preservation_errors(source, broken, "en", "ja"))
            with self.assertRaises(ValueError):
                interpret_review(broken, source, "broken", "en", "ja")
        self.assertTrue(preservation_errors("12 L and 12 L", "12 L", "en", "es"))
        self.assertIn("units", preservation_errors("12 L and 5 kg", "12 kg y 5 L", "en", "es"))
        self.assertEqual(preservation_errors("12 L for staff", "12 litros para el personal", "en", "es"), [])
        self.assertEqual(preservation_errors("12 L", "１２リットル", "en", "ja"), [])
        self.assertEqual(preservation_errors("12 L", "١٢ L", "en", "ar"), [])
        self.assertIn("numbers", preservation_errors("-12 L", "12 L", "en", "es"))
        # A spelled-out English number may become a digit, but never a different value.
        self.assertEqual(preservation_errors("Keep two cases for batch 42.", "バッチ42のケースを2つ確保。", "en", "ja"), [])
        self.assertIn("numbers", preservation_errors("Keep two cases for batch 42.", "バッチ42のケースを3つ確保。", "en", "ja"))
        self.assertIn("numbers", preservation_errors("Keep cases for batch 42.", "バッチ42のケースを2つ確保。", "en", "ja"))
        self.assertIn("numbers", preservation_errors("Keep two cases.", "Garde deux caisses pour le lot 7.", "fr", "en"))

    def test_diagnostics_are_opt_in_and_contain_no_confidential_text(self):
        source, draft, final = "CONFIDENTIAL SOURCE", "CONFIDENTIAL DRAFT", "CONFIDENTIAL RESULT"
        prefs = {**qt.default_preferences(), "openaiApiKey": "SECRET-KEY", "requestContext": "CONFIDENTIAL CONTEXT"}
        params = {"text": source, "draft": draft, "sourceLanguage": "en", "targetLanguage": "es", "translator": "openai"}
        for enabled in ("0", "1"):
            stderr = io.StringIO()
            with patch.dict(os.environ, QUICK_TRANSLATE_DEV_DIAGNOSTICS=enabled), contextlib.redirect_stderr(stderr), patch("urllib.request.urlopen", return_value=response(final, "openai")):
                self.assertTrue(qt.review_translation(params, preferences=prefs)["ok"])
            logged = stderr.getvalue()
            for private in (source, draft, final, prefs["requestContext"], "SECRET-KEY"):
                self.assertNotIn(private, logged)
            if enabled == "0": self.assertEqual(logged, "")
            else:
                rows = [json.loads(line) for line in logged.splitlines()]
                request = next(row for row in rows if row["event"] == "request")
                self.assertEqual(request["model"], "gpt-5")
                self.assertTrue(request["source_matches"] and request["draft_matches"] and request["context_matches"])
                self.assertTrue(rows[-1]["changed"])

    def test_review_provider_settings_request_plain_text(self):
        prefs = {**qt.default_preferences(), "openaiApiKey": "test-key", "requestContext": ""}
        for provider in ("ollama", "openai"):
            params = {"text": "Hello", "draft": "Hola", "sourceLanguage": "en", "targetLanguage": "es", "translator": provider}
            with patch("urllib.request.urlopen", return_value=response(UNCHANGED, provider)) as opener:
                self.assertTrue(qt.review_translation(params, preferences=prefs)["ok"])
                body = json.loads(opener.call_args.args[0].data)
                field = "messages" if provider == "ollama" else "input"
                self.assertEqual(len(body[field]), 2)
                self.assertEqual(body[field][0]["content"], (qt.Path(qt.__file__).with_name("review_prompt.txt")).read_text().strip())
                for removed in ("coverage", "issues", "source_segments", "schema"):
                    self.assertNotIn(removed, body[field][1]["content"])
                if provider == "openai":
                    self.assertEqual(body["reasoning"]["effort"], "medium")
                    self.assertNotIn("text", body)
                    self.assertEqual(body["max_output_tokens"], 16384)
                    self.assertFalse(body["store"])
                else:
                    self.assertNotIn("format", body)
                    self.assertEqual(body["model"], "gemma3")
                    self.assertFalse(body["truncate"])
                    self.assertFalse(body["shift"])
                    self.assertEqual(body["options"], {"num_ctx": 32768, "num_predict": 16384, "temperature": 0.1})

    def test_long_multibyte_review_is_sent_complete_instead_of_rejected_by_bytes(self):
        source, draft, context = "A" * 5000, "翻訳" * 4000, "Context " * 1375
        prefs = {**qt.default_preferences(), "requestContext": context}
        params = {"text": source, "draft": draft, "sourceLanguage": "en", "targetLanguage": "es", "translator": "ollama"}
        with patch("urllib.request.urlopen", return_value=response(UNCHANGED, "ollama")) as opener:
            result = qt.review_translation(params, preferences=prefs)
            self.assertTrue(result["ok"], result)
            opener.assert_called_once()
            body = json.loads(opener.call_args.args[0].data)
            self.assertEqual(qt.review_sections(body["messages"][1]["content"]), {"original": source, "draft": draft, "context": context})
            self.assertGreater(len(body["messages"][1]["content"].encode("utf-8")), 32768)
            self.assertEqual(body["options"]["num_ctx"], 32768)
            self.assertEqual(body["options"]["num_predict"], 16384)
            self.assertFalse(body["truncate"])
            self.assertFalse(body["shift"])

    def test_actual_engine_context_overflow_is_a_visible_review_failure(self):
        prefs = {**qt.default_preferences(), "requestContext": "Keep everything."}
        params = {"text": "Hello", "draft": "Hola", "sourceLanguage": "en", "targetLanguage": "es", "translator": "ollama"}
        body = {"error": json.dumps({"error": {"type": "exceed_context_size_error", "n_prompt_tokens": 40000, "n_ctx": 32768}})}
        for progress in (None, lambda event: None):
            error = urllib.error.HTTPError("http://localhost:11434/api/chat", 400, "Bad Request", {}, io.BytesIO(json.dumps(body).encode()))
            with patch("urllib.request.urlopen", side_effect=error) as opener:
                result = qt.review_translation(params, preferences=prefs, progress=progress)
                self.assertFalse(result["ok"])
                self.assertEqual(result["error"]["cause"], "review_context_limit")
                self.assertIn("local model reported", result["error"]["message"])
                self.assertEqual(result["reviewRequest"]["draft"], "Hola")
                opener.assert_called_once()

    def test_streamed_review_reaching_output_limit_fails(self):
        prefs = {**qt.default_preferences(), "requestContext": ""}
        params = {"text": "Hello", "draft": "Hola", "sourceLanguage": "en", "targetLanguage": "es", "translator": "ollama"}
        chunks = [{"message": {"content": "Hol"}, "done": False}, {"done": True, "done_reason": "length"}]
        stream = io.BytesIO(b"".join((json.dumps(chunk) + "\n").encode() for chunk in chunks))
        with patch("urllib.request.urlopen", return_value=stream):
            result = qt.review_translation(params, progress=lambda event: None, preferences=prefs)
        self.assertEqual(result["error"]["code"], "review_failed")
        self.assertEqual(result["error"]["cause"], "incomplete_translation")


if __name__ == "__main__": unittest.main()
