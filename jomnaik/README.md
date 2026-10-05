# jomnaik Flutter app

The app reads the current transit-stop catalogue and scheduled departures from
the sibling `jomnaik_backend` FastAPI service.

Start the backend first:

```sh
cd ../jomnaik_backend
uvicorn main:app --host 0.0.0.0 --port 8000
```

Then start Flutter from this folder. The production build uses:

```text
https://jomnaik2-production.up.railway.app
```

For a physical phone or another deployed API, pass its publicly reachable URL
(without a trailing slash):

```sh
flutter run --dart-define=GTFS_BACKEND_URL=http://192.168.1.10:8000
```

`BACKEND_URL` remains supported for existing builds. For local web
development, explicitly pass
`--dart-define=GTFS_BACKEND_URL=http://localhost:8000`. Android emulators use
`http://10.0.2.2:8000` when no URL is supplied. The app falls back to its
bundled stop data when the backend is unavailable.
