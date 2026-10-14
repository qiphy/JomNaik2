from datetime import datetime
import json
from pathlib import Path
from unittest import TestCase, main
from unittest.mock import patch
from zoneinfo import ZoneInfo

import gtfs_schedule


class DeparturesForStopTests(TestCase):
    def test_generated_bundle_contains_no_ets_schedule(self):
        bundle_path = (
            Path(__file__).parent.parent
            / "jomnaik/assets/offline/raptor_klang_valley.json"
        )
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))

        self.assertNotIn("ktmb:ETS", bundle["routes"])
        self.assertFalse(
            any(
                len(trip) > 1 and str(trip[1]).casefold().endswith(":ets")
                for trip in bundle["trips"]
            )
        )

    def test_excludes_ets_and_keeps_other_scheduled_routes(self):
        service_calendar = [True] * 7 + ["20260101", "20271231"]
        bundle = {
            "routes": {
                "ktmb:ETS": ["ETS", "Electric Train Service", 2],
                "ktmb:SH": ["SH", "Intercity Shuttle", 2],
            },
            "trips": [
                ["ets-trip", "ktmb:ETS", "ets-service", "To Ipoh", [["ktmb:1", 36000, 36000]]],
                ["sh-trip", "ktmb:SH", "sh-service", "To Gemas", [["ktmb:1", 36600, 36600]]],
            ],
            "calendars": {
                "ets-service": service_calendar,
                "sh-service": service_calendar,
            },
            "exceptions": {},
            "stops": {"ktmb:1": ["Station", 3.0, 101.0]},
        }
        now = datetime(2026, 10, 14, 9, 0, tzinfo=ZoneInfo("Asia/Kuala_Lumpur"))

        with patch.object(gtfs_schedule, "_load_bundle", return_value=bundle):
            result = gtfs_schedule.departures_for_stop(
                "ktmb:1", limit=1, now=now
            )

        self.assertEqual([item["route"] for item in result["departures"]], ["SH"])


if __name__ == "__main__":
    main()