"""Official Malaysian GTFS-Realtime vehicle-position ingestion."""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import Any

import httpx
from google.protobuf.message import DecodeError
from google.transit import gtfs_realtime_pb2


# data.gov.my refreshes these source feeds every 30 seconds. They currently
# contain vehicle positions only, not GTFS-RT TripUpdates/ServiceAlerts.
MALAYSIA_VEHICLE_FEEDS = {
    "rapid-kl-bus": (
        "https://api.data.gov.my/gtfs-realtime/vehicle-position/prasarana/"
        "?category=rapid-bus-kl"
    ),
    "rapid-kl-bus-mrtfeeder": (
        "https://api.data.gov.my/gtfs-realtime/vehicle-position/prasarana/"
        "?category=rapid-bus-mrtfeeder"
    ),
    "ktmb": "https://api.data.gov.my/gtfs-realtime/vehicle-position/ktmb/",
}


async def fetch_vehicle_positions(client: httpx.AsyncClient) -> dict[str, Any]:
    """Fetch and normalize official live vehicle positions by static feed."""
    results = await asyncio.gather(
        *(_fetch_one_feed(client, name, url) for name, url in MALAYSIA_VEHICLE_FEEDS.items())
    )
    vehicles: list[dict[str, Any]] = []
    feed_status: dict[str, dict[str, Any]] = {}
    for feed_name, feed_vehicles, status in results:
        vehicles.extend(feed_vehicles)
        feed_status[feed_name] = status
    return {
        "updatedAt": datetime.now(timezone.utc).isoformat(),
        "vehicles": vehicles,
        "feeds": feed_status,
        "source": "data.gov.my GTFS-Realtime vehicle positions",
        "routingUpdatesAvailable": False,
    }


async def _fetch_one_feed(
    client: httpx.AsyncClient, feed_name: str, url: str
) -> tuple[str, list[dict[str, Any]], dict[str, Any]]:
    try:
        response = await client.get(url, headers={"Cache-Control": "no-cache"})
        response.raise_for_status()
        message = gtfs_realtime_pb2.FeedMessage()
        message.ParseFromString(response.content)
        vehicles: list[dict[str, Any]] = []
        for entity in message.entity:
            if not entity.HasField("vehicle") or not entity.vehicle.HasField("position"):
                continue
            vehicle = entity.vehicle
            latitude, longitude = vehicle.position.latitude, vehicle.position.longitude
            if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
                continue
            trip = vehicle.trip
            vehicle_id = vehicle.vehicle.id or entity.id
            vehicles.append(
                {
                    "id": f"{feed_name}:{vehicle_id}",
                    "feed": feed_name,
                    "lat": latitude,
                    "lon": longitude,
                    "bearing": vehicle.position.bearing if vehicle.position.HasField("bearing") else None,
                    "speedMps": vehicle.position.speed if vehicle.position.HasField("speed") else None,
                    "tripId": trip.trip_id or None,
                    "routeId": trip.route_id or None,
                    "timestamp": int(vehicle.timestamp) if vehicle.timestamp else None,
                }
            )
        return feed_name, vehicles, {"ok": True, "vehicleCount": len(vehicles)}
    except (httpx.HTTPError, ValueError, DecodeError) as error:
        return feed_name, [], {"ok": False, "error": str(error)[:200]}
