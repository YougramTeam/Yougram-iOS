#!/usr/bin/env python3
"""Write the Make.py build configuration for CI.

Starts from build-system/yougram-configuration.json (Yougram's bundle id, and the team id
the placeholder profiles in build-system/yougram-codesigning are made for) and swaps in
Yougram's own Telegram API credentials from the YOUGRAM_API_ID / YOUGRAM_API_HASH secrets
when they are set.
"""
import json
import os
import sys

out_path = sys.argv[1]
with open("build-system/yougram-configuration.json") as f:
    config = json.load(f)

api_id = os.environ.get("API_ID", "").strip()
api_hash = os.environ.get("API_HASH", "").strip()
if api_id and api_hash:
    config["api_id"] = api_id
    config["api_hash"] = api_hash
    print("Using the API credentials from the YOUGRAM_API_ID / YOUGRAM_API_HASH secrets.")
else:
    print("::warning title=Telegram API credentials::YOUGRAM_API_ID / YOUGRAM_API_HASH are not set, "
          "so this build uses the official Telegram app's api_id. Telegram's API terms require a client "
          "to use its own; get one at https://my.telegram.org/apps and add both as repository secrets.")

with open(out_path, "w") as f:
    json.dump(config, f, indent=2)
