"""Server-side TomTom Traffic Flow client for stop-area road congestion."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import httpx


FLOW_SEGMENT_URL = (
    "https://api.tomtom.com/traffic/services/4/flowSegmentData/absolute/10/json"
)
ROUTE_URL = "https://api.tomtom.com/routing/1/calculateRoute"


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
    except httpx.HTTPStatusError as error:
        raise TomTomTrafficError(
            f"TomTom traffic request failed with HTTP {error.response.status_code}"
        ) from error
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


async def fetch_route_estimate(
    client: httpx.AsyncClient,
    *,
    api_key: str,
    from_latitude: float,
    from_longitude: float,
    to_latitude: float,
    to_longitude: float,
    depart_at: datetime | None = None,
) -> dict[str, Any]:
    """Return a traffic-aware car route estimate and traffic delay."""
    locations = (
        f"{from_latitude:.6f},{from_longitude:.6f}:"
        f"{to_latitude:.6f},{to_longitude:.6f}"
    )
    params: dict[str, str] = {
        "key": api_key,
        "traffic": "true",
        "routeType": "fastest",
        "travelMode": "car",
        "computeTravelTimeFor": "all",
        "routeRepresentation": "summaryOnly",
    }
    if depart_at is not None:
        params["departAt"] = depart_at.isoformat()

    try:
        response = await client.get(
            f"{ROUTE_URL}/{locations}/json",
            params=params,
        )
        response.raise_for_status()
        payload = response.json()
        routes = payload.get("routes") if isinstance(payload, dict) else None
        route = routes[0] if isinstance(routes, list) and routes else None
        summary = route.get("summary") if isinstance(route, dict) else None
        if not isinstance(summary, dict):
            raise TomTomTrafficError("TomTom returned no route summary")
        travel_seconds = int(summary["travelTimeInSeconds"])
        distance_meters = int(summary["lengthInMeters"])
        no_traffic_seconds = int(
            summary.get("noTrafficTravelTimeInSeconds", travel_seconds)
        )
        delay_seconds = max(
            0,
            int(
                summary.get(
                    "trafficDelayInSeconds",
                    travel_seconds - no_traffic_seconds,
                )
            ),
        )
    except httpx.HTTPStatusError as error:
        raise TomTomTrafficError(
            f"TomTom route request failed with HTTP {error.response.status_code}"
        ) from error
    except (httpx.HTTPError, KeyError, TypeError, ValueError, IndexError) as error:
        if isinstance(error, TomTomTrafficError):
            raise
        raise TomTomTrafficError("TomTom route estimate is unavailable") from error

    delay_ratio = delay_seconds / max(1, no_traffic_seconds)
    if delay_ratio >= 0.4:
        level = "heavy"
    elif delay_ratio >= 0.15:
        level = "moderate"
    else:
        level = "low"

    return {
        "provider": "TomTom Routing API",
        "trafficLevel": level,
        "travelTimeSeconds": travel_seconds,
        "noTrafficTravelTimeSeconds": no_traffic_seconds,
        "trafficDelaySeconds": delay_seconds,
        "distanceMeters": distance_meters,
        "departureTime": summary.get("departureTime"),
        "arrivalTime": summary.get("arrivalTime"),
    }
