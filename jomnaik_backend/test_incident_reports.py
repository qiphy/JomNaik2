import asyncio
from unittest import TestCase
from unittest.mock import AsyncMock, patch

import lite_main


class IncidentReportTests(TestCase):
    def test_optional_comment_is_forwarded_to_persistent_storage(self):
        report = lite_main.IncidentReport(
            station_id="rapid-kl-rail:KJ31",
            station_name="USJ 7",
            station_lat=3.054956,
            station_lon=101.592194,
            report_type="disruption",
            target_type="station",
            comment="Train delayed at platform",
        )

        with patch.object(lite_main, "_insert", new_callable=AsyncMock) as insert:
            response = asyncio.run(lite_main.incidents(report))

        self.assertEqual(response, {"status": "accepted"})
        insert.assert_awaited_once_with(
            "anonymous_incident_reports",
            report.model_dump(exclude_none=True),
        )

    def test_recent_incidents_returns_submitted_comments(self):
        incident_rows = [
            {
                "station_id": "rapid-kl-rail:KJ31",
                "comment": "Train delayed at platform",
            }
        ]
        client = AsyncMock()
        client.__aenter__.return_value = client
        client.__aexit__.return_value = False
        client.get.return_value = type(
            "Response",
            (),
            {"status_code": 200, "json": lambda self: incident_rows},
        )()

        with (
            patch.object(lite_main, "SUPABASE_URL", "https://supabase.example"),
            patch.object(lite_main, "SUPABASE_SERVICE_ROLE_KEY", "service-key"),
            patch.object(lite_main.httpx, "AsyncClient", return_value=client),
        ):
            response = asyncio.run(lite_main.recent_incidents())

        self.assertEqual(response["incidents"], incident_rows)
        self.assertIn("comment", client.get.await_args.kwargs["params"]["select"])

    def test_facility_report_with_comment_is_persisted(self):
        report = lite_main.FacilityIssueReport(
            station_id="rapid-kl-rail:KJ31",
            station_name="USJ 7",
            station_lat=3.054956,
            station_lon=101.592194,
            facility_type="lift",
            issue_type="out_of_service",
            comment="Lift at the east entrance is not working",
        )

        with patch.object(lite_main, "_insert", new_callable=AsyncMock) as insert:
            response = asyncio.run(lite_main.create_facility_report(report))

        self.assertEqual(response, {"status": "accepted"})
        insert.assert_awaited_once_with(
            "station_facility_reports",
            report.model_dump(exclude_none=True),
        )

    def test_facility_report_rejects_unknown_category(self):
        with self.assertRaises(Exception):
            lite_main.FacilityIssueReport(
                station_id="station-1",
                station_name="Station",
                station_lat=3.0,
                station_lon=101.0,
                facility_type="elevator",
                issue_type="out_of_service",
            )


if __name__ == "__main__":
    import unittest

    unittest.main()