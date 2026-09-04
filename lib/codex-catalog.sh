#!/usr/bin/env bash
# Codex model catalog helper. The Codex CLI keeps the LIVE server catalog for this account in
# ${CODEX_HOME:-$HOME/.codex}/models_cache.json and refreshes it on every run. The catalog bundled into
# the binary (`codex debug models --bundled`) is NOT an availability signal: it lists models the account
# cannot use (observed: gpt-6-astra, codex-cli 0.153.2).

codex_catalog_file() { printf '%s/models_cache.json\n' "${CODEX_HOME:-$HOME/.codex}"; }

# codex_catalog_probe <slug> -> exactly three lines, never a non-zero exit:
#   state=present|absent|unknown
#   efforts=<comma-joined supported_reasoning_levels[].effort, or empty>
#   fast=1|0        (1 when additional_speed_tiers contains "fast")
# unknown when CC_ORCH_CODEX_CATALOG_CHECK=0, the file is missing/unreadable, python3 is missing, the JSON
# does not parse, or models[] is missing/empty. absent only when models[] parsed non-empty without <slug>.
codex_catalog_probe() {
  local catalog slug
  catalog="$(codex_catalog_file)"
  slug="$1"

  if [ "${CC_ORCH_CODEX_CATALOG_CHECK:-1}" = 0 ] || ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' 'state=unknown' 'efforts=' 'fast=0'
    return 0
  fi

  if ! python3 - "$catalog" "$slug" <<'PY'
import json
import sys

catalog, slug = sys.argv[1:]

try:
    with open(catalog, encoding="utf-8") as handle:
        payload = json.load(handle)
    models = payload.get("models")
    if not isinstance(models, list) or not models:
        raise ValueError("missing or empty models list")

    model = next(
        (item for item in models if isinstance(item, dict) and item.get("slug") == slug),
        None,
    )
    if model is None:
        print("state=absent")
        print("efforts=")
        print("fast=0")
    else:
        levels = model.get("supported_reasoning_levels")
        if not isinstance(levels, list):
            levels = []
        efforts = [
            level["effort"]
            for level in levels
            if isinstance(level, dict) and isinstance(level.get("effort"), str)
        ]
        speed_tiers = model.get("additional_speed_tiers")
        if not isinstance(speed_tiers, list):
            speed_tiers = []
        print("state=present")
        print("efforts=" + ",".join(efforts))
        print("fast=" + ("1" if "fast" in speed_tiers else "0"))
except Exception:
    print("state=unknown")
    print("efforts=")
    print("fast=0")
PY
  then
    printf '%s\n' 'state=unknown' 'efforts=' 'fast=0'
  fi
  return 0
}
