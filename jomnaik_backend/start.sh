#!/usr/bin/env bash
# Run the optional live-context API. Static transit routing is performed on
# device, so this process has no MOTIS/GTFS runtime dependency.
set -euo pipefail
exec uvicorn lite_main:app --host 0.0.0.0 --port "${PORT:-8000}"
