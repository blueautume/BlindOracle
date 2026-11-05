#!/usr/bin/env python3
"""Build the location picker catalog from pinned pca-code.json and GeoNames ZIPs."""
import argparse
from collections import defaultdict
import csv
import io
import json
import math
from pathlib import Path
import re
from zipfile import ZipFile


# Labels verified against the Hong Kong District Council and Macao cadastral lists.
HK_NAMES = dict(zip(
    "NYL NTW NTP NSK NIS HCW HWC HEA HSO KYT KSS KKC KWT KKT NKT NTM NNO NST".split(),
    "元朗區 荃灣區 大埔區 西貢區 離島區 中西區 灣仔區 東區 南區 油尖旺區 深水埗區 九龍城區 黃大仙區 觀塘區 葵青區 屯門區 北區 沙田區".split(),
    strict=True,
))
MO_NAMES = dict(zip(
    range(11875154, 11875162),
    "花地瑪堂區 花王堂區 望德堂區 大堂區 風順堂區 嘉模堂區 路氹填海區 聖方濟各堂區".split(),
    strict=True,
))
TW_CITIES = {"TPQ", "TAO", "TPE", "TNN", "HSQ", "CYI", "KEE", "KHH", "TXG"}
CHINESE = re.compile(r"[\u3400-\u9fff]+")
SYNTHETIC = {"市辖区", "县", "省直辖县级行政区划", "自治区直辖县级行政区划"}
DEFAULT_COORDINATE_SUPPLEMENTS = Path(__file__).resolve().parent / "Data" / "china-coordinate-supplements.json"


def records(source, country):
    with ZipFile(source / f"{country}.zip") as archive:
        with archive.open(f"{country}.txt") as raw:
            for row in csv.reader(io.TextIOWrapper(raw, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE):
                if row[7] in {"ADM1", "ADM2", "ADM3", "PCLI", "PCLS"}:
                    yield row


def district(code, name, parent=None, geo=None, country=None):
    value = {"id": code, "name": name}
    if parent:
        value["parent"] = parent
    if country:
        value["country"] = country
    if geo:
        value.update(latitude=float(geo[4]), longitude=float(geo[5]), geonameID=int(geo[0]))
    return value


def mainland(source):
    indexed = defaultdict(list)
    for row in records(source, "CN"):
        for alias in {row[1], *row[3].split(",")}:
            if CHINESE.fullmatch(alias):
                indexed[alias].append(row)

    def match(name, features, admin1=None, admin2=None):
        matches = [
            row for row in indexed[name]
            if row[7] in features and (admin1 is None or row[10] == admin1)
            and (admin2 is None or row[11] in admin2)
        ]
        return matches[0] if len(matches) == 1 else None

    for province in json.loads((source / "pca-code.json").read_text(encoding="utf-8")):
        province_id = province["code"].ljust(6, "0")
        province_geo = match(province["name"], {"ADM1"})
        yield district(province_id, province["name"], geo=province_geo, country="CN")
        for city in province["children"]:
            city_id = city["code"].ljust(6, "0")
            city_geo = None
            synthetic = city["name"] in SYNTHETIC
            admin1 = province_geo[10] if province_geo else None
            if not synthetic:
                if admin1:
                    city_geo = match(city["name"], {"ADM2"}, admin1)
                yield district(city_id, city["name"], province_id, city_geo)
            for county in city.get("children", []):
                # The snapshot reserves 71–80 for statistical management units.
                if len(county["code"]) != 6 or 71 <= int(county["code"][-2:]) <= 80:
                    continue
                geo = None
                if admin1:
                    if synthetic:
                        geo = match(county["name"], {"ADM2", "ADM3"}, admin1)
                    else:
                        parent_codes = {city["code"]}
                        if city_geo:
                            parent_codes.add(city_geo[11])
                        geo = match(county["name"], {"ADM3"}, admin1, parent_codes)
                yield district(county["code"], county["name"], province_id if synthetic else city_id, geo)


def aliases(row):
    return [a for a in row[3].split(",") if CHINESE.fullmatch(a)]


def taiwan_name(row, endings):
    names = [a for a in aliases(row) if a.endswith(endings)]
    if not names:
        raise ValueError(f"Missing Taiwan label: {row[0]} {row[1]} {aliases(row)}")
    # Normalize orthographic variants without changing the traditional place name.
    return names[0].replace("台", "臺").replace("鎭", "鎮")


def regional(source, country, label):
    rows = list(records(source, country))
    root = next(r for r in rows if r[7] in {"PCLI", "PCLS"})
    root_id = f"{country}:{root[0]}"
    yield district(root_id, label, geo=root, country=country)
    if country == "HK":
        for row in sorted((r for r in rows if r[7] == "ADM1"), key=lambda r: r[10]):
            yield district(f"{country}:{row[0]}", HK_NAMES[row[10]], root_id, row)
    elif country == "MO":
        for row in sorted((r for r in rows if r[7] == "ADM1"), key=lambda r: int(r[0])):
            yield district(f"{country}:{row[0]}", MO_NAMES[int(row[0])], root_id, row)
    else:
        counties = {row[11]: row for row in rows if row[7] == "ADM2"}
        townships = defaultdict(list)
        for row in rows:
            if row[7] != "ADM3":
                continue
            if row[11] not in counties:
                raise ValueError(f"Missing Taiwan parent: {row[0]} {row[11]}")
            townships[row[11]].append(row)
        for county_code, row in sorted(counties.items()):
            code = f"{country}:{row[0]}"
            label = taiwan_name(row, "市" if county_code in TW_CITIES else "縣")
            yield district(code, label, root_id, row)
            for child in sorted(townships[county_code], key=lambda r: r[12]):
                suffix = next((ending for word, ending in [
                    ("District", "區"), ("Township", ("鄉", "鎮", "鎭")), ("City", "市")
                ] if child[1].endswith(word)), ("區", "鄉", "鎮", "鎭", "市"))
                yield district(f"{country}:{child[0]}", taiwan_name(child, suffix), code, child)


def apply_coordinate_supplements(entries, supplement_path):
    """Apply reviewed, source-linked WGS84 points without replacing upstream points."""
    supplements = json.loads(supplement_path.read_text(encoding="utf-8"))
    if supplements.get("version") != 1 or supplements.get("coordinateSystem") != "WGS84":
        raise ValueError("Unsupported coordinate supplement version or coordinate system")
    by_id = {entry["id"]: entry for entry in entries}
    applied = set()
    for point in supplements["entries"]:
        code = point["id"]
        if code in applied or code not in by_id:
            raise ValueError(f"Duplicate or unknown coordinate supplement: {code}")
        entry = by_id[code]
        names = [entry["name"]]
        parent = entry
        while "parent" in parent:
            parent = by_id[parent["parent"]]
            names.append(parent["name"])
        if point["name"] != entry["name"] or point["path"] != list(reversed(names)):
            raise ValueError(f"Coordinate supplement does not match the district path: {code}")
        if "latitude" in entry or "longitude" in entry:
            raise ValueError(f"Coordinate supplement would replace an existing point: {code}")
        latitude, longitude = point["latitude"], point["longitude"]
        if (type(latitude) not in (float, int) or type(longitude) not in (float, int)
                or not math.isfinite(latitude) or not math.isfinite(longitude)
                or not 0 < latitude < 56 or not 70 < longitude < 140):
            raise ValueError(f"Invalid supplemental coordinates: {code}")
        source = point["source"]
        if not source.get("provider") or not source.get("id") or not source.get("url", "").startswith("https://") or not point.get("note"):
            raise ValueError(f"Missing coordinate provenance: {code}")
        entry.update(latitude=latitude, longitude=longitude)
        if source["provider"] == "GeoNames":
            entry["geonameID"] = int(source["id"])
        elif source["provider"] == "Wikidata":
            entry["wikidataID"] = source["id"]
        applied.add(code)
    return applied


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="directory with pca-code.json and CN/HK/MO/TW.zip")
    parser.add_argument("--output", type=Path, default=Path("Resources/Locations/china-districts.json"))
    parser.add_argument("--coordinate-supplements", type=Path, default=DEFAULT_COORDINATE_SUPPLEMENTS,
                        help="reviewed WGS84 coordinate supplements with per-district provenance")
    args = parser.parse_args()
    entries = list(mainland(args.source))
    for country, label in (("HK", "香港特别行政区"), ("MO", "澳门特别行政区"), ("TW", "台湾地区")):
        entries.extend(regional(args.source, country, label))
    ids = set()
    for entry in entries:
        if entry["id"] in ids or ("parent" in entry and entry["parent"] not in ids):
            raise ValueError(f"Duplicate or missing parent: {entry}")
        ids.add(entry["id"])
    applied = apply_coordinate_supplements(entries, args.coordinate_supplements)
    rows = [json.dumps(entry, ensure_ascii=False, separators=(",", ":")) for entry in entries]
    args.output.write_text('{"version":1,"districts":[\n' + ",\n".join(rows) + "\n]}\n", encoding="utf-8")
    print(f"{len(entries)} districts, {sum('latitude' in entry for entry in entries)} with coordinates, {len(applied)} reviewed supplements")


if __name__ == "__main__":
    main()
