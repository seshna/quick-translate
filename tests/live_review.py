"""Opt-in, real model evaluation using synthetic fixtures only.

From the plugin directory: python3 tests/live_review.py --provider ollama [--case NAME]
OpenAI uses the saved API key and may incur charges. Never uses saved context or
message text. This is separate from the deterministic/mock unit test suite.
"""
import argparse
import json
import re
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import quick_translate as qt
from review_validation import preservation_errors

CASES = ("japanese-fixture", "japanese-pipeline", "spanish", "french-plain", "long")
parser = argparse.ArgumentParser()
parser.add_argument("--provider", choices=("openai", "ollama"), required=True)
parser.add_argument("--case", choices=("all",) + CASES, default="all")
args = parser.parse_args()

BREWING = "Use professional brewing terminology. Preserve Roman names and e-Tax exactly. For Japanese only: use です／ます."
FIXTURE = ("Ayano-san\nKegging\nLauter\nCalculated Dilution Amount vs Actual Dilution Amount\nExcise Tax Report\n"
           "Several meetings\nPut aside for staff\nRecipe cost information\ne-Tax")
BROKEN = "綾野様\nケージング\nロイヤー\n計算上の希釈量と蒸発後の実際の希釈量\n減価税レポート\n会議\n保管する\nレシピ情報\n電子申告"
PIPELINE = ("Hi Ayano-san,\n\nThanks for your help with kegging and the lauter step last week. Could you compare the "
            "Calculated Dilution Amount vs Actual Dilution Amount for batch 42? We also need the Excise Tax Report "
            "before filing through e-Tax. After several meetings, we agreed to keep two cases put aside for staff. "
            "Please send the recipe cost information by Friday.")
PARAGRAPH = ("On {day}, the brewery transferred {volume} L of wort from the lauter tun to fermenter {tank}. "
             "The gravity reading was {gravity}, and the team recorded the temperature at {temp} °C. "
             "Ayano-san asked whether the kegging schedule should move because several meetings overlap with "
             "the packaging shift. The Excise Tax Report for this batch must be filed through e-Tax before the "
             "end of the month. Please keep {cases} cases put aside for staff and do not include them in the "
             "sales total. Recipe cost information for this batch is still provisional, so the final figure "
             "may change after the hop invoice arrives.\n\n")
DAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Monday")
LONG = "".join(PARAGRAPH.format(day=day, volume=1200 + 25 * i, tank=i + 1, gravity="1.0%02d" % (48 + i),
                                temp=18 + i % 3, cases=2 + i) for i, day in enumerate(DAYS)).strip()


validate = qt.interpret_review
def show_rejected(raw, *inputs):
    try: return validate(raw, *inputs)
    except ValueError as exc:
        # Safe to print: this runner only ever sends the synthetic fixtures in this file.
        print(json.dumps({"rejected": str(exc), "synthetic_candidate": raw}, ensure_ascii=False), flush=True)
        raise
qt.interpret_review = show_rejected


def preferences(context):
    value = qt.default_preferences()
    if args.provider == "openai": value["openaiApiKey"] = qt.read_preferences().get("openaiApiKey")
    value["requestContext"] = context
    return value


def report(case, started, result, extra=None, checks=()):
    seconds = round(time.monotonic() - started, 1)
    data = result.get("data") or {}
    failed = [name for name, ok in checks if not ok]
    ok = bool(result.get("ok")) and not failed
    print(json.dumps({"case": case, "ok": ok, "seconds": seconds, "reviewChanged": data.get("reviewChanged"),
                      "failed_checks": failed, "error": result.get("error"), **(extra or {}),
                      "result": data.get("translation")}, ensure_ascii=False), flush=True)
    return ok


def draft_for(text, source, target, prefs):
    if args.provider == "openai": return qt.translate_openai(text, source, target, prefs)
    return qt.translate_ollama(text, source, target, preferences=prefs)


def run(case):
    if case == "japanese-fixture":
        prefs = preferences(BREWING)
        started = time.monotonic()
        result = qt.review_translation({"text": FIXTURE, "draft": BROKEN, "sourceLanguage": "en", "targetLanguage": "ja",
                                        "translator": args.provider}, preferences=prefs)
        return report(case, started, result)
    if case in {"japanese-pipeline", "long"}:
        text = PIPELINE if case == "japanese-pipeline" else LONG
        prefs = preferences(BREWING)
        started = time.monotonic()
        draft = draft_for(text, "en", "ja", prefs)
        draft_seconds = round(time.monotonic() - started, 1)
        result = qt.review_translation({"text": text, "draft": draft, "sourceLanguage": "en", "targetLanguage": "ja",
                                        "translator": args.provider}, preferences=prefs)
        return report(case, started, result, {"source_characters": len(text), "draft_seconds": draft_seconds,
                      "draft_check_failures": preservation_errors(text, draft, "en", "ja"), "draft": draft})
    if case == "spanish":
        text, prefs = "Please send the report tomorrow. The meeting moved to 3 pm.", preferences("Use neutral professional Spanish.")
        started = time.monotonic()
        draft = draft_for(text, "en", "es", prefs)
        result = qt.review_translation({"text": text, "draft": draft, "sourceLanguage": "en", "targetLanguage": "es",
                                        "translator": args.provider}, preferences=prefs)
        final = (result.get("data") or {}).get("translation", "")
        return report(case, started, result, {"draft": draft}, [
            ("sending", re.search(r"env[ií]|mand", final, re.I)), ("report", re.search(r"informe|reporte", final, re.I)),
            ("tomorrow", re.search(r"mañana", final, re.I)), ("meeting", re.search(r"reuni[oó]n", final, re.I)),
            ("3", "3" in final)])
    if case == "french-plain":
        # Ordinary single-pass translation into a non-Japanese language, review off.
        text = "The fermenter is clean. Please start the next batch on Monday."
        params = {"text": text, "sourceLanguage": "en", "targetLanguage": "fr", "translator": args.provider,
                  "reviewTranslation": False, "customContext": ""}
        started = time.monotonic()
        with_prefs = preferences("")
        original = qt.request_preferences
        qt.request_preferences = lambda _params: dict(with_prefs)
        try: result = qt.translate(params)
        finally: qt.request_preferences = original
        final = (result.get("data") or {}).get("translation", "")
        return report(case, started, result, None, [("monday", re.search(r"lundi", final, re.I)),
                      ("batch", re.search(r"lot|brassin", final, re.I)), ("not_reviewed", "reviewed" not in (result.get("data") or {}))])


passed = all([run(case) for case in (CASES if args.case == "all" else (args.case,))])
sys.exit(0 if passed else 1)
