"""Synthetic provider used only by the isolated QML regression test."""
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(os.environ["REVIEW_REAL_HELPER"]).parent))
spec = importlib.util.spec_from_file_location("real_helper", os.environ["REVIEW_REAL_HELPER"])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
request = json.loads(sys.stdin.readline())
params = request.get("params", {})
operation = request.get("operation")
if operation == "copy":
    with Path(os.environ["REVIEW_TEST_LOG"]).open("a") as log:
        log.write("copy:" + params["text"] + "\n")
    print(json.dumps(helper.reply({"copied": True})), flush=True)
    sys.exit(0)
if operation in {"translate", "review"}:
    with Path(os.environ["REVIEW_TEST_LOG"]).open("a") as log:
        log.write(operation + ":" + params["text"] + "\n")


class SlowResponse(io.BytesIO):
    def __init__(self, text, hold=False):
        chunks = [{"message": {"content": text}, "done": False}, {"done": True}]
        super().__init__(b"".join((json.dumps(chunk) + "\n").encode() for chunk in chunks))
        self.hold = hold
        self.reads = 0

    def readline(self, size=-1):
        self.reads += 1
        time.sleep(60 if self.hold and self.reads > 1 else 0.2)
        return super().readline(size)


def urlopen(http_request, **kwargs):
    body = json.loads(http_request.data)
    reviewing = body["messages"][0]["content"].startswith("You are a translation accuracy checker.")
    if reviewing:
        original = helper.review_sections(body["messages"][1]["content"])["original"]
        if original == "failure" and operation != "review": raise TimeoutError()
        hold = original in {"cancelreview", "timeoutreview"} and operation != "review"
        return SlowResponse("FINAL REVIEW", hold)
    return SlowResponse("PRIVATE DRAFT", params["text"] == "canceltranslation")


helper.urllib.request.urlopen = urlopen
result = helper.handle(request, progress=lambda event: print(json.dumps(event), flush=True))
print(json.dumps(result), flush=True)
