#!/usr/bin/env python3
"""NDJSON helper for Shaun Quick Translate; standard library only."""
import json
import os
import re
import subprocess
import sys
import tempfile
import hashlib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from translation_prompt import translation_messages
from review_validation import UNCHANGED, protected_literals, translation_findings, required_terminology, interpret_review

MAX_CHARS = 5000
MAX_RESPONSE_BYTES = 1024 * 1024
LEGACY_MAX_CONTEXTS = 20
LEGACY_MAX_CONTEXT_NAME_LENGTH = 64
MAX_PROFILE_INSTRUCTION_LENGTH = 11000
MAX_PROFILES = 20
MAX_PROFILE_NAME_LENGTH = 64
WEB_USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36"
EDITING_KEYS = {"Space", "Enter", "Tab", "Esc", "Backspace", "Delete"}
DEFAULT_SHORTCUTS = {
    "copy": "Ctrl+Y",
    "copyAll": "Ctrl+Shift+Y",
    "switch": "Ctrl+U",
    "clear": "Ctrl+Shift+K",
    "translate": "Ctrl+Enter",
    "undo": "Ctrl+Z",
}
DEFAULTS = {
    "sourceLanguage": "en",
    "targetLanguage": "ja",
    "translator": "google",
    "shortcuts": DEFAULT_SHORTCUTS,
    "showBarIcon": True,
    "showHotkeys": True,
    "reviewTranslation": False,
    "openaiApiKeyConfigured": False,
    "openaiReasoningEffort": "minimal",
    "activeProfileId": "",
    "profiles": [],
}
OPENAI_REASONING_EFFORTS = {"minimal", "low", "medium", "high"}
with Path(__file__).with_name("languages.json").open(encoding="utf-8") as language_file:
    LANGUAGES = json.load(language_file)
    LANGUAGE_CODES = {row[0] for row in LANGUAGES}
    LANGUAGE_NAMES = {row[0]: row[1] for row in LANGUAGES}
with Path(__file__).with_name("manifest.json").open(encoding="utf-8") as manifest_file:
    PLUGIN_VERSION = json.load(manifest_file)["version"]

# These are public web endpoints, not supported commercial APIs.  Keep the
# capability data local so changing engines immediately updates the UI without
# a preliminary network request.
APERTIUM_PAIRS = {
    ("en", "es"), ("es", "en"), ("en", "ca"), ("ca", "en"),
    ("es", "ca"), ("ca", "es"), ("en", "fr"), ("fr", "en"),
    ("es", "fr"), ("fr", "es"), ("en", "pt"), ("pt", "en"),
}
REVERSO_CODES = {
    "en": "eng", "es": "spa", "fr": "fra", "de": "ger", "it": "ita",
    "pt": "por", "nl": "dut", "pl": "pol", "ru": "rus", "uk": "ukr",
    "zh-CN": "chi", "ja": "jpn", "ko": "kor", "ar": "ara", "hi": "hin",
    "tr": "tur", "he": "heb", "ro": "rum", "hu": "hun", "cs": "cze",
    "el": "gre", "th": "tha", "sv": "swe", "da": "dan",
}
BING_CODES = {"zh-CN": "zh-Hans", "zh-TW": "zh-Hant", "no": "nb"}
REVERSO_PAIRS = sorted((source, target) for source in REVERSO_CODES for target in REVERSO_CODES if source != target)
# An empty "pairs" list means the engine has no restriction of its own beyond
# LANGUAGE_CODES membership (see pair_supported()); the UI treats an empty
# list as "use the full language catalogue" rather than "no options".
ENGINE_METADATA = {
    "google": {"name": "Google", "maxChars": 5000, "pairs": []},
    "apertium": {"name": "Apertium", "maxChars": 1000, "pairs": sorted(APERTIUM_PAIRS)},
    "bing": {"name": "Bing", "maxChars": 1000, "pairs": []},
    "reverso": {"name": "Reverso", "maxChars": 2000, "pairs": REVERSO_PAIRS},
    "ollama": {"name": "Ollama Local", "maxChars": 5000, "pairs": []},
    "openai": {"name": "OpenAI", "maxChars": 5000, "pairs": []},
}
OLLAMA_MODEL = "gemma3"
# Translation should be faithful and repeatable, so keep sampling close to the top choice.
OLLAMA_TEMPERATURE = 0.1
OPENAI_MODEL = "gpt-5-mini"
# A fidelity audit needs more reasoning than the fast first pass. Keep local
# jobs local; never silently send an Ollama user's messages to a cloud provider.
OPENAI_REVIEW_MODEL = "gpt-5"
OLLAMA_REVIEW_MODEL = OLLAMA_MODEL
REVIEW_OUTPUT_TOKENS = 16384


def review_diagnostic(event, **metadata):
    """Opt-in developer metadata on stderr only. Never log text, keys or hashes of text."""
    if os.environ.get("QUICK_TRANSLATE_DEV_DIAGNOSTICS") == "1":
        print(json.dumps({"component": "quick-translate-review", "event": event, **metadata}), file=sys.stderr, flush=True)

class TranslationError(Exception):
    def __init__(self, code, message): self.code, self.message = code, message


def default_preferences():
    """Return a fresh preference object; callers may safely modify it."""
    return {
        "sourceLanguage": DEFAULTS["sourceLanguage"],
        "targetLanguage": DEFAULTS["targetLanguage"],
        "translator": DEFAULTS["translator"],
        "shortcuts": dict(DEFAULT_SHORTCUTS),
        "showBarIcon": DEFAULTS["showBarIcon"],
        "showHotkeys": DEFAULTS["showHotkeys"],
        "reviewTranslation": DEFAULTS["reviewTranslation"],
        "openaiApiKeyConfigured": DEFAULTS["openaiApiKeyConfigured"],
        "openaiReasoningEffort": DEFAULTS["openaiReasoningEffort"],
        "activeProfileId": "",
        "profiles": [],
    }

def reply(data=None, error=None):
    return {"ok": error is None, **({"data": data} if error is None else {"error": error})}

def fail(code, message):
    return reply(error={"code": code, "message": message})

def state_path():
    root = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(root, "omarchy", "quick-translate", "preferences.json")

def read_stored_preferences():
    try:
        with open(state_path(), encoding="utf-8") as f:
            raw = json.load(f)
        if not isinstance(raw, dict): raise ValueError("not an object")
        return raw
    except (FileNotFoundError, OSError, ValueError, json.JSONDecodeError):
        return {}

def read_preferences():
    return migrate_contexts_to_profiles(read_stored_preferences())

def legacy_contexts(raw):
    if not isinstance(raw, list): return []
    contexts, ids, names = [], set(), set()
    for context in raw[:LEGACY_MAX_CONTEXTS]:
        if not isinstance(context, dict): continue
        context_id, name, instruction = context.get("id"), context.get("name"), context.get("instruction")
        if (not isinstance(context_id, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", context_id)
                or context_id in ids or not isinstance(name, str) or not isinstance(instruction, str)):
            continue
        name, instruction = name.strip(), instruction.strip()
        normalized_name = name.casefold()
        if (not name or not instruction or normalized_name in names
                or len(name) > LEGACY_MAX_CONTEXT_NAME_LENGTH or len(instruction) > MAX_PROFILE_INSTRUCTION_LENGTH):
            continue
        contexts.append({"id": context_id, "name": name, "instruction": instruction})
        ids.add(context_id); names.add(normalized_name)
    return contexts

def unique_profile_name(name, profiles):
    taken = {str(profile.get("name", "")).strip().casefold() for profile in profiles}
    candidate, suffix = name, 2
    while candidate.casefold() in taken:
        tail = " (%d)" % suffix
        candidate = name[:MAX_PROFILE_NAME_LENGTH - len(tail)] + tail
        suffix += 1
    return candidate

def migrate_contexts_to_profiles(raw):
    """Fold saved translation contexts into profiles; a no-op for migrated preferences."""
    if "translationContexts" not in raw and "selectedContextId" not in raw:
        return raw
    migrated = {key: value for key, value in raw.items() if key not in ("translationContexts", "selectedContextId")}
    contexts = legacy_contexts(raw.get("translationContexts"))
    instructions = {context["id"]: context["instruction"] for context in contexts}
    selected = raw.get("selectedContextId")
    profiles, used, active = [], set(), ""
    for profile in raw.get("profiles") if isinstance(raw.get("profiles"), list) else []:
        if not isinstance(profile, dict): continue
        context_id = profile.get("selectedContextId", "")
        upgraded = {key: value for key, value in profile.items() if key != "selectedContextId"}
        upgraded.setdefault("instruction", instructions.get(context_id, ""))
        profiles.append(upgraded)
        if context_id in instructions:
            used.add(context_id)
            matches_settings = all(profile.get(key) == raw.get(key) for key in ("translator", "sourceLanguage", "targetLanguage"))
            if context_id == selected and (not active or matches_settings):
                active = profile.get("id", "")
    source = raw.get("sourceLanguage") if raw.get("sourceLanguage") in LANGUAGE_CODES else DEFAULTS["sourceLanguage"]
    target = raw.get("targetLanguage") if raw.get("targetLanguage") in LANGUAGE_CODES else DEFAULTS["targetLanguage"]
    translator = raw.get("translator") if raw.get("translator") in ("ollama", "openai") else "ollama"
    for context in contexts:
        if context["id"] in used or len(profiles) >= MAX_PROFILES: continue
        profile_id = "p-" + context["id"][:62]
        profiles.append({"id": profile_id, "name": unique_profile_name(context["name"], profiles), "translator": translator,
                         "sourceLanguage": source, "targetLanguage": target, "instruction": context["instruction"]})
        if context["id"] == selected: active = profile_id
    migrated["profiles"] = profiles
    migrated["activeProfileId"] = active
    return migrated

def backup_legacy_preferences(raw, directory):
    """Keep the pre-merge data, minus the API key, the first time migrated preferences are saved."""
    if "translationContexts" not in raw and "selectedContextId" not in raw:
        return
    path = os.path.join(directory, "preferences.before-profile-merge.json")
    if os.path.exists(path):
        return
    backup = {key: value for key, value in raw.items() if key != "openaiApiKey"}
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(backup, f, ensure_ascii=False, indent=2)
        f.write("\n"); f.flush(); os.fsync(f.fileno())

def normalize_profiles(raw):
    if not isinstance(raw, list): return []
    profiles, ids, names = [], set(), set()
    for profile in raw[:MAX_PROFILES]:
        if not isinstance(profile, dict): continue
        profile_id, name = profile.get("id"), profile.get("name")
        translator = profile.get("translator")
        source, target = profile.get("sourceLanguage"), profile.get("targetLanguage")
        instruction = profile.get("instruction", "")
        if (not isinstance(profile_id, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", profile_id)
                or profile_id in ids or not isinstance(name, str) or translator not in ENGINE_METADATA
                or source not in LANGUAGE_CODES or target not in LANGUAGE_CODES
                or not isinstance(instruction, str)
                or len(instruction.strip()) > MAX_PROFILE_INSTRUCTION_LENGTH
                or not pair_supported(translator, source, target)):
            continue
        name = name.strip()
        normalized_name = name.casefold()
        if not name or len(name) > MAX_PROFILE_NAME_LENGTH or normalized_name in names:
            continue
        profiles.append({"id": profile_id, "name": name, "translator": translator,
                         "sourceLanguage": source, "targetLanguage": target,
                         "instruction": instruction.strip()})
        ids.add(profile_id); names.add(normalized_name)
    return profiles

def profile_error(raw):
    if not isinstance(raw, list) or len(raw) > MAX_PROFILES:
        return "Keep at most %d profiles." % MAX_PROFILES
    for profile in raw:
        if isinstance(profile, dict) and isinstance(profile.get("instruction"), str):
            if len(profile["instruction"].strip()) > MAX_PROFILE_INSTRUCTION_LENGTH:
                return "Keep profile instructions to at most %s characters." % format(MAX_PROFILE_INSTRUCTION_LENGTH, ",")
    if len(normalize_profiles(raw)) != len(raw):
        return "Each profile needs a unique name and valid translation settings."
    return None

def preferences_get():
    # read_preferences() already swallows file-read/parse errors and returns
    # {}, so any corrupt or missing state file falls back to safe defaults
    # below without needing a second layer of exception handling here.
    raw = read_preferences()
    result = default_preferences()
    for key in ("sourceLanguage", "targetLanguage"):
        if raw.get(key) in LANGUAGE_CODES: result[key] = raw[key]
    if raw.get("translator") in ENGINE_METADATA: result["translator"] = raw["translator"]
    result["shortcuts"] = normalize_shortcuts(raw.get("shortcuts"))
    if isinstance(raw.get("showBarIcon"), bool): result["showBarIcon"] = raw["showBarIcon"]
    if isinstance(raw.get("showHotkeys"), bool): result["showHotkeys"] = raw["showHotkeys"]
    if isinstance(raw.get("reviewTranslation"), bool): result["reviewTranslation"] = raw["reviewTranslation"]
    if raw.get("openaiReasoningEffort") in OPENAI_REASONING_EFFORTS:
        result["openaiReasoningEffort"] = raw["openaiReasoningEffort"]
    result["profiles"] = normalize_profiles(raw.get("profiles"))
    if raw.get("activeProfileId") in {profile["id"] for profile in result["profiles"]}:
        result["activeProfileId"] = raw["activeProfileId"]
    result["openaiApiKeyConfigured"] = isinstance(raw.get("openaiApiKey"), str) and bool(raw["openaiApiKey"])
    return reply(result)

def shortcut_error(value):
    if not isinstance(value, str) or not value or len(value) > 64:
        return "Choose a valid shortcut for every action."
    if value == "Ctrl+Shift+U": return "Ctrl+Shift+U is reserved for Unicode input. Choose another shortcut."
    if value in {"Ctrl+?", "Ctrl+Shift+?", "Ctrl+Shift+/"}: return "Ctrl+? opens Setup. Choose another shortcut."
    if value == "Ctrl+Shift+P": return "Ctrl+Shift+P opens Profiles. Choose another shortcut."
    if value in {"Ctrl+J", "Ctrl+K"}: return "Ctrl+J and Ctrl+K navigate Setup. Choose another shortcut."
    parts = value.split("+")
    modifiers, key = parts[:-1], parts[-1]
    function_key = bool(re.fullmatch(r"F(?:[1-9]|[12][0-9]|3[0-5])", key))
    if "Meta" in modifiers: return "Super shortcuts are managed globally. Choose Ctrl or Alt instead."
    if (not key or len(set(modifiers)) != len(modifiers)
            or any(modifier not in {"Ctrl", "Alt", "Shift", "Meta"} for modifier in modifiers)
            or (not function_key and not ("Ctrl" in modifiers or "Alt" in modifiers))
            or not (key in EDITING_KEYS or re.fullmatch(r"[A-Z0-9]", key)
                    or function_key)):
        return "Use Ctrl, Alt, or an F-key shortcut to avoid typing and navigation conflicts."
    return None

def valid_shortcut(value):
    return not shortcut_error(value)


def normalize_shortcuts(raw):
    """Only expose a complete, valid, non-conflicting shortcut map."""
    if not isinstance(raw, dict):
        return dict(DEFAULT_SHORTCUTS)
    shortcuts = dict(DEFAULT_SHORTCUTS)
    for key in DEFAULT_SHORTCUTS:
        if key in raw:
            shortcuts[key] = raw[key]
    if (set(raw) != set(DEFAULT_SHORTCUTS) or
            not all(valid_shortcut(value) for value in shortcuts.values()) or
            len(set(shortcuts.values())) != len(shortcuts)):
        return dict(DEFAULT_SHORTCUTS)
    return shortcuts

def preferences_set(params):
    current = preferences_get()["data"]
    raw = read_preferences()
    existing_openai_key = raw.get("openaiApiKey", "") if isinstance(raw.get("openaiApiKey"), str) else ""
    if params.get("clearOpenaiApiKey") is True:
        openai_api_key = ""
    elif "openaiApiKey" in params:
        openai_api_key = params["openaiApiKey"]
    else:
        openai_api_key = existing_openai_key
    value = {
        "sourceLanguage": params.get("sourceLanguage", current["sourceLanguage"]),
        "targetLanguage": params.get("targetLanguage", current["targetLanguage"]),
        "translator": params.get("translator", current["translator"]),
        "shortcuts": dict(current["shortcuts"]),
        "showBarIcon": params.get("showBarIcon", current["showBarIcon"]),
        "showHotkeys": params.get("showHotkeys", current["showHotkeys"]),
        "reviewTranslation": params.get("reviewTranslation", current["reviewTranslation"]),
        "openaiReasoningEffort": params.get("openaiReasoningEffort", current["openaiReasoningEffort"]),
        "activeProfileId": params.get("activeProfileId", current["activeProfileId"]),
        "profiles": params.get("profiles", current["profiles"]),
        "openaiApiKey": openai_api_key,
    }
    if "shortcuts" in params and not isinstance(params["shortcuts"], dict):
        return fail("invalid_shortcut", "Choose a valid shortcut for every action.")
    if isinstance(params.get("shortcuts"), dict):
        value["shortcuts"].update(params["shortcuts"])
    if value["sourceLanguage"] not in LANGUAGE_CODES or value["targetLanguage"] not in LANGUAGE_CODES:
        return fail("invalid_language", "Choose a language from the catalogue.")
    if value["translator"] not in ENGINE_METADATA:
        return fail("invalid_translator", "Choose a supported translator.")
    if not pair_supported(value["translator"], value["sourceLanguage"], value["targetLanguage"]):
        return fail("unsupported_language_pair", "That translator does not support the selected language pair.")
    if not isinstance(value["showBarIcon"], bool):
        return fail("invalid_preference", "Choose whether to show the menu bar icon.")
    if not isinstance(value["showHotkeys"], bool):
        return fail("invalid_preference", "Choose whether to show shortcut hints.")
    if not isinstance(value["reviewTranslation"], bool):
        return fail("invalid_preference", "Choose whether to review AI translations.")
    if value["openaiReasoningEffort"] not in OPENAI_REASONING_EFFORTS:
        return fail("invalid_preference", "Choose a valid OpenAI reasoning effort.")
    profiles_error = profile_error(value["profiles"])
    if profiles_error:
        return fail("invalid_profile", profiles_error)
    value["profiles"] = normalize_profiles(value["profiles"])
    profile_ids = {profile["id"] for profile in value["profiles"]}
    if "profiles" in params and "activeProfileId" not in params and value["activeProfileId"] not in profile_ids:
        value["activeProfileId"] = ""
    if not isinstance(value["activeProfileId"], str) or (value["activeProfileId"] and value["activeProfileId"] not in profile_ids):
        return fail("invalid_profile", "Choose a saved profile.")
    if not isinstance(value["openaiApiKey"], str) or len(value["openaiApiKey"]) > 512:
        return fail("invalid_api_key", "Enter a valid OpenAI API key.")
    shortcut_message = None
    for shortcut in value["shortcuts"].values():
        shortcut_message = shortcut_error(shortcut)
        if shortcut_message:
            break
    if shortcut_message:
        return fail("reserved_shortcut", shortcut_message)
    if set(value["shortcuts"]) != set(DEFAULT_SHORTCUTS):
        return fail("invalid_shortcut", "Choose a valid shortcut for every action.")
    if len(set(value["shortcuts"].values())) != len(value["shortcuts"]):
        return fail("duplicate_shortcut", "Each action needs a different shortcut.")
    path = state_path(); directory = os.path.dirname(path)
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        backup_legacy_preferences(read_stored_preferences(), directory)
        fd, temporary = tempfile.mkstemp(prefix=".preferences-", dir=directory)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(value, f, ensure_ascii=False, separators=(",", ":"))
                f.write("\n"); f.flush(); os.fsync(f.fileno())
            os.replace(temporary, path)
            os.chmod(path, 0o600)
        except Exception:
            try: os.unlink(temporary)
            except OSError: pass
            raise
        response = dict(value)
        response.pop("openaiApiKey")
        response["openaiApiKeyConfigured"] = bool(value["openaiApiKey"])
        return reply(response)
    except OSError:
        return fail("state_write", "Could not save language preferences.")

def parse_google_response(payload):
    try:
        rows = json.loads(payload)
        translated = "".join(str(row[0]) for row in rows[0] if row and row[0] is not None)
    except (TypeError, ValueError, IndexError, KeyError, json.JSONDecodeError):
        raise ValueError("Google returned an unexpected response.")
    if not translated: raise ValueError("Google returned an empty translation.")
    return translated

def read_google_response(response):
    payload = response.read(MAX_RESPONSE_BYTES + 1)
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ValueError("Google returned an unexpectedly large response.")
    return parse_google_response(payload.decode("utf-8"))

def pair_supported(translator, source, target):
    if source == target: return True
    if translator == "apertium": return (source, target) in APERTIUM_PAIRS
    if translator == "reverso": return source in REVERSO_CODES and target in REVERSO_CODES
    return source in LANGUAGE_CODES and target in LANGUAGE_CODES

def engine_data():
    result = [{"id": identifier, "name": metadata["name"], "maxChars": metadata["maxChars"],
               "pairs": [list(pair) for pair in metadata["pairs"]]}
              for identifier, metadata in ENGINE_METADATA.items()]
    return reply(result)

def read_json(response):
    payload = response.read(MAX_RESPONSE_BYTES + 1)
    if len(payload) > MAX_RESPONSE_BYTES: raise ValueError("response too large")
    try: return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError): raise ValueError("malformed response")

def active_profile_instruction(preferences):
    active_id = preferences.get("activeProfileId")
    for profile in normalize_profiles(preferences.get("profiles")):
        if profile["id"] == active_id: return profile["instruction"]
    return ""

def provider_messages(text, source, target, context, instructions, instruction_role):
    """A review pass brings its own instructions; every other request uses the shared layers."""
    if instructions:
        return [{"role": instruction_role, "content": instructions}, {"role": "user", "content": text}]
    return translation_messages(LANGUAGE_NAMES[source], LANGUAGE_NAMES[target], context, text, instruction_role)

def request_preferences(params):
    """Freeze provider configuration and context for both passes of this job."""
    preferences = read_preferences()
    preferences["requestContext"] = params.get("customContext", active_profile_instruction(preferences))
    if "openaiReasoningEffort" in params:
        preferences["openaiReasoningEffort"] = params["openaiReasoningEffort"]
    return preferences

def review_message(text, draft, source, target, context):
    """Plain-text review request with the FULL original, draft and context, unmodified."""
    def bullets(rows): return "\n".join("- " + row for row in rows) if rows else "None"
    terminology = ["%s → %s" % pair for pair in required_terminology(text, source, target).items()]
    findings = [note for _, note in translation_findings(text, draft, source, target)]
    return ("Source language: %s (%s)\nTarget language: %s (%s)\n\n"
            "Custom translation instructions:\n<custom_instructions>\n%s\n</custom_instructions>\n\n"
            "Required terminology (source term → required %s term):\n%s\n\n"
            "Protected text (copy exactly):\n%s\n\n"
            "Automatic checks found these problems in the draft:\n%s\n\n"
            "<original>\n%s\n</original>\n\n<draft>\n%s\n</draft>\n\n"
            "Reply with exactly %s if the draft has no missing information, changed meaning, invented details "
            "or incorrect terminology. Otherwise reply with only the complete corrected %s translation."
            % (LANGUAGE_NAMES[source], source, LANGUAGE_NAMES[target], target, context or "None",
               LANGUAGE_NAMES[target], bullets(terminology), bullets(protected_literals(text)), bullets(findings),
               text, draft, UNCHANGED, LANGUAGE_NAMES[target]))

def review_sections(message):
    """Extract the embedded texts; used to verify requests without logging them."""
    def section(name):
        match = re.search(r"<%s>\n(.*)\n</%s>" % (name, name), message, re.S)
        return match.group(1) if match else None
    return {"original": section("original"), "draft": section("draft"), "context": section("custom_instructions")}

def translate_google(text, source, target):
    query = urllib.parse.urlencode({"client":"gtx", "sl":source, "tl":target, "dt":"t"})
    body = urllib.parse.urlencode({"q":text}).encode("utf-8")
    request = urllib.request.Request("https://translate.googleapis.com/translate_a/single?" + query,
                                     data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(request, timeout=15) as response:
        return read_google_response(response)

def translate_apertium(text, source, target):
    codes = {"en": "eng", "es": "spa", "ca": "cat", "fr": "fra", "pt": "por"}
    query = urllib.parse.urlencode({"langpair": codes[source] + "|" + codes[target], "q": text, "markUnknown": "no"})
    request = urllib.request.Request("https://www.apertium.org/apy/translate?" + query)
    with urllib.request.urlopen(request, timeout=15) as response:
        payload = read_json(response)
    translated = payload.get("responseData", {}).get("translatedText")
    if not isinstance(translated, str) or not translated: raise ValueError("empty translation")
    return translated

def bing_credentials():
    request = urllib.request.Request("https://www.bing.com/translator", headers={"User-Agent": f"shaun.quick-translate/{PLUGIN_VERSION}"})
    with urllib.request.urlopen(request, timeout=15) as response:
        raw = response.read(MAX_RESPONSE_BYTES + 1)
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ValueError("Bing returned an unexpectedly large response.")
    page = raw.decode("utf-8")
    ig = re.search(r'IG:"([^"]+)"', page)
    iid = re.search(r'data-iid="([^"]+)"', page)
    params = re.search(r'params_AbusePreventionHelper\s*=\s*\[(-?[0-9]+),"([^"]+)"(?:,[^\]]+)?\]', page)
    if not (ig and iid and params): raise ValueError("missing Bing credentials")
    return ig.group(1), iid.group(1), params.group(1), params.group(2)

def translate_bing(text, source, target):
    ig, iid, key, token = bing_credentials()
    form = urllib.parse.urlencode({"fromLang": BING_CODES.get(source, source), "to": BING_CODES.get(target, target),
                                   "text": text, "token": token, "key": key}).encode("utf-8")
    request = urllib.request.Request("https://www.bing.com/ttranslatev3?" + urllib.parse.urlencode({"IG": ig, "IID": iid}), data=form,
                                     headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": WEB_USER_AGENT})
    with urllib.request.urlopen(request, timeout=15) as response:
        payload = read_json(response)
    translated = payload[0]["translations"][0]["text"]
    if not isinstance(translated, str) or not translated: raise ValueError("empty translation")
    return translated

def translate_reverso(text, source, target):
    body = json.dumps({"format": "text", "from": REVERSO_CODES[source], "to": REVERSO_CODES[target], "input": text,
                       "options": {"sentenceSplitter": "true", "origin": "translation.web", "contextResults": "true", "languageDetection": "false"}}).encode("utf-8")
    request = urllib.request.Request("https://api.reverso.net/translate/v1/translation", data=body,
                                     headers={"Content-Type": "application/json", "User-Agent": f"shaun.quick-translate/{PLUGIN_VERSION}"})
    with urllib.request.urlopen(request, timeout=15) as response:
        payload = read_json(response)
    translated = payload.get("translation")
    if isinstance(translated, list): translated = "".join(str(part) for part in translated)
    if not isinstance(translated, str) or not translated: raise ValueError("empty translation")
    return translated

def translate_ollama(text, source, target, progress=None, preferences=None, instructions=None):
    preferences = read_preferences() if preferences is None else preferences
    context = preferences.get("requestContext", active_profile_instruction(preferences))
    body = {"model": OLLAMA_MODEL, "stream": progress is not None, "options": {"num_ctx": 16384, "temperature": OLLAMA_TEMPERATURE},
            "messages": provider_messages(text, source, target, context, instructions, "system")}
    if preferences.get("reviewTranslation") is True or instructions is not None:
        body.update({"truncate": False, "shift": False})
    if instructions is not None:
        body["model"] = OLLAMA_REVIEW_MODEL
        body["options"].update({"num_predict": REVIEW_OUTPUT_TOKENS,
                                "num_ctx": 32768})
        # Ollama applies its model tokenizer and chat template to check capacity.
        # UTF-8 bytes and JSON-schema size are not a token count. Keep truncation
        # disabled and let the engine reject actual overflow without slicing text.
    body = json.dumps(body).encode("utf-8")
    request = urllib.request.Request("http://localhost:11434/api/chat", data=body,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=300) as response:
        if progress is None:
            payload = read_json(response)
            if instructions is not None:
                review_diagnostic("provider_response", provider="ollama", model=payload.get("model") if isinstance(payload, dict) else None,
                    prompt_tokens=payload.get("prompt_eval_count") if isinstance(payload, dict) else None,
                    output_tokens=payload.get("eval_count") if isinstance(payload, dict) else None)
            if not isinstance(payload, dict) or payload.get("error") or payload.get("done") is False:
                raise ValueError("invalid translation response")
            if instructions is not None and payload.get("done") is not True:
                raise ValueError("incomplete review response")
            if payload.get("done_reason") == "length":
                raise TranslationError("incomplete_translation", "Ollama reached its output limit. Try translating a smaller section.")
            message = payload.get("message", {})
            if not isinstance(message, dict): raise ValueError("invalid translation message")
            translated = message.get("content")
        else:
            parts, received, finished = [], 0, False
            while True:
                line = response.readline(MAX_RESPONSE_BYTES - received + 1)
                if not line: break
                received += len(line)
                if received > MAX_RESPONSE_BYTES: raise ValueError("response too large")
                if not line.strip(): continue
                payload = json.loads(line)
                if not isinstance(payload, dict) or payload.get("error"):
                    raise ValueError("invalid translation stream")
                message = payload.get("message", {})
                if not isinstance(message, dict): raise ValueError("invalid translation message")
                chunk = message.get("content", "")
                if not isinstance(chunk, str): raise ValueError("invalid translation chunk")
                if chunk:
                    parts.append(chunk)
                    progress({"event": "progress", "delta": chunk})
                if payload.get("done") is True:
                    if instructions is not None:
                        review_diagnostic("provider_response", provider="ollama", model=payload.get("model"),
                            prompt_tokens=payload.get("prompt_eval_count"), output_tokens=payload.get("eval_count"))
                    if payload.get("done_reason") == "length":
                        raise TranslationError("incomplete_translation", "Ollama reached its output limit. Try translating a smaller section.")
                    finished = True
                    break
            if not finished: raise ValueError("incomplete translation stream")
            translated = "".join(parts)
    if not isinstance(translated, str) or not translated.strip(): raise ValueError("empty translation")
    return translated

def translate_openai(text, source, target, preferences=None, instructions=None):
    preferences = read_preferences() if preferences is None else preferences
    api_key = preferences.get("openaiApiKey")
    if not isinstance(api_key, str) or not api_key:
        raise TranslationError("openai_api_key_missing", "Add your OpenAI API key in Setup before using OpenAI.")
    reasoning_effort = preferences.get("openaiReasoningEffort")
    if reasoning_effort not in OPENAI_REASONING_EFFORTS: reasoning_effort = DEFAULTS["openaiReasoningEffort"]
    context = preferences.get("requestContext", active_profile_instruction(preferences))
    body = {"model": OPENAI_MODEL, "reasoning": {"effort": reasoning_effort}, "truncation": "disabled",
            "input": provider_messages(text, source, target, context, instructions, "developer")}
    if instructions is not None:
        body.update({"model": OPENAI_REVIEW_MODEL, "reasoning": {"effort": "medium"},
                     "max_output_tokens": REVIEW_OUTPUT_TOKENS, "store": False})
    body = json.dumps(body).encode("utf-8")
    request = urllib.request.Request("https://api.openai.com/v1/responses", data=body,
                                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + api_key})
    with urllib.request.urlopen(request, timeout=300 if instructions is not None else 60) as response:
        payload = read_json(response)
    if not isinstance(payload, dict): raise ValueError("invalid translation response")
    if instructions is not None:
        review_diagnostic("provider_response", provider="openai", model=payload.get("model"))
    if payload.get("status", None if instructions is not None else "completed") != "completed" or payload.get("error"):
        raise TranslationError("incomplete_translation", "OpenAI returned an incomplete translation. Try translating a smaller section.")
    translated = openai_output_text(payload)
    if not isinstance(translated, str) or not translated.strip(): raise ValueError("empty translation")
    return translated

def openai_output_text(payload):
    """Extract text from the raw Responses API output array.

    ``output_text`` is an SDK convenience property, whereas HTTP JSON contains
    message items with ``output_text`` content parts.
    """
    direct = payload.get("output_text")
    if isinstance(direct, str): return direct
    parts = []
    output = payload.get("output")
    if not isinstance(output, list): return ""
    for item in output:
        if not isinstance(item, dict): continue
        content = item.get("content")
        if not isinstance(content, list): continue
        for part in content:
            if isinstance(part, dict) and part.get("type") == "output_text" and isinstance(part.get("text"), str):
                parts.append(part["text"])
    return "".join(parts)

def openai_error_code(error):
    """Return OpenAI's machine-readable error code without exposing its body."""
    try:
        raw = error.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES: return ""
        payload = json.loads(raw.decode("utf-8"))
        detail = payload.get("error", {})
        if not isinstance(detail, dict): return ""
        code = detail.get("code") or detail.get("type")
        return code if isinstance(code, str) else ""
    except (OSError, UnicodeDecodeError, ValueError, AttributeError):
        return ""

def ollama_context_error(error):
    """Recognize the engine's structured overflow code without exposing its body."""
    try:
        with error:
            value = read_json(error)
        for _ in range(4):
            if isinstance(value, str): value = json.loads(value)
            if not isinstance(value, dict): return False
            if value.get("type") == "exceed_context_size_error" or value.get("code") == "context_length_exceeded":
                return True
            value = value.get("error")
    except (OSError, ValueError, TypeError):
        pass
    return False


def translate_once(params, progress=None, preferences=None, review=False):
    text = params.get("text")
    source = params.get("sourceLanguage")
    target = params.get("targetLanguage")
    translator = params.get("translator", "google")
    if not isinstance(text, str) or not text.strip(): return fail("blank_input", "Enter text to translate.")
    if translator not in ENGINE_METADATA: return fail("invalid_translator", "Choose a supported translator.")
    max_chars = ENGINE_METADATA[translator]["maxChars"]
    if len(text) > max_chars: return fail("input_too_long", "%s accepts %s characters or fewer." % (ENGINE_METADATA[translator]["name"], f"{max_chars:,}"))
    if source not in LANGUAGE_CODES or target not in LANGUAGE_CODES: return fail("invalid_language", "Choose a language from the catalogue.")
    if not pair_supported(translator, source, target): return fail("unsupported_language_pair", "That translator does not support the selected language pair.")
    if source == target and not review: return reply({"translation": text})
    # Trailing whitespace makes small local models drop words from short input.
    text = text.strip()
    preferences = request_preferences(params) if preferences is None else preferences
    context = preferences.get("requestContext", "")
    if not isinstance(context, str) or len(context) > MAX_PROFILE_INSTRUCTION_LENGTH:
        return fail("invalid_context", "Keep profile instructions to at most 11,000 characters.")
    try:
        translators = {"google": translate_google, "apertium": translate_apertium,
                       "bing": translate_bing, "reverso": translate_reverso,
                       "ollama": translate_ollama, "openai": translate_openai}
        instructions = None
        if review:
            if translator not in {"ollama", "openai"}:
                return fail("invalid_translator", "Translation review requires Ollama or OpenAI.")
            draft = params.get("draft")
            if not isinstance(draft, str) or not draft.strip():
                return fail("invalid_draft", "Keep the complete draft to retry its review.")
            instructions = Path(__file__).with_name("review_prompt.txt").read_text(encoding="utf-8").strip()
            if not instructions:
                raise TranslationError("review_prompt", "The translation review prompt is empty.")
            text = review_message(text, draft, source, target, context)
            sections = review_sections(text)
            review_diagnostic("request", provider=translator,
                model=OLLAMA_REVIEW_MODEL if translator == "ollama" else OPENAI_REVIEW_MODEL,
                source_language=source, target_language=target,
                source_characters=len(params["text"]), draft_characters=len(draft), context_characters=len(context),
                input_characters=len(text), source_matches=sections["original"] == params["text"],
                draft_matches=sections["draft"] == draft, context_matches=sections["context"] == (context or "None"),
                draft_check_failures=len(translation_findings(params["text"], draft, source, target)),
                instruction_file="review_prompt.txt", instruction_sha256=hashlib.sha256(instructions.encode()).hexdigest(),
                instruction_characters=len(instructions), output_token_budget=REVIEW_OUTPUT_TOKENS,
                reasoning_effort="medium" if translator == "openai" else None,
                input_truncation=False, local_context_tokens=32768 if translator == "ollama" else None)
        if translator not in {"ollama", "openai"}:
            return reply({"translation": translators[translator](text, source, target)})
        if translator == "ollama":
            output = translate_ollama(text, source, target, progress, preferences, instructions)
        else:
            output = translate_openai(text, source, target, preferences, instructions)
        if not review: return reply({"translation": output})
        # One review request. Any invalid, ambiguous or failing result is a
        # visible failure; it is never patched, retried silently, or shown.
        try:
            output, changed = interpret_review(output, params["text"], draft, source, target)
        except ValueError as exc:
            review_diagnostic("rejected", reason=str(exc))
            message = "The reviewer's answer failed validation (%s). The result has not been accepted." % str(exc)
            raise TranslationError("invalid_review", message) from None
        review_diagnostic("accepted", output_characters=len(output), changed=changed)
        return reply({"translation": output, "reviewChanged": changed})
    except TranslationError as exc:
        return fail(exc.code, exc.message)
    except urllib.error.HTTPError as exc:
        name = ENGINE_METADATA[translator]["name"]
        if translator == "ollama" and exc.code in {400, 413} and ollama_context_error(exc):
            return fail("review_context_limit" if review else "context_limit", "The local model reported that the complete input exceeds its context window. No input was truncated.")
        if translator == "ollama" and exc.code == 404:
            if review:
                return fail("ollama_model_missing", "The local review model is not installed. Run: ollama pull " + OLLAMA_REVIEW_MODEL + ". Review has not completed.")
            return fail("ollama_model_missing", "Ollama is running, but Gemma 3 is not installed. Run: ollama pull gemma3")
        if translator == "openai" and exc.code in {401, 403}:
            return fail("openai_auth", "OpenAI rejected the API key. Update it in Setup.")
        if translator == "openai" and exc.code == 429:
            if openai_error_code(exc) in {"insufficient_quota", "billing_hard_limit_reached"}:
                return fail("openai_quota", "OpenAI API quota is unavailable. Add billing or credits, then try again.")
            return fail("openai_rate_limited", "OpenAI rate limit reached. Wait a moment, then try again.")
        if exc.code == 429: return fail("rate_limited", "%s is rate-limiting requests. Try again shortly." % name)
        return fail("http_error", "%s returned HTTP %s." % (name, exc.code))
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, TimeoutError): return fail("timeout", "The translation request timed out.")
        if translator == "ollama": return fail("ollama_unavailable", "Ollama is not running locally. Install Ollama, run it, then run: ollama pull gemma3")
        return fail("offline", "Could not reach %s. Check your connection." % ENGINE_METADATA[translator]["name"])
    except TimeoutError: return fail("timeout", "The translation request timed out.")
    except (UnicodeDecodeError, ValueError, KeyError, IndexError, TypeError): return fail("malformed_response", "%s returned an unexpected response." % ENGINE_METADATA[translator]["name"])
    except OSError: return fail("provider_error", "Could not complete the AI request. Check the service and review prompt file.")

def review_progress(progress):
    """Report activity without exposing draft or unfinished reviewed text to the result box."""
    if progress is None: return None
    characters = 0
    def report(event):
        nonlocal characters
        if event.get("event") == "stage":
            characters = 0
            progress(event)
            return
        characters += len(event.get("delta", ""))
        progress({"event": "progress", "characters": characters})
    return report

def review_translation(params, progress=None, preferences=None):
    preferences = request_preferences(params) if preferences is None else preferences
    if progress: progress({"event": "stage", "stage": "reviewing"})
    result = translate_once(params, review_progress(progress), preferences, review=True)
    if not result["ok"]: review_diagnostic("failed", code=result["error"]["code"])
    if result["ok"]:
        result["data"]["reviewed"] = True
        return result
    failed = fail("review_failed", "Translation succeeded, but review failed: " + result["error"]["message"] + " Retry review without translating again.")
    failed["error"]["cause"] = result["error"]["code"]
    # In-memory retry data only. Never include provider keys or save source/draft to disk.
    failed["reviewRequest"] = {key: params[key] for key in (
        "text", "draft", "translator", "sourceLanguage", "targetLanguage", "customContext",
        "selectedContextId", "openaiReasoningEffort", "reviewTranslation") if key in params}
    return failed

def translate(params, progress=None):
    preferences = request_preferences(params)
    enabled = params.get("reviewTranslation", preferences.get("reviewTranslation") is True)
    if not isinstance(enabled, bool): return fail("invalid_preference", "Choose whether to review AI translations.")
    preferences["reviewTranslation"] = enabled
    if not enabled or params.get("translator", "google") not in {"ollama", "openai"} or params.get("sourceLanguage") == params.get("targetLanguage"):
        return translate_once(params, progress, preferences)
    draft_result = translate_once(params, review_progress(progress), preferences)
    if not draft_result["ok"]: return draft_result
    draft = draft_result["data"]["translation"]
    review_request = dict(params, draft=draft, customContext=preferences["requestContext"], reviewTranslation=True,
                          selectedContextId=params.get("selectedContextId", preferences.get("selectedContextId", "")),
                          openaiReasoningEffort=preferences.get("openaiReasoningEffort", DEFAULTS["openaiReasoningEffort"]))
    if progress: progress({"event": "draft", "draft": draft})
    return review_translation(review_request, progress, preferences)

def copy_text(params):
    text = params.get("text")
    if not isinstance(text, str) or not text: return fail("blank_clipboard", "There is nothing to copy yet.")
    try:
        # wl-copy forks a clipboard-owner process. Do not capture its standard
        # streams: the child inherits those pipes and makes communicate() wait
        # until the clipboard changes, even though the copy already succeeded.
        result = subprocess.run(
            ["wl-copy"], input=text, text=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5
        )
        if result.returncode != 0: raise OSError()
        return reply({"copied": True})
    except (OSError, subprocess.SubprocessError):
        return fail("clipboard", "Could not copy to the clipboard.")

def handle(request, progress=None):
    if not isinstance(request, dict): return fail("invalid_request", "Request must be an object.")
    operation = request.get("operation"); params = request.get("params", {})
    if not isinstance(params, dict): return fail("invalid_request", "Request parameters must be an object.")
    if operation == "preferences.get": return preferences_get()
    if operation == "preferences.set": return preferences_set(params)
    if operation == "preferences.resetShortcuts": return preferences_set({"shortcuts": DEFAULT_SHORTCUTS})
    if operation == "engines.get": return engine_data()
    if operation == "translate": return translate(params, progress)
    if operation == "review": return review_translation(params, progress)
    if operation == "copy": return copy_text(params)
    return fail("unknown_operation", "Unknown operation.")

def main():
    line = sys.stdin.readline()
    def emit_progress(event):
        print(json.dumps(event, ensure_ascii=False), flush=True)
    try: response = handle(json.loads(line), progress=emit_progress)
    except json.JSONDecodeError: response = fail("invalid_json", "Request was not valid JSON.")
    print(json.dumps(response, ensure_ascii=False), flush=True)

if __name__ == "__main__": main()
