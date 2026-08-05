"""Live weather client for JomNaik regions."""

from __future__ import annotations

from typing import Any

import httpx

OPEN_METEO_FORECAST_URL = "https://api.open-meteo.com/v1/forecast"


def _english_condition(weather_code: int) -> str:
    """Translate Open-Meteo WMO weather codes into client-facing English."""
    if weather_code == 0:
        return "Clear"
    if weather_code in {1, 2, 3}:
        return "Cloudy"
    if weather_code in {45, 48}:
        return "Foggy"
    if weather_code in {51, 53, 55, 56, 57}:
        return "Drizzle"
    if weather_code in {61, 63, 65, 66, 67, 80, 81, 82}:
        return "Rain"
    if weather_code in {95, 96, 99}:
        return "Thunderstorm"
    return "Unknown"


async def fetch_current_weather(
    client: httpx.AsyncClient,
    *,
    latitude: float,
    longitude: float,
) -> dict[str, Any]:
    """Fetch current modelled conditions at a region's centre point."""
    response = await client.get(
        OPEN_METEO_FORECAST_URL,
        params={
            "latitude": latitude,
            "longitude": longitude,
            "current": "temperature_2m,weather_code,is_day",
            "timezone": "Asia/Kuala_Lumpur",
        },
    )
    response.raise_for_status()
    current = response.json().get("current")
    if not current:
        raise ValueError("No current weather is available for this location")

    weather_code = int(current["weather_code"])
    return {
        "region_center": {"lat": latitude, "lon": longitude},
        "location": "Klang Valley",
        "observed_at": current["time"],
        "current_temp": current["temperature_2m"],
        "weather_code": weather_code,
        "is_day": bool(current.get("is_day", 1)),
        "forecast": _english_condition(weather_code),
    }
