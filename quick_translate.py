#!/usr/bin/env python3
"""NDJSON helper for Shaun Quick Translate; standard library only."""
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

MAX_CHARS = 5000
MAX_RESPONSE_BYTES = 1024 * 1024
DEFAULTS = {"sourceLanguage": "en", "targetLanguage": "ja"}
LANGUAGE_CODES = {
    "en", "ja", "es", "fr", "de", "it", "pt", "nl", "pl", "ru", "uk",
    "zh-CN", "zh-TW", "ko", "ar", "hi", "id", "tr", "vi", "th", "sv",
    "da", "no", "fi", "cs", "el", "he", "hu", "ro", "bg", "ca", "tl"
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
        result = dict(DEFAULTS)
        for key in result:
            if raw.get(key) in LANGUAGE_CODES: result[key] = raw[key]
        return reply(result)
    except FileNotFoundError:
        return reply(dict(DEFAULTS))
    except (OSError, ValueError, json.JSONDecodeError):
        # Corrupt state is deliberately non-fatal: start from safe defaults.
        return reply(dict(DEFAULTS))

def preferences_set(params):
    value = {key: params.get(key) for key in DEFAULTS}
    if any(value[key] not in LANGUAGE_CODES for key in value):
        return fail("invalid_language", "Choose a language from the catalogue.")
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
                                         "User-Agent": "shaun.quick-translate/0.1"
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
    if operation == "translate": return translate(params)
    if operation == "copy": return copy_text(params)
    return fail("unknown_operation", "Unknown operation.")

def main():
    line = sys.stdin.readline()
    try: response = handle(json.loads(line))
    except json.JSONDecodeError: response = fail("invalid_json", "Request was not valid JSON.")
    print(json.dumps(response, ensure_ascii=False), flush=True)

if __name__ == "__main__": main()
