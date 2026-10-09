#!/usr/bin/env bash
set -euo pipefail

# Build the bounded Klang Valley road data used by routing/build-time tools.
# The source extract is intentionally not copied to Flutter or deployed to
# Railway.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-"$ROOT/malaysia-singapore-brunei-261008.osm.pbf"}"
OUT="$ROOT/data/osm"

if ! command -v osmium >/dev/null 2>&1; then
  echo "osmium is required: https://osmcode.org/osmium-tool/" >&2
  exit 1
fi
if [[ ! -f "$SOURCE" ]]; then
  echo "OSM source extract not found: $SOURCE" >&2
  exit 1
fi

mkdir -p "$OUT"

# Klang Valley bounds: west,south,east,north.
osmium extract \
  -b 101.20,2.70,101.95,3.45 \
  "$SOURCE" \
  -o "$OUT/klang-valley.osm.pbf" \
  --overwrite

# Keep roads usable by buses and cars. Pedestrian-only ways are deliberately
# excluded from this artifact; they belong in a separate walking graph.
osmium tags-filter \
  "$OUT/klang-valley.osm.pbf" \
  'w/highway=motorway,trunk,primary,secondary,tertiary,unclassified,residential,living_street,service,road,construction' \
  -o "$OUT/klang-valley-bus-roads.osm.pbf" \
  --overwrite

osmium export \
  "$OUT/klang-valley-bus-roads.osm.pbf" \
  -o "$OUT/klang-valley-bus-roads.geojson" \
  --overwrite

echo "Built:"
ls -lh \
  "$OUT/klang-valley.osm.pbf" \
  "$OUT/klang-valley-bus-roads.osm.pbf" \
  "$OUT/klang-valley-bus-roads.geojson"
