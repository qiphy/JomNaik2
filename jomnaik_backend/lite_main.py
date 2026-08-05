"""Small optional live-context API for the on-device JomNaik router.

RAPTOR routing now runs in Flutter.  This service deliberately contains no
MOTIS binary, GTFS import, scheduler, or local database.  It is safe to host
on a small Railway/Render service and is non-essential to route availability.
"""
from __future__ import annotations

import os
import time
from math import asin, cos, radians, sin, sqrt
from typing import Any

import httpx
from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from tomtom import TomTomTrafficError, fetch_congestion
from realtime import fetch_vehicle_positions
from weather import fetch_current_weather

SUPABASE_URL = os.getenv("SUPABASE_URL", "").rstrip("/")
SUPABASE_ANON_KEY = os.getenv("SUPABASE_ANON_KEY", "")
SUPABASE_SERVICE_ROLE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
TOMTOM_API_KEY = os.getenv("TOMTOM_API_KEY", "")
_weather_cache: dict[tuple[float, float], tuple[float, dict[str, Any]]] = {}
_traffic_cache: dict[tuple[float, float], tuple[float, dict[str, Any]]] = {}
_offline_manifest_cache: tuple[float, dict[str, str]] | None = None
_vehicle_cache: tuple[float, dict[str, Any]] | None = None


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
    reported_at: str | None = None


app = FastAPI(title="JomNaik Live Context API", version="1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[item.strip() for item in os.getenv("CORS_ORIGINS", "*").split(",")],
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)


async def _verified_user(authorization: str | None) -> None:
    if not SUPABASE_URL or not SUPABASE_ANON_KEY:
        raise HTTPException(503, "Reporting is not configured")
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Sign in is required")
    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers={"apikey": SUPABASE_ANON_KEY, "Authorization": authorization},
        )
    if response.status_code != 200:
        raise HTTPException(401, "Your sign-in session is invalid")


async def _insert(table: str, body: dict[str, Any]) -> None:
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        raise HTTPException(503, "Reporting storage is not configured")
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
    if response.status_code not in {200, 201, 204}:
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
async def health() -> dict[str, str]:
    return {"status": "ok", "routing": "on_device"}


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
    key = (round(lat, 2), round(lon, 2))
    cached = _weather_cache.get(key)
    if cached and time.monotonic() - cached[0] < 120:
        return cached[1]
    try:
        async with httpx.AsyncClient(timeout=12) as client:
            value = await fetch_current_weather(client, latitude=lat, longitude=lon)
    except (httpx.HTTPError, ValueError) as error:
        raise HTTPException(503, "Weather is temporarily unavailable") from error
    _weather_cache[key] = (time.monotonic(), value)
    return value


@app.get("/api/traffic/congestion")
async def traffic(
    lat: float = Query(ge=2.7, le=3.5), lon: float = Query(ge=101.2, le=102.1)
) -> dict[str, Any]:
    if not TOMTOM_API_KEY:
        raise HTTPException(503, "Traffic is not configured")
    key = (round(lat, 3), round(lon, 3))
    cached = _traffic_cache.get(key)
    if cached and time.monotonic() - cached[0] < 60:
        return cached[1]
    try:
        async with httpx.AsyncClient(timeout=12) as client:
            value = await fetch_congestion(client, api_key=TOMTOM_API_KEY, latitude=lat, longitude=lon)
    except TomTomTrafficError as error:
        raise HTTPException(503, str(error)) from error
    _traffic_cache[key] = (time.monotonic(), value)
    return value


@app.post("/api/station-presence", status_code=202)
async def station_presence(report: PresenceReport, authorization: str | None = Header(default=None)) -> dict[str, str]:
    await _verified_user(authorization)
    body = report.model_dump(exclude_none=True)
    await _insert("anonymous_station_presence", body)
    return {"status": "accepted"}


@app.post("/api/incidents", status_code=202)
async def incidents(report: IncidentReport, authorization: str | None = Header(default=None)) -> dict[str, str]:
    await _verified_user(authorization)
    body = report.model_dump(exclude_none=True)
    await _insert("anonymous_incident_reports", body)
    return {"status": "accepted"}
