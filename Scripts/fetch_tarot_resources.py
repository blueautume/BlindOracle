#!/usr/bin/env python3
"""Fetch the pinned MIT tarot corpus and classic Rider–Waite–Smith scans.

Runtime does not use the network. This maintenance script requires curl and
macOS sips (or Pillow on other platforms) only when regenerating the assets.
"""

from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


REVISION = "319ce18f1b583035e00c63854a2a405a0088bc73"
REPOSITORY = "https://github.com/LindseyB/tarot-api"
ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "Resources" / "Tarot"
MAJOR_NAMES = [
    "愚者", "魔术师", "女祭司", "皇后", "皇帝", "教皇", "恋人", "战车",
    "力量", "隐者", "命运之轮", "正义", "倒吊人", "死神", "节制", "恶魔",
    "高塔", "星星", "月亮", "太阳", "审判", "世界",
]
RANKS = {"page": 11, "knight": 12, "queen": 13, "king": 14}
SUITS = {"wands": "权杖", "cups": "圣杯", "swords": "宝剑", "pentacles": "星币"}
RANK_NAMES = ["", "首牌", "二", "三", "四", "五", "六", "七", "八", "九", "十", "侍从", "骑士", "王后", "国王"]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    payload = subprocess.check_output([
        "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
        f"https://codeload.github.com/LindseyB/tarot-api/zip/{REVISION}",
    ])
    archive = zipfile.ZipFile(io.BytesIO(payload))
    prefix = archive.namelist()[0]
    source_json = archive.read(prefix + "tarot.json")
    source_cards = json.loads(source_json)["cards"]
    assert len(source_cards) == 78
    (DESTINATION / "Cards").mkdir(parents=True, exist_ok=True)
    cards = []
    provenance = []
    with tempfile.TemporaryDirectory(prefix="blind-oracle-tarot-") as temp:
        for card in source_cards:
            suit = card["suit"]
            rank = RANKS.get(card["rank"], card["rank"])
            identifier = f"{suit}-{rank:02d}"
            name = card["name"].replace("Charriot", "Chariot")
            if suit == "major":
                source_name = name.replace(" ", "") + ".png"
                # Upstream uses these two spellings in its actual image names.
                source_name = {"Judgment.png": "Judgement.png", "WheelofFortune.png": "WheelOfFortune.png"}.get(source_name, source_name)
                localized_name = MAJOR_NAMES[rank]
            else:
                source_name = f"{suit.capitalize()}{rank:02d}.png"
                localized_name = SUITS[suit] + RANK_NAMES[rank]
            original = archive.read(prefix + "public/cards/" + source_name)
            original_path = Path(temp) / source_name
            original_path.write_bytes(original)
            image_filename = identifier + ".jpg"
            image_path = DESTINATION / "Cards" / image_filename
            if shutil.which("sips"):
                subprocess.run([
                    "sips", "--setProperty", "format", "jpeg", "--setProperty", "formatOptions", "82",
                    str(original_path), "--out", str(image_path),
                ], check=True, stdout=subprocess.DEVNULL)
            else:
                from PIL import Image

                with Image.open(original_path) as image:
                    background = Image.new("RGB", image.size, "white")
                    if image.mode == "RGBA":
                        background.paste(image, mask=image.getchannel("A"))
                    else:
                        background.paste(image.convert("RGB"))
                    background.save(image_path, "JPEG", quality=82, optimize=True)
            cards.append({
                "id": identifier, "name": name, "localizedName": localized_name,
                "upright": card["meanings"]["upright"],
                "reversed": card["meanings"]["reversed"],
                "imageFilename": image_filename,
            })
            provenance.append({
                "id": identifier, "sourcePath": "public/cards/" + source_name,
                "sourceSHA256": digest(original), "bundledSHA256": digest(image_path.read_bytes()),
            })
    assert len({card["id"] for card in cards}) == 78
    assert all(card["upright"] and card["reversed"] for card in cards)
    (DESTINATION / "tarot-cards.json").write_text(json.dumps({
        "schemaVersion": 1, "sourceRevision": REVISION, "cards": cards,
    }, ensure_ascii=False, indent=2) + "\n")
    (DESTINATION / "source-manifest.json").write_text(json.dumps({
        "repository": REPOSITORY, "revision": REVISION,
        "sourceJSONSHA256": digest(source_json),
        "imageOrigin": "https://luciellaes.itch.io/rider-waite-smith-tarot-cards-cc0",
        "imageProcessing": "Original 300x527px scans converted to JPEG at quality 82; no generative imagery.",
        "cards": provenance,
    }, ensure_ascii=False, indent=2) + "\n")
    (DESTINATION / "ThirdParty-Tarot-MIT.txt").write_bytes(archive.read(prefix + "MIT-LICENSE"))
    total = sum(path.stat().st_size for path in DESTINATION.rglob("*") if path.is_file())
    print(f"Prepared {len(cards)} cards and images ({total / 1024 / 1024:.2f} MiB) at {DESTINATION}")


if __name__ == "__main__":
    main()
