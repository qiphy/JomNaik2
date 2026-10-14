import asyncio
import os
from unittest import TestCase
from unittest.mock import patch

import lite_main


class _ManifestResponse:
    status_code = 200

    def json(self):
        return {
            "version": "2026-10-14-testbundle",
            "downloadUrl": "https://raw.githubusercontent.com/qiphy/JomNaik2/main/bundle.json",
        }


class _ManifestClient:
    def __init__(self):
        self.requested_url = None

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return None

    async def get(self, url):
        self.requested_url = url
        return _ManifestResponse()


class OfflineManifestTests(TestCase):
    def test_placeholder_deployment_url_falls_back_to_repository_manifest(self):
        client = _ManifestClient()
        previous_cache = lite_main._offline_manifest_cache
        lite_main._offline_manifest_cache = None
        try:
            with (
                patch.dict(
                    os.environ,
                    {
                        "OFFLINE_ROUTING_MANIFEST_URL": "https://raw.githubusercontent.com/owner/repository/main/jomnaik/assets/offline/raptor_manifest.json",
                        "OFFLINE_ROUTING_BUNDLE_URL": "https://raw.githubusercontent.com/owner/repository/main/jomnaik/assets/offline/raptor_klang_valley.json",
                        "OFFLINE_ROUTING_BUNDLE_VERSION": "2026-08-05",
                    },
                    clear=False,
                ),
                patch.object(lite_main.httpx, "AsyncClient", return_value=client),
            ):
                result = asyncio.run(lite_main.offline_manifest())

            self.assertEqual(client.requested_url, lite_main._DEFAULT_OFFLINE_MANIFEST_URL)
            self.assertEqual(result["version"], "2026-10-14-testbundle")
            self.assertIn("qiphy/JomNaik2", result["downloadUrl"])
        finally:
            lite_main._offline_manifest_cache = previous_cache


if __name__ == "__main__":
    import unittest

    unittest.main()