"""Small optional live-context API for the on-device jomnaik router.

RAPTOR routing now runs in Flutter.  This service deliberately contains no
MOTIS binary, GTFS import, scheduler, or local database.  It is safe to host
on a small Railway/Render service and is non-essential to route availability.
"""
from __future__ import annotations

import os
import time
import logging
from datetime import datetime, timedelta, timezone
from math import asin, atan2, cos, radians, sin, sqrt
from typing import Any
from zoneinfo import ZoneInfo
from urllib.parse import urlparse

import httpx
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from tomtom import TomTomTrafficError, fetch_congestion, fetch_route_estimate
from realtime import fetch_vehicle_positions
from weather import fetch_current_weather
from gtfs_schedule import _load_bundle, departures_for_stop

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("jomnaik")


def _env_first(*names: str) -> str:
    for name in names:
        value = os.getenv(name, "").strip()
        if value:
            return value
    return ""


def _supabase_url() -> str:
    """Normalize a Supabase project URL supplied through deployment variables."""
    value = _env_first("SUPABASE_URL").rstrip("/")
    if value and "://" not in value:
        value = f"https://{value}"
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return ""
    return value


SUPABASE_URL = _supabase_url()
SUPABASE_ANON_KEY = _env_first("SUPABASE_ANON_KEY", "SUPABASE_PUBLISHABLE_KEY")
SUPABASE_SERVICE_ROLE_KEY = _env_first(
    "SUPABASE_SERVICE_ROLE_KEY",
    "SUPABASE_SECRET_KEY",
)
_MALAYSIA = ZoneInfo("Asia/Kuala_Lumpur")
_weather_cache: dict[tuple[float, float], tuple[float, dict[str, Any]]] = {}
_traffic_cache: dict[tuple[float, float], tuple[float, dict[str, Any]]] = {}
_traffic_route_cache: dict[tuple[str, str, str], tuple[float, dict[str, Any]]] = {}
_offline_manifest_cache: tuple[float, dict[str, str]] | None = None
_vehicle_cache: tuple[float, dict[str, Any]] | None = None
_places_cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}


def _tomtom_api_key() -> str:
    """Read the current deployment value instead of freezing import-time config."""
    value = os.getenv("TOMTOM_API_KEY", "").strip()
    if value.lower() in {"replace_me", "changeme", "your_api_key"}:
        return ""
    return value


class PresenceReport(BaseModel):
    station_id: str = Field(min_length=1, max_length=255)
    station_name: str = Field(min_length=1, max_length=255)
    observed_at: str | None = None


class IncidentReport(BaseModel):
    station_id: str = Field(min_length=1, max_length=255)
    station_name: str = Field(min_length=1, max_length=255)
    station_lat: float = Field(ge=-90, le=90)
    station_lon: float = Field(ge=-180, le=180)
    report_type: str = Field(min_length=1, max_length=100)
    target_type: str = Field(pattern="^(bus|station)$")
    service_route: str | None = Field(default=None, max_length=100)
    comment: str | None = Field(default=None, max_length=2000)
    reported_at: str | None = None


app = FastAPI(title="jomnaik Live Context API", version="1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[item.strip() for item in os.getenv("CORS_ORIGINS", "*").split(",")],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(Exception)
async def _unhandled_api_error(request: Request, error: Exception) -> JSONResponse:
    """Keep browser clients from seeing an opaque CORS error for server faults."""
    logger.exception("Unhandled API error for %s %s", request.method, request.url.path)
    return JSONResponse(
        status_code=500,
        content={"detail": "The backend could not process this request."},
        headers={"Access-Control-Allow-Origin": "*"},
    )


async def _insert(table: str, body: dict[str, Any]) -> None:
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        raise HTTPException(503, "Reporting storage is not configured")
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.post(
            f"{SUPABASE_URL}/rest/v1/{table}",
            headers={
                "apikey": SUPABASE_SERVICE_ROLE_KEY,
                "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
                "Content-Type": "application/json",
                "Prefer": "return=minimal",
            },
                json=body,
            )
    except httpx.HTTPError as error:
        logger.exception("Could not reach Supabase table %s", table)
        raise HTTPException(503, "Reporting storage is temporarily unavailable") from error
    if response.status_code not in {200, 201, 204}:
        logger.error(
            "Supabase rejected write to %s with status %s: %s",
            table,
            response.status_code,
            response.text[:300],
        )
        raise HTTPException(502, "Could not save the report")


def _distance_km(
    first_lat: float, first_lon: float, second_lat: float, second_lon: float
) -> float:
    """Great-circle distance used only to trim map vehicle results."""
    lat_delta = radians(second_lat - first_lat)
    lon_delta = radians(second_lon - first_lon)
    value = sin(lat_delta / 2) ** 2 + cos(radians(first_lat)) * cos(
        radians(second_lat)
    ) * sin(lon_delta / 2) ** 2
    return 12_742 * asin(sqrt(value))


def _bearing_degrees(
    first_lat: float, first_lon: float, second_lat: float, second_lon: float
) -> float:
    """Initial bearing from the vehicle toward a candidate stop."""
    lat1, lat2 = radians(first_lat), radians(second_lat)
    lon_delta = radians(second_lon - first_lon)
    y = sin(lon_delta) * cos(lat2)
    x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(lon_delta)
    return (atan2(y, x) * 180 / 3.141592653589793 + 360) % 360


async def _vehicle_positions() -> dict[str, Any]:
    """Fetch public GTFS-RT only when needed, sharing one short-lived cache."""
    global _vehicle_cache
    if _vehicle_cache and time.monotonic() - _vehicle_cache[0] < 25:
        return _vehicle_cache[1]
    try:
        async with httpx.AsyncClient(timeout=12) as client:
            value = await fetch_vehicle_positions(client)
    except (httpx.HTTPError, ValueError) as error:
        raise HTTPException(503, "Live vehicle data is temporarily unavailable") from error
    _vehicle_cache = (time.monotonic(), value)
    return value


@app.get("/api/health")
async def health() -> dict[str, str | bool | int]:
    logger.info("GET /api/health success")
    timetable_configured = False
    timetable_stops = 0
    timetable_trips = 0
    try:
        bundle = _load_bundle()
        timetable_configured = True
        timetable_stops = len(bundle.get("stops", {}))
        timetable_trips = len(bundle.get("trips", []))
    except (FileNotFoundError, OSError, ValueError, TypeError):
        pass
    return {
        "status": "ok",
        "routing": "on_device",
        "trafficConfigured": bool(_tomtom_api_key()),
        "reportingConfigured": bool(SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY),
        "reportingSupabaseUrlConfigured": bool(SUPABASE_URL),
        "reportingSupabaseAuthKeyConfigured": bool(SUPABASE_ANON_KEY),
        "reportingSupabaseWriteKeyConfigured": bool(SUPABASE_SERVICE_ROLE_KEY),
        "timetableConfigured": timetable_configured,
        "timetableStops": timetable_stops,
        "timetableTrips": timetable_trips,
    }


@app.get("/api/offline/manifest")
async def offline_manifest() -> dict[str, str]:
    """Return the current app timetable manifest without redeploying the API.

    The scheduled GitHub workflow updates a tiny manifest next to the bundle.
    Keeping its URL in an environment variable means a newly published bundle
    reaches devices even when the lightweight service has not been restarted.
    """
    global _offline_manifest_cache
    manifest_url = os.getenv("OFFLINE_ROUTING_MANIFEST_URL", "")
    if manifest_url:
        if _offline_manifest_cache and time.monotonic() - _offline_manifest_cache[0] < 300:
            return _offline_manifest_cache[1]
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                response = await client.get(manifest_url)
            remote = response.json()
            if (
                response.status_code == 200
                and isinstance(remote, dict)
                and isinstance(remote.get("version"), str)
                and isinstance(remote.get("downloadUrl"), str)
            ):
                value = {"version": remote["version"], "downloadUrl": remote["downloadUrl"]}
                _offline_manifest_cache = (time.monotonic(), value)
                return value
        except (httpx.HTTPError, ValueError):
            # The static variables below remain a usable, explicit fallback.
            pass
    url = os.getenv("OFFLINE_ROUTING_BUNDLE_URL", "")
    version = os.getenv("OFFLINE_ROUTING_BUNDLE_VERSION", "")
    if not url or not version:
        raise HTTPException(404, "No published offline timetable bundle")
    return {"version": version, "downloadUrl": url}


@app.get("/api/places/search")
async def places_search(
    q: str = Query(min_length=2, max_length=200),
) -> dict[str, Any]:
    """Search any mapped place in Klang Valley through Nominatim."""
    query = " ".join(q.split())
    cache_key = query.casefold()
    cached = _places_cache.get(cache_key)
    if cached and time.monotonic() - cached[0] < 60:
        return {"places": cached[1], "source": "Nominatim"}
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            response = await client.get(
                "https://nominatim.openstreetmap.org/search",
                params={
                    "q": query,
                    "format": "jsonv2",
                    "addressdetails": "1",
                    "limit": "12",
                    "countrycodes": "my",
                    "viewbox": "101.2,3.45,101.95,2.7",
                    "bounded": "1",
                },
                headers={
                    "Accept": "application/json",
                    "User-Agent": "jomnaik/1.0 (Klang Valley transit app)",
                },
            )
            response.raise_for_status()
            payload = response.json()
    except (httpx.HTTPError, ValueError) as error:
        logger.warning("Nominatim place search failed: %s", error)
        raise HTTPException(503, "Place search is temporarily unavailable") from error

    places: list[dict[str, Any]] = []
    if isinstance(payload, list):
        for item in payload:
            if not isinstance(item, dict):
                continue
            try:
                lat = float(item["lat"])
                lon = float(item["lon"])
            except (KeyError, TypeError, ValueError):
                continue
            if not (2.7 <= lat <= 3.45 and 101.2 <= lon <= 101.95):
                continue
            display_name = str(item.get("display_name") or query)
            name = str(item.get("name") or display_name.split(",", 1)[0])
            places.append(
                {
                    "name": name,
                    "address": display_name,
                    "lat": lat,
                    "lon": lon,
                    "osm_type": item.get("osm_type"),
                    "osm_id": item.get("osm_id"),
                }
            )
    _places_cache[cache_key] = (time.monotonic(), places)
    return {"places": places, "source": "Nominatim"}


@app.get("/api/gtfs/stops/{stop_id}/departures")
async def gtfs_departures(
    stop_id: str,
    limit: int = Query(default=6, ge=1, le=20),
) -> dict[str, Any]:
    """Return scheduled rail and bus departures for a GTFS stop."""
    try:
        value = departures_for_stop(stop_id, limit=limit)
    except FileNotFoundError as error:
        logger.error("GTFS timetable bundle is missing: %s", error)
        raise HTTPException(503, "GTFS timetable is not configured") from error
    except (OSError, ValueError, KeyError, TypeError) as error:
        logger.exception("GTFS timetable could not be read")
        raise HTTPException(503, "GTFS timetable is temporarily unavailable") from error
    matching_stops = {
        key
        for key in _load_bundle().get("stops", {})
        if key == stop_id or key.rsplit(":", 1)[-1].casefold() == stop_id.casefold()
    }
    is_brt_station = any(
        key.startswith("rapid-kl-rail:BRT") for key in matching_stops
    )
    if any(
        key.startswith("rapid-kl-bus:")
        or key.startswith("rapid-kl-bus-mrtfeeder:")
        for key in matching_stops
    ) or is_brt_station:
        value = await _add_live_bus_departures(value, matching_stops, limit)
    logger.info(
        "GET /api/gtfs/stops/%s/departures returned %d departures",
        stop_id,
        len(value["departures"]),
    )
    return value


async def _add_live_bus_departures(
    value: dict[str, Any], matching_stops: set[str], limit: int
) -> dict[str, Any]:
    """Add route-matched bus ETAs, including B1000 at BRT platforms."""
    bundle = _load_bundle()
    stops = bundle.get("stops", {})
    transfers = bundle.get("transfers", {})
    vehicle_stop_ids = set(matching_stops)
    is_brt_station = any(
        key.startswith("rapid-kl-rail:BRT") for key in matching_stops
    )
    if is_brt_station:
        # Static GTFS keeps BRT platforms under rapid-kl-rail:BRT* while the
        # official live vehicle feed reports these buses as route B1000.
        # Their stop IDs are linked by the transfer table.
        for station_id in matching_stops:
            for transfer in transfers.get(station_id, []):
                if (
                    isinstance(transfer, list)
                    and transfer
                    and str(transfer[0]).startswith("rapid-kl-bus:")
                ):
                    vehicle_stop_ids.add(str(transfer[0]))
    stop_points = [
        stops[key]
        for key in vehicle_stop_ids
        if isinstance(stops.get(key), list) and len(stops[key]) >= 3
    ]
    if not stop_points:
        return value
    route_ids: set[str] = set()
    route_terminals: dict[str, set[str]] = {}
    trips_by_route: dict[str, list[list[Any]]] = {}
    for trip in bundle.get("trips", []):
        if not isinstance(trip, list) or len(trip) < 5:
            continue
        calls = trip[4]
        if isinstance(calls, list) and any(
            isinstance(call, list) and call and call[0] in vehicle_stop_ids
            for call in calls
        ):
            route_id = str(trip[1])
            route_ids.add(route_id)
            trips_by_route.setdefault(route_id, []).append(trip)
            headsign = str(trip[3]).strip() if len(trip) > 3 else ""
            if headsign:
                route_terminals.setdefault(route_id, set()).add(headsign)
    try:
        live = await _vehicle_positions()
    except HTTPException:
        return value
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    estimates_by_route: dict[str, dict[str, Any]] = {}
    routes = bundle.get("routes", {})
    for vehicle in live.get("vehicles", []):
        feed = str(vehicle.get("feed", ""))
        if feed not in {"rapid-kl-bus", "rapid-kl-bus-mrtfeeder"}:
            continue
        route_id = str(vehicle.get("routeId") or "")
        route_key = route_id if ":" in route_id else next(
            (
                candidate
                for candidate in route_ids
                if candidate.rsplit(":", 1)[-1] == route_id
                or (
                    isinstance(routes.get(candidate), list)
                    and len(routes[candidate]) > 1
                    and route_id
                    in {str(routes[candidate][0]), str(routes[candidate][1])}
                )
            ),
            "",
        )
        if route_key not in route_ids:
            continue
        source_timestamp = vehicle.get("timestamp")
        source_timestamp_ms = (
            int(source_timestamp) * 1000
            if isinstance(source_timestamp, (int, float))
            and source_timestamp < 10_000_000_000
            else int(source_timestamp)
            if isinstance(source_timestamp, (int, float))
            else None
        )
        if (
            source_timestamp_ms is not None
            and now_ms - source_timestamp_ms > 120_000
        ):
            continue
        lat, lon = vehicle.get("lat"), vehicle.get("lon")
        if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)):
            continue
        nearest_stop = min(
            stop_points,
            key=lambda stop: _distance_km(
                lat, lon, float(stop[1]), float(stop[2])
            ),
        )
        distance_km = _distance_km(
            lat, lon, float(nearest_stop[1]), float(nearest_stop[2])
        )
        if distance_km > 4:
            continue
        bearing = vehicle.get("bearing")
        if (
            isinstance(bearing, (int, float))
            and distance_km > 0.1
        ):
            bearing_to_stop = _bearing_degrees(
                lat,
                lon,
                float(nearest_stop[1]),
                float(nearest_stop[2]),
            )
            difference = abs((float(bearing) - bearing_to_stop + 180) % 360 - 180)
            if difference > 90:
                continue
        speed = vehicle.get("speedMps")
        speed_mps = float(speed) if isinstance(speed, (int, float)) and speed > 2 else 8.0
        eta_seconds = max(90, round(distance_km * 1000 / speed_mps) + 60)
        route = routes.get(route_key, [])
        route_name = route[0] if isinstance(route, list) and route else route_key.rsplit(":", 1)[-1]
        if is_brt_station and route_key == "rapid-kl-bus:B1000":
            brt_route = routes.get("rapid-kl-rail:BRT", [])
            if isinstance(brt_route, list) and brt_route:
                route_name = brt_route[0]
        realtime_trip_id = str(vehicle.get("tripId") or "").casefold()
        matched_trip = next(
            (
                trip
                for trip in trips_by_route.get(route_key, [])
                if len(trip) > 3
                and realtime_trip_id
                and (
                    str(trip[0]).rsplit(":", 1)[-1].casefold().endswith(
                        realtime_trip_id
                    )
                    or realtime_trip_id.endswith(
                        str(trip[0]).rsplit(":", 1)[-1].casefold()
                    )
                )
            ),
            None,
        )
        terminal = (
            str(matched_trip[3]).strip()
            if matched_trip is not None and str(matched_trip[3]).strip()
            else next(iter(sorted(route_terminals.get(route_key, set()))), "")
        )
        estimate = {
            "route": str(route_name),
            "time": datetime.fromtimestamp(
                (now_ms + eta_seconds * 1000) / 1000, tz=timezone.utc
            ).astimezone(_MALAYSIA).strftime("%H:%M"),
            "timestamp": now_ms + eta_seconds * 1000,
            "is_estimated": True,
            "terminal": terminal,
            "source": "data.gov.my GTFS-Realtime vehicle position",
            "vehicle_id": vehicle.get("id"),
            "vehicle_timestamp": source_timestamp,
        }
        estimate_key = f"{route_key}|{terminal}"
        previous = estimates_by_route.get(estimate_key)
        if previous is None or estimate["timestamp"] < previous["timestamp"]:
            estimates_by_route[estimate_key] = estimate
    estimates = list(estimates_by_route.values())
    existing = value.get("departures", [])
    scheduled = existing if isinstance(existing, list) else []

    # For transit to buses, prioritize estimated arrival time first;
    # if no estimate is available for a service, fall back to scheduled time.
    combined = list(estimates)
    for item in scheduled:
        same_service_prediction = any(
            str(item.get("route", "")).casefold()
            == str(estimate.get("route", "")).casefold()
            and (
                not item.get("terminal")
                or not estimate.get("terminal")
                or str(item.get("terminal", "")).casefold()
                == str(estimate.get("terminal", "")).casefold()
            )
            and abs(int(item.get("timestamp", 0)) - int(estimate.get("timestamp", 0)))
            <= 300_000
            for estimate in estimates
        )
        if not same_service_prediction:
            combined.append(item)
    combined.sort(key=lambda item: item.get("timestamp", 0))

    has_estimates = bool(estimates)
    has_scheduled = any(not item.get("is_estimated") for item in combined)
    source_label = (
        "data.gov.my GTFS-Realtime and GTFS timetable"
        if has_estimates and has_scheduled
        else "data.gov.my GTFS-Realtime bus positions"
        if has_estimates
        else "GTFS static timetable"
    )
    return {
        **value,
        "departures": combined[: max(1, min(limit, 20))],
        "source": source_label,
        "realtimeBusConfigured": True,
    }


@app.get("/api/incidents/recent")
async def recent_incidents(
    limit: int = Query(default=500, ge=1, le=1000),
) -> dict[str, Any]:
    """Return recent anonymous reports for client-side route risk scoring."""
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        raise HTTPException(503, "Reporting storage is not configured")
    since = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.get(
                f"{SUPABASE_URL}/rest/v1/anonymous_incident_reports",
                headers={
                    "apikey": SUPABASE_SERVICE_ROLE_KEY,
                    "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
                },
                params={
                    "select": "station_id,station_name,station_lat,station_lon,report_type,target_type,service_route,reported_at",
                    "reported_at": f"gte.{since}",
                    "order": "reported_at.desc",
                    "limit": str(limit),
                },
            )
        if response.status_code != 200:
            raise HTTPException(502, "Could not load incident reports")
        payload = response.json()
        if not isinstance(payload, list):
            raise HTTPException(502, "Incident reports returned an invalid response")
        return {"incidents": payload, "asOf": datetime.now(timezone.utc).isoformat()}
    except httpx.HTTPError as error:
        raise HTTPException(503, "Incident reports are temporarily unavailable") from error


@app.get("/api/route")
async def route_is_local() -> None:
    raise HTTPException(503, "Routing is performed on-device")


@app.post("/api/route")
async def route_is_local_post() -> None:
    raise HTTPException(503, "Routing is performed on-device")


@app.get("/api/realtime/vehicles")
async def realtime_vehicles(
    lat: float | None = Query(default=None, ge=2.7, le=3.5),
    lon: float | None = Query(default=None, ge=101.2, le=102.1),
    radius_km: float = Query(default=8, gt=0, le=30),
) -> dict[str, Any]:
    """Return official live bus and KTM positions, optionally near a map point.

    data.gov.my updates the source every 30 seconds. Railway never keeps a
    background polling process; an active app request refreshes the shared
    cache at most once every 25 seconds.
    """
    if (lat is None) != (lon is None):
        raise HTTPException(422, "lat and lon must be supplied together")
    data = await _vehicle_positions()
    vehicles = data["vehicles"]
    if lat is not None and lon is not None:
        vehicles = [
            vehicle
            for vehicle in vehicles
            if _distance_km(lat, lon, vehicle["lat"], vehicle["lon"]) <= radius_km
        ]
    return {
        **data,
        "vehicles": vehicles,
        "cacheSeconds": 25,
        "filteredAround": ({"lat": lat, "lon": lon, "radiusKm": radius_km} if lat is not None else None),
    }


@app.get("/api/weather/klang-valley")
async def weather(
    lat: float = Query(ge=2.7, le=3.5), lon: float = Query(ge=101.2, le=102.1)
) -> dict[str, Any]:
    logger.info("GET /api/weather/klang-valley lat=%s lon=%s", lat, lon)
    key = (round(lat, 2), round(lon, 2))
    cached = _weather_cache.get(key)
    if cached and time.monotonic() - cached[0] < 120:
        return cached[1]
    try:
        async with httpx.AsyncClient(timeout=12) as client:
            value = await fetch_current_weather(client, latitude=lat, longitude=lon)
    except (httpx.HTTPError, ValueError) as error:
        logger.exception("Weather provider request failed")
        raise HTTPException(503, "Weather is temporarily unavailable") from error
    _weather_cache[key] = (time.monotonic(), value)
    logger.info("GET /api/weather/klang-valley success")
    return value


@app.get("/api/traffic/congestion")
async def traffic(
    lat: float = Query(ge=2.7, le=3.5), lon: float = Query(ge=101.2, le=102.1)
) -> dict[str, Any]:
    tomtom_api_key = _tomtom_api_key()
    if not tomtom_api_key:
        logger.warning(
            "GET /api/traffic/congestion unavailable: TOMTOM_API_KEY is not configured"
        )
        raise HTTPException(503, "Traffic is not configured")
    key = (round(lat, 3), round(lon, 3))
    cached = _traffic_cache.get(key)
    if cached and time.monotonic() - cached[0] < 60:
        return cached[1]
    try:
        async with httpx.AsyncClient(timeout=12) as client:
            value = await fetch_congestion(
                client,
                api_key=tomtom_api_key,
                latitude=lat,
                longitude=lon,
            )
    except TomTomTrafficError as error:
        logger.warning(
            "GET /api/traffic/congestion provider failure at %.6f,%.6f: %s",
            lat,
            lon,
            error,
        )
        raise HTTPException(503, str(error)) from error
    _traffic_cache[key] = (time.monotonic(), value)
    logger.info(
        "GET /api/traffic/congestion success at %.6f,%.6f",
        lat,
        lon,
    )
    return value


@app.get("/api/traffic/route")
async def traffic_route(
    from_lat: float = Query(ge=2.7, le=3.5),
    from_lon: float = Query(ge=101.2, le=102.1),
    to_lat: float = Query(ge=2.7, le=3.5),
    to_lon: float = Query(ge=101.2, le=102.1),
    depart_at: str | None = None,
) -> dict[str, Any]:
    """Return a TomTom traffic-aware car ETA for an e-hailing leg."""
    tomtom_api_key = _tomtom_api_key()
    if not tomtom_api_key:
        raise HTTPException(503, "Traffic routing is not configured")

    departure: datetime | None = None
    if depart_at:
        try:
            departure = datetime.fromisoformat(depart_at.replace("Z", "+00:00"))
            if departure.tzinfo is None:
                departure = departure.replace(tzinfo=_MALAYSIA)
        except ValueError as error:
            raise HTTPException(400, "depart_at must be an ISO 8601 datetime") from error

    # A five-minute departure bucket allows similar itinerary alternatives to
    # share one provider request, while the short TTL keeps traffic estimates fresh.
    departure_bucket = (
        departure.replace(minute=(departure.minute // 5) * 5, second=0, microsecond=0)
        .isoformat()
        if departure is not None
        else "now"
    )
    cache_key = (
        f"{from_lat:.4f},{from_lon:.4f}",
        f"{to_lat:.4f},{to_lon:.4f}",
        departure_bucket,
    )
    cached = _traffic_route_cache.get(cache_key)
    if cached and time.monotonic() - cached[0] < 60:
        return cached[1]

    try:
        async with httpx.AsyncClient(timeout=12) as client:
            value = await fetch_route_estimate(
                client,
                api_key=tomtom_api_key,
                from_latitude=from_lat,
                from_longitude=from_lon,
                to_latitude=to_lat,
                to_longitude=to_lon,
                depart_at=departure,
            )
    except TomTomTrafficError as error:
        logger.warning("TomTom e-hailing route estimate failed: %s", error)
        raise HTTPException(503, "Traffic-aware route estimate is unavailable") from error

    if len(_traffic_route_cache) >= 1000:
        _traffic_route_cache.clear()
    _traffic_route_cache[cache_key] = (time.monotonic(), value)
    return value


@app.get("/api/stations/{station_id}/crowd")
async def station_crowd(station_id: str) -> dict[str, Any]:
    """Estimate crowd level from recent anonymous station-presence reports."""
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        logger.warning("Crowd data is not configured; returning low fallback")
        return {
            "stationId": station_id,
            "level": "low",
            "observedUsers": 0,
            "capacity": None,
            "windowMinutes": 30,
            "confidence": "low",
            "available": False,
        }
    since = (datetime.now(timezone.utc) - timedelta(minutes=30)).isoformat()
    headers = {
        "apikey": SUPABASE_SERVICE_ROLE_KEY,
        "Authorization": f"******",
    }
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            presence_response = await client.get(
                f"{SUPABASE_URL}/rest/v1/anonymous_station_presence",
                headers=headers,
                params={
                    "select": "station_id,observed_at",
                    "station_id": f"eq.{station_id}",
                    "observed_at": f"gte.{since}",
                },
            )
            presence_response.raise_for_status()
            capacity_response = await client.get(
                f"{SUPABASE_URL}/rest/v1/station_capacity",
                headers=headers,
                params={
                    "select": "capacity",
                    "station_id": f"eq.{station_id}",
                    "limit": "1",
                },
            )
            capacity = None
            if capacity_response.status_code == 200:
                rows = capacity_response.json()
                if rows and isinstance(rows[0], dict):
                    capacity = rows[0].get("capacity")
    except httpx.HTTPError as error:
        logger.exception("Could not read crowd data for station %s", station_id)
        return {
            "stationId": station_id,
            "level": "low",
            "observedUsers": 0,
            "capacity": None,
            "windowMinutes": 30,
            "confidence": "low",
            "available": False,
        }
    rows = presence_response.json()
    observed_users = len(rows) if isinstance(rows, list) else 0
    if isinstance(capacity, int) and capacity > 0:
        ratio = observed_users / capacity
        level = "high" if ratio >= 0.7 else "medium" if ratio >= 0.3 else "low"
    else:
        level = "high" if observed_users >= 10 else "medium" if observed_users >= 4 else "low"
    return {
        "stationId": station_id,
        "level": level,
        "observedUsers": observed_users,
        "capacity": capacity,
        "windowMinutes": 30,
        "confidence": "low" if capacity is None else "medium",
        "available": True,
    }


@app.post("/api/station-presence", status_code=202)
async def station_presence(report: PresenceReport) -> dict[str, str]:
    body = report.model_dump(exclude_none=True)
    await _insert("anonymous_station_presence", body)
    return {"status": "accepted"}


@app.post("/api/incidents", status_code=202)
async def incidents(report: IncidentReport) -> dict[str, str]:
    body = report.model_dump(exclude_none=True)
    await _insert("anonymous_incident_reports", body)
    return {"status": "accepted"}
