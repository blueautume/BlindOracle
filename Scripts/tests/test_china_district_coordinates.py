"""Validate the bundled district catalog without network or Apple SDKs."""
from collections import Counter
from copy import deepcopy
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Resources/Locations/china-districts.json"
SUPPLEMENTS = ROOT / "Scripts/Data/china-coordinate-supplements.json"
GENERATOR_SPEC = importlib.util.spec_from_file_location(
    "generate_china_districts", ROOT / "Scripts/generate_china_districts.py"
)
GENERATOR = importlib.util.module_from_spec(GENERATOR_SPEC)
GENERATOR_SPEC.loader.exec_module(GENERATOR)


class ChinaDistrictCoordinatesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = json.loads(CATALOG.read_text(encoding="utf-8"))
        cls.rows = cls.source["districts"]
        cls.by_id = {row["id"]: row for row in cls.rows}
        cls.parent_ids = {row["parent"] for row in cls.rows if "parent" in row}

    def test_catalog_identity_and_parent_order_are_preserved(self):
        self.assertEqual(self.source["version"], 1)
        self.assertEqual(len(self.rows), 3_633)
        self.assertEqual(len(self.by_id), len(self.rows), "Duplicate district IDs")
        roots = Counter()
        seen = set()
        for row in self.rows:
            with self.subTest(district=row["id"]):
                self.assertTrue(row["id"])
                self.assertTrue(row["name"])
                if "parent" in row:
                    # The app decodes parents before their children.
                    self.assertIn(row["parent"], seen)
                else:
                    roots[row["country"]] += 1
                seen.add(row["id"])
        self.assertEqual(roots, {"CN": 31, "HK": 1, "MO": 1, "TW": 1})

    def test_available_coordinates_are_finite_and_in_the_supported_region(self):
        for row in self.rows:
            with self.subTest(district=row["id"]):
                self.assertEqual("latitude" in row, "longitude" in row)
                if "latitude" not in row:
                    continue
                latitude, longitude = row["latitude"], row["longitude"]
                self.assertIn(type(latitude), (int, float))
                self.assertIn(type(longitude), (int, float))
                self.assertTrue(math.isfinite(latitude))
                self.assertTrue(math.isfinite(longitude))
                # A broad regional envelope catches swapped latitude/longitude,
                # null-island placeholders and coordinates from another country.
                self.assertGreater(latitude, 0)
                self.assertLess(latitude, 56)
                self.assertGreater(longitude, 70)
                self.assertLess(longitude, 140)

    def test_every_selectable_leaf_has_offline_coordinates(self):
        leaves = [row for row in self.rows if row["id"] not in self.parent_ids]
        self.assertEqual(len(leaves), 3_248)
        missing = [f'{row["id"]} {row["name"]}' for row in leaves
                   if "latitude" not in row or "longitude" not in row]
        self.assertEqual(missing, [], "Missing offline leaf coordinates")

    def test_supplements_match_the_catalog_and_record_their_source(self):
        supplements = json.loads(SUPPLEMENTS.read_text(encoding="utf-8"))
        self.assertEqual(supplements["version"], 1)
        self.assertEqual(supplements["coordinateSystem"], "WGS84")
        entries = supplements["entries"]
        self.assertTrue(entries)
        self.assertEqual(len(entries), len({entry["id"] for entry in entries}))
        for entry in entries:
            with self.subTest(district=entry["id"]):
                row = self.by_id[entry["id"]]
                self.assertEqual(entry["name"], row["name"])
                path = [row["name"]]
                current = row
                seen = {row["id"]}
                while "parent" in current:
                    current = self.by_id[current["parent"]]
                    self.assertNotIn(current["id"], seen)
                    seen.add(current["id"])
                    path.append(current["name"])
                self.assertEqual(entry["path"], list(reversed(path)))
                self.assertEqual(entry["latitude"], row["latitude"])
                self.assertEqual(entry["longitude"], row["longitude"])
                source = entry["source"]
                self.assertTrue(source["provider"])
                self.assertTrue(str(source["id"]))
                url = urlparse(source["url"])
                self.assertEqual(url.scheme, "https")
                self.assertTrue(url.hostname)
                if source["provider"] == "GeoNames":
                    self.assertEqual(row["geonameID"], int(source["id"]))
                elif source["provider"] == "Wikidata":
                    self.assertRegex(source["id"], r"^Q[1-9][0-9]*$")
                    self.assertEqual(row["wikidataID"], source["id"])

    def test_catalog_is_reproducible_from_pinned_source_inputs(self):
        source = os.environ.get("BLINDORACLE_DISTRICT_SOURCE_DIR")
        if not source:
            self.skipTest("Set BLINDORACLE_DISTRICT_SOURCE_DIR to the pinned source directory")
        with tempfile.TemporaryDirectory(prefix="blindoracle-district-rebuild-") as directory:
            output = Path(directory) / "china-districts.json"
            completed = subprocess.run(
                [sys.executable, str(ROOT / "Scripts/generate_china_districts.py"),
                 source, "--output", str(output)],
                cwd=ROOT, capture_output=True, text=True, check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(output.read_bytes(), CATALOG.read_bytes())


class CoordinateSupplementValidationTests(unittest.TestCase):
    def setUp(self):
        self.rows = [
            {"id": "130000", "name": "河北省", "country": "CN"},
            {"id": "130100", "name": "石家庄市", "parent": "130000"},
            {"id": "130102", "name": "长安区", "parent": "130100"},
        ]
        self.point = {
            "id": "130102", "name": "长安区",
            "path": ["河北省", "石家庄市", "长安区"],
            "latitude": 38.1, "longitude": 114.5,
            "source": {"provider": "GeoNames", "id": "123",
                       "url": "https://www.geonames.org/123/"},
            "note": "Synthetic test point; not a catalog coordinate.",
        }

    def apply(self, rows, points):
        with tempfile.TemporaryDirectory(prefix="blindoracle-coordinate-fixture-") as directory:
            manifest = Path(directory) / "supplements.json"
            manifest.write_text(json.dumps({
                "version": 1, "coordinateSystem": "WGS84", "entries": points,
            }, ensure_ascii=False), encoding="utf-8")
            return GENERATOR.apply_coordinate_supplements(rows, manifest)

    def test_same_district_name_from_another_city_cannot_supply_coordinates(self):
        point = deepcopy(self.point)
        point["path"] = ["陕西省", "西安市", "长安区"]
        with self.assertRaises(ValueError):
            self.apply(self.rows, [point])
        self.assertNotIn("latitude", self.rows[-1])

    def test_duplicate_supplements_and_replacing_upstream_coordinates_are_rejected(self):
        with self.subTest(case="duplicate district"):
            with self.assertRaises(ValueError):
                self.apply(deepcopy(self.rows), [deepcopy(self.point), deepcopy(self.point)])
        with self.subTest(case="existing upstream coordinates"):
            rows = deepcopy(self.rows)
            rows[-1].update(latitude=38.2, longitude=114.6)
            with self.assertRaises(ValueError):
                self.apply(rows, [deepcopy(self.point)])
            self.assertEqual((rows[-1]["latitude"], rows[-1]["longitude"]), (38.2, 114.6))

    def test_nonfinite_out_of_range_and_placeholder_coordinates_are_rejected(self):
        values = [
            (float("nan"), 114.5), (38.1, float("inf")),
            (90.1, 114.5), (38.1, 180.1),
            (114.5, 38.1), (True, 114.5), (0, 0),
        ]
        for latitude, longitude in values:
            with self.subTest(latitude=latitude, longitude=longitude):
                point = deepcopy(self.point)
                point.update(latitude=latitude, longitude=longitude)
                rows = deepcopy(self.rows)
                with self.assertRaises(ValueError):
                    self.apply(rows, [point])
                self.assertNotIn("latitude", rows[-1])


if __name__ == "__main__":
    unittest.main()
