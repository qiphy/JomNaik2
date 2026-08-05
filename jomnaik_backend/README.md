# JomNaik live-context backend

JomNaik plans static public-transit journeys on the device using its bundled
RAPTOR timetable. This optional FastAPI service adds only live context:

- Open-Meteo weather for the current map centre.
- TomTom road congestion for e-hailing/station access.
- Official data.gov.my GTFS-Realtime bus and KTM vehicle positions.
- Supabase-authenticated anonymous station-presence and incident reports.

There is no MOTIS process, GTFS import, scheduler, Databricks SDK, Lakebase
dependency, database volume, or routing data in the deployable service.
If this API is down, Flutter still supplies an offline timetable itinerary.

## Deploy

Push the **JomNaik parent folder** (containing both `jomnaik/` and
`jomnaik_backend/`) to one GitHub repository, then create either a Railway or
Railway web service with `jomnaik_backend` as its root directory. The service
starts with:

```sh
bash start.sh
```

Set these environment variables from `.env.example` in the hosting dashboard:

- `TOMTOM_API_KEY`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `CORS_ORIGINS` (use `*` for the mobile beta)
- `OFFLINE_ROUTING_MANIFEST_URL` (replace `owner/repository/main` in the
  example with your GitHub repository and default branch)

Never put `SUPABASE_SERVICE_ROLE_KEY` or the TomTom key in Flutter.

The service health check is `GET /api/health`.

### Live vehicles

`GET /api/realtime/vehicles` returns current Rapid KL bus, MRT feeder and KTM
vehicle positions. Provide `lat`, `lon`, and an optional `radius_km` (default
`8`, maximum `30`) to return only vehicles near the visible map area. The API
shares a 25-second memory cache, while data.gov.my publishes vehicle positions
at a 30-second cadence. The feed does not currently include trip updates or
service alerts, so the app must label these as live positions—not guaranteed
arrival predictions.

## Weekly GTFS refresh

The repository workflow at `.github/workflows/refresh-offline-gtfs.yml` runs
every Monday at 03:15 UTC (11:15 AM Malaysia time), and can also be run from
GitHub Actions manually. It downloads the official Prasarana and KTMB static
feeds, rebuilds `jomnaik/assets/offline/raptor_klang_valley.json`, writes a
small version manifest, and commits both files only when the bundle changed.

Enable **Settings → Actions → General → Workflow permissions → Read and write
permissions** in GitHub. Devices check the API manifest when the app starts;
the backend caches that manifest for five minutes and then returns the newer
bundle URL. A device downloads it safely in the background and continues to
use the bundled timetable if any part of the update is unavailable.

## Local run

```sh
python -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
bash start.sh
```

## Client build

After deploying, point Flutter directly to the new service URL:

```sh
flutter build apk --release \
  --dart-define=GTFS_BACKEND_URL=https://your-service.example.com \
  --dart-define=USE_SUPABASE_API_AUTH=true
```

Do not use the old Databricks Cloudflare gateway in new builds.
