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


if __name__ == "__main__":
    import unittest

    unittest.main()