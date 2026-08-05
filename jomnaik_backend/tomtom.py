"""Server-side TomTom Traffic Flow client for stop-area road congestion."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import httpx


FLOW_SEGMENT_URL = (
    "https://api.tomtom.com/traffic/services/4/flowSegmentData/absolute/10/json"
)


class TomTomTrafficError(RuntimeError):
    """TomTom traffic data is unavailable or malformed."""


def _level(*, current_speed: float, free_flow_speed: float, road_closure: bool) -> str:
    if road_closure:
        return "road_closed"
    if free_flow_speed <= 0:
        return "unavailable"
    speed_ratio = current_speed / free_flow_speed
    if speed_ratio >= 0.8:
        return "low"
    if speed_ratio >= 0.55:
        return "moderate"
    return "heavy"


async def fetch_congestion(
    client: httpx.AsyncClient,
    *,
    api_key: str,
    latitude: float,
    longitude: float,
) -> dict[str, Any]:
    """Return the live traffic flow for the road closest to a stop area."""
    try:
        response = await client.get(
            FLOW_SEGMENT_URL,
            params={
                "key": api_key,
                "point": f"{latitude:.6f},{longitude:.6f}",
                "unit": "KMPH",
            },
        )
        response.raise_for_status()
        payload = response.json()
        flow = payload.get("flowSegmentData") if isinstance(payload, dict) else None
        if not isinstance(flow, dict):
            raise TomTomTrafficError("TomTom returned no flow segment")
        current_speed = float(flow["currentSpeed"])
        free_flow_speed = float(flow["freeFlowSpeed"])
        closure = bool(flow.get("roadClosure", False))
    except (httpx.HTTPError, KeyError, TypeError, ValueError) as error:
        raise TomTomTrafficError("TomTom traffic data is unavailable") from error

    delay_percent = (
        round(max(0.0, (free_flow_speed - current_speed) / free_flow_speed * 100), 1)
        if free_flow_speed > 0
        else None
    )
    return {
        "provider": "TomTom Traffic Flow",
        "level": _level(
            current_speed=current_speed,
            free_flow_speed=free_flow_speed,
            road_closure=closure,
        ),
        "currentSpeedKph": round(current_speed, 1),
        "freeFlowSpeedKph": round(free_flow_speed, 1),
        "delayPercent": delay_percent,
        "roadClosure": closure,
        "confidence": flow.get("confidence"),
        "observedAt": datetime.now(timezone.utc).isoformat(),
        "point": {"lat": latitude, "lon": longitude},
    }
