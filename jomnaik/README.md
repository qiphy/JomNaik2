# JomNaik Flutter app

The app reads the current transit-stop catalogue and scheduled departures from
the sibling `jomnaik_backend` FastAPI service.

Start the backend first:

```sh
cd ../jomnaik_backend
uvicorn main:app --host 0.0.0.0 --port 8000
```

Then start Flutter from this folder. For a physical phone or deployed API,
pass the publicly reachable API URL (without a trailing slash):

```sh
flutter run --dart-define=GTFS_BACKEND_URL=http://192.168.1.10:8000
```

`BACKEND_URL` remains supported for existing builds. Local web uses
`http://localhost:8000` and Android emulators use `http://10.0.2.2:8000` by
default. The app falls back to its bundled stop data when the backend is
unavailable.
