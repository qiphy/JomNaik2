"""Scheduled GTFS departures from the generated Klang Valley timetable bundle."""

from __future__ import annotations

import json
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

_BUNDLE: dict[str, Any] | None = None
_MALAYSIA = ZoneInfo("Asia/Kuala_Lumpur")


def _bundle_path() -> Path:
    candidates = (
        Path(__file__).parent / "data" / "raptor_klang_valley.json",
        Path(__file__).parent.parent / "jomnaik" / "assets" / "offline" / "raptor_klang_valley.json",
    )
    for path in candidates:
        if path.is_file():
            return path
    raise FileNotFoundError("No generated Klang Valley timetable bundle was found")


def _load_bundle() -> dict[str, Any]:
    global _BUNDLE
    if _BUNDLE is None:
        with _bundle_path().open(encoding="utf-8") as stream:
            _BUNDLE = json.load(stream)
    return _BUNDLE


def _candidate_stop_ids(bundle: dict[str, Any], stop_id: str) -> set[str]:
    stops = bundle.get("stops", {})
    if stop_id in stops:
        return {stop_id}
    return {
        key
        for key in stops
        if key.rsplit(":", 1)[-1].casefold() == stop_id.casefold()
    }


def _service_active(
    bundle: dict[str, Any], service_id: str, date: datetime
) -> bool:
    calendar = bundle.get("calendars", {}).get(service_id)
    if not isinstance(calendar, list) or len(calendar) < 9:
        return False
    first = datetime.strptime(str(calendar[7]), "%Y%m%d").date()
    last = datetime.strptime(str(calendar[8]), "%Y%m%d").date()
    if not first <= date.date() <= last:
        return False
    return calendar[date.weekday()] is True


def departures_for_stop(
    stop_id: str, *, limit: int = 6, now: datetime | None = None
) -> dict[str, Any]:
    bundle = _load_bundle()
    local_now = (now or datetime.now(_MALAYSIA)).astimezone(_MALAYSIA)
    matching_stops = _candidate_stop_ids(bundle, stop_id)
    if not matching_stops:
        return {"stop_id": stop_id, "departures": [], "source": "GTFS static timetable"}

    routes = bundle.get("routes", {})
    departures: list[dict[str, Any]] = []
    # Include the next active service day when today's final departure has
    # already passed. This keeps the station panel useful overnight and for
    # stops with only a small number of scheduled services.
    for day_offset in range(7):
        service_day = local_now + timedelta(days=day_offset)
        day_start = service_day.replace(hour=0, minute=0, second=0, microsecond=0)
        for trip in bundle.get("trips", []):
            if not isinstance(trip, list) or len(trip) < 5:
                continue
            service_id = trip[2]
            if not _service_active(bundle, service_id, service_day):
                continue
            route_id = trip[1]
            route = routes.get(route_id, [])
            calls = trip[4]
            if not isinstance(calls, list):
                continue
            for call in calls:
                if (
                    not isinstance(call, list)
                    or len(call) < 3
                    or call[0] not in matching_stops
                ):
                    continue
                seconds = call[2]
                if not isinstance(seconds, (int, float)):
                    continue
                departure = day_start + timedelta(seconds=int(seconds))
                if departure < local_now:
                    continue
                route_name = route[0] if isinstance(route, list) and route else route_id
                terminal = route[1] if isinstance(route, list) and len(route) > 1 else ""
                departures.append(
                    {
                        "route": str(route_name),
                        "time": departure.strftime("%H:%M"),
                        "timestamp": int(departure.timestamp() * 1000),
                        "is_estimated": False,
                        "terminal": str(terminal),
                    }
                )
                break
        if len(departures) >= limit:
            break

    departures.sort(key=lambda item: item["timestamp"])
    return {
        "stop_id": stop_id,
        "departures": departures[: max(1, min(limit, 20))],
        "source": "GTFS static timetable",
        "generated_at": datetime.now(_MALAYSIA).isoformat(),
    }
