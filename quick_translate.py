#!/usr/bin/env python3
"""NDJSON helper for Shaun Quick Translate; standard library only."""
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

MAX_CHARS = 5000
MAX_RESPONSE_BYTES = 1024 * 1024
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
    "shortcuts": DEFAULT_SHORTCUTS,
    "showBarIcon": True,
    "showHotkeys": True,
}
with Path(__file__).with_name("languages.json").open(encoding="utf-8") as language_file:
    LANGUAGE_CODES = {row[0] for row in json.load(language_file)}
with Path(__file__).with_name("manifest.json").open(encoding="utf-8") as manifest_file:
    PLUGIN_VERSION = json.load(manifest_file)["version"]


def default_preferences():
    """Return a fresh preference object; callers may safely modify it."""
    return {
        "sourceLanguage": DEFAULTS["sourceLanguage"],
        "targetLanguage": DEFAULTS["targetLanguage"],
        "shortcuts": dict(DEFAULT_SHORTCUTS),
        "showBarIcon": DEFAULTS["showBarIcon"],
        "showHotkeys": DEFAULTS["showHotkeys"],
    }

def reply(data=None, error=None):
    return {"ok": error is None, **({"data": data} if error is None else {"error": error})}

def fail(code, message):
    return reply(error={"code": code, "message": message})

def state_path():
    root = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(root, "omarchy", "quick-translate", "preferences.json")

def preferences_get():
    try:
        with open(state_path(), encoding="utf-8") as f:
            raw = json.load(f)
        if not isinstance(raw, dict): raise ValueError("not an object")
        result = default_preferences()
        for key in ("sourceLanguage", "targetLanguage"):
            if raw.get(key) in LANGUAGE_CODES: result[key] = raw[key]
        result["shortcuts"] = normalize_shortcuts(raw.get("shortcuts"))
        if isinstance(raw.get("showBarIcon"), bool): result["showBarIcon"] = raw["showBarIcon"]
        if isinstance(raw.get("showHotkeys"), bool): result["showHotkeys"] = raw["showHotkeys"]
        return reply(result)
    except FileNotFoundError:
        return reply(default_preferences())
    except (OSError, ValueError, json.JSONDecodeError):
        # Corrupt state is deliberately non-fatal: start from safe defaults.
        return reply(default_preferences())

def shortcut_error(value):
    if not isinstance(value, str) or not value or len(value) > 64:
        return "Choose a valid shortcut for every action."
    if value == "Ctrl+Shift+U": return "Ctrl+Shift+U is reserved for Unicode input. Choose another shortcut."
    if value in {"Ctrl+?", "Ctrl+Shift+?", "Ctrl+Shift+/"}: return "Ctrl+? opens Setup. Choose another shortcut."
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
    value = {
        "sourceLanguage": params.get("sourceLanguage", current["sourceLanguage"]),
        "targetLanguage": params.get("targetLanguage", current["targetLanguage"]),
        "shortcuts": dict(current["shortcuts"]),
        "showBarIcon": params.get("showBarIcon", current["showBarIcon"]),
        "showHotkeys": params.get("showHotkeys", current["showHotkeys"]),
    }
    if "shortcuts" in params and not isinstance(params["shortcuts"], dict):
        return fail("invalid_shortcut", "Choose a valid shortcut for every action.")
    if isinstance(params.get("shortcuts"), dict):
        value["shortcuts"].update(params["shortcuts"])
    if value["sourceLanguage"] not in LANGUAGE_CODES or value["targetLanguage"] not in LANGUAGE_CODES:
        return fail("invalid_language", "Choose a language from the catalogue.")
    if not isinstance(value["showBarIcon"], bool):
        return fail("invalid_preference", "Choose whether to show the menu bar icon.")
    if not isinstance(value["showHotkeys"], bool):
        return fail("invalid_preference", "Choose whether to show shortcut hints.")
    shortcut_message = next((shortcut_error(shortcut) for shortcut in value["shortcuts"].values() if shortcut_error(shortcut)), None)
    if shortcut_message:
        return fail("reserved_shortcut", shortcut_message)
    if set(value["shortcuts"]) != set(DEFAULT_SHORTCUTS):
        return fail("invalid_shortcut", "Choose a valid shortcut for every action.")
    if len(set(value["shortcuts"].values())) != len(value["shortcuts"]):
        return fail("duplicate_shortcut", "Each action needs a different shortcut.")
    path = state_path(); directory = os.path.dirname(path)
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
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
        return reply(value)
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

def translate(params):
    text = params.get("text")
    source = params.get("sourceLanguage")
    target = params.get("targetLanguage")
    if not isinstance(text, str) or not text.strip(): return fail("blank_input", "Enter text to translate.")
    if len(text) > MAX_CHARS: return fail("input_too_long", "Text must be 5,000 characters or fewer.")
    if source not in LANGUAGE_CODES or target not in LANGUAGE_CODES: return fail("invalid_language", "Choose a language from the catalogue.")
    if source == target: return reply({"translation": text})
    query = urllib.parse.urlencode({"client":"gtx", "sl":source, "tl":target, "dt":"t"})
    body = urllib.parse.urlencode({"q":text}).encode("utf-8")
    request = urllib.request.Request("https://translate.googleapis.com/translate_a/single?" + query,
                                     data=body,
                                     headers={
                                         "Content-Type": "application/x-www-form-urlencoded",
                                         "User-Agent": f"shaun.quick-translate/{PLUGIN_VERSION}"
                                     })
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return reply({"translation": read_google_response(response)})
    except urllib.error.HTTPError as exc:
        if exc.code == 429: return fail("rate_limited", "Google is rate-limiting requests. Try again shortly.")
        return fail("http_error", "Google returned HTTP %s." % exc.code)
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, TimeoutError): return fail("timeout", "The translation request timed out.")
        return fail("offline", "Could not reach Google. Check your connection.")
    except TimeoutError: return fail("timeout", "The translation request timed out.")
    except (UnicodeDecodeError, ValueError): return fail("malformed_response", "Google returned an unexpected response.")

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

def handle(request):
    if not isinstance(request, dict): return fail("invalid_request", "Request must be an object.")
    operation = request.get("operation"); params = request.get("params", {})
    if not isinstance(params, dict): return fail("invalid_request", "Request parameters must be an object.")
    if operation == "preferences.get": return preferences_get()
    if operation == "preferences.set": return preferences_set(params)
    if operation == "preferences.resetShortcuts": return preferences_set({"shortcuts": DEFAULT_SHORTCUTS})
    if operation == "translate": return translate(params)
    if operation == "copy": return copy_text(params)
    return fail("unknown_operation", "Unknown operation.")

def main():
    line = sys.stdin.readline()
    try: response = handle(json.loads(line))
    except json.JSONDecodeError: response = fail("invalid_json", "Request was not valid JSON.")
    print(json.dumps(response, ensure_ascii=False), flush=True)

if __name__ == "__main__": main()
