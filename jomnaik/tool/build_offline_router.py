#!/usr/bin/env python3
"""Build the compact static-GTFS bundle consumed by OfflineRaptorRouter.

Run from ``jomnaik`` after refreshing the backend GTFS archives:

  python3 tool/build_offline_router.py

The app deliberately receives only static schedules, stop data, and short
transfer links.  Live vehicle positions, traffic, weather, and reports remain
server features.
"""

from __future__ import annotations

import csv
import json
import math
import zipfile
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT.parent / "jomnaik_backend"
SOURCES = {
    "rapid-kl-bus": BACKEND / "data/gtfs/rapid-kl-bus.zip",
    "rapid-kl-bus-mrtfeeder": ROOT / "assets/gtfs_rapid_bus_mrtfeeder.zip",
    "rapid-kl-rail": BACKEND / "data/gtfs/rapid-kl-rail.zip",
    "ktmb": BACKEND / "data/gtfs/ktmb.zip",
}
OUT = ROOT / "assets/offline/raptor_klang_valley.json"
ACCESS = BACKEND / "motis/data/station_access.json"


def read_rows(archive: zipfile.ZipFile, name: str) -> list[dict[str, str]]:
    if name not in archive.namelist():
        return []
    with archive.open(name) as raw:
        return list(csv.DictReader((line.decode("utf-8-sig") for line in raw)))


def seconds(value: str) -> int:
    hour, minute, second = (int(part) for part in value.split(":"))
    return hour * 3600 + minute * 60 + second


def meters(a: tuple[float, float], b: tuple[float, float]) -> float:
    radius = 6_371_000
    y = math.radians(b[0] - a[0])
    x = math.radians(b[1] - a[1])
    value = math.sin(y / 2) ** 2 + math.cos(math.radians(a[0])) * math.cos(math.radians(b[0])) * math.sin(x / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(value))


def main() -> None:
    stops: dict[str, list] = {}
    routes: dict[str, list] = {}
    trips: list[list] = []
    calendars: dict[str, list] = {}
    exceptions: dict[str, dict[str, int]] = defaultdict(dict)
    frequencies: dict[str, list[list[int]]] = defaultdict(list)

    for feed, path in SOURCES.items():
        if not path.exists():
            raise SystemExit(f"Missing GTFS archive: {path}")
        with zipfile.ZipFile(path) as archive:
            for row in read_rows(archive, "stops.txt"):
                try:
                    stops[f"{feed}:{row['stop_id']}"] = [row.get("stop_name") or "Transit stop", float(row["stop_lat"]), float(row["stop_lon"])]
                except (KeyError, ValueError):
                    continue
            for row in read_rows(archive, "routes.txt"):
                routes[f"{feed}:{row['route_id']}"] = [row.get("route_short_name") or row.get("route_long_name") or "Service", row.get("route_long_name") or "", int(row.get("route_type") or 3)]
            for row in read_rows(archive, "calendar.txt"):
                calendars[f"{feed}:{row['service_id']}"] = [row.get(day) == "1" for day in ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")] + [row.get("start_date", "00000000"), row.get("end_date", "99999999")]
            for row in read_rows(archive, "calendar_dates.txt"):
                exceptions[f"{feed}:{row['service_id']}"][row.get("date", "")] = int(row.get("exception_type") or 0)
            stop_times: dict[str, list[tuple[int, str, int, int]]] = defaultdict(list)
            for row in read_rows(archive, "stop_times.txt"):
                try:
                    stop_times[row["trip_id"]].append((int(row.get("stop_sequence") or 0), f"{feed}:{row['stop_id']}", seconds(row["arrival_time"]), seconds(row["departure_time"])))
                except (KeyError, ValueError):
                    continue
            for row in read_rows(archive, "frequencies.txt"):
                try:
                    frequencies[f"{feed}:{row['trip_id']}"].append([seconds(row["start_time"]), seconds(row["end_time"]), int(row["headway_secs"])])
                except (KeyError, ValueError):
                    continue
            for row in read_rows(archive, "trips.txt"):
                calls = sorted(stop_times.get(row.get("trip_id", ""), []))
                if len(calls) >= 2:
                    trip_id = f"{feed}:{row['trip_id']}"
                    trips.append([trip_id, f"{feed}:{row['route_id']}", f"{feed}:{row['service_id']}", row.get("trip_headsign") or "", [[stop, arrival, departure] for _, stop, arrival, departure in calls], frequencies.get(trip_id, [])])

    # Nearby stops make ordinary platform changes possible without loading an
    # OSM road graph.  Verified station connectors override these estimates.
    transfer_map: dict[str, dict[str, int]] = defaultdict(dict)
    indexed = list(stops.items())
    for index, (left_id, left) in enumerate(indexed):
        for right_id, right in indexed[index + 1 :]:
            distance = meters((left[1], left[2]), (right[1], right[2]))
            if distance <= 90:
                duration = max(60, round(distance / 1.2))
                transfer_map[left_id][right_id] = duration
                transfer_map[right_id][left_id] = duration
    if ACCESS.exists():
        data = json.loads(ACCESS.read_text())
        for connector in data.get("connectors", {}).values():
            if not isinstance(connector, dict):
                continue
            # Connector keys use public feed:stop IDs; retain only known stops.
        for key, connector in data.get("connectors", {}).items():
            if not isinstance(connector, dict) or "|" not in key:
                continue
            left, right = key.split("|", 1)
            if left in stops and right in stops:
                duration = max(30, round(float(connector.get("distanceMeters") or 0) / 1.2))
                transfer_map[left][right] = duration
                transfer_map[right][left] = duration

    document = {
        "version": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "stops": stops,
        "routes": routes,
        "trips": trips,
        "calendars": calendars,
        "exceptions": exceptions,
        "transfers": {stop: [[target, duration] for target, duration in links.items()] for stop, links in transfer_map.items()},
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(document, separators=(",", ":")))
    print(f"Wrote {OUT}: {len(stops)} stops, {len(trips)} trips, {sum(len(v) for v in transfer_map.values())} transfers")


if __name__ == "__main__":
    main()
