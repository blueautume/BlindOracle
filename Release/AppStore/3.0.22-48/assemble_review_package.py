#!/usr/bin/env python3
"""Validate and assemble an offline, allowlisted App Store review material ZIP."""

import argparse
import hashlib
import io
import itertools
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import tempfile
import unittest
import zipfile
import zlib


HERE = Path(__file__).resolve().parent
VERSION, BUILD = "3.0.22", "48"
LOCALES = ("zh-Hans", "en-US")
DEVICES = {
    "iphone-large": (1320, 2868),
    "iphone-medium": (1206, 2622),
    "ipad-13": (2064, 2752),
}
ROLES = {
    "question": "01-question.png",
    "reading-form": "02-reading-form.png",
    "tarot-selection": "03-tarot-selection.png",
    "method-directory": "04-method-directory.png",
    "local-bazi-preview": "05-local-bazi-preview.png",
}
# This one native iPad date-selection capture failed and was not approved.
# Every other locale/device/role remains mandatory; do not accept any 29 files.
OMITTED_UNAPPROVED_IDENTITY = ("en-US", "ipad-13", "local-bazi-preview")
STOREFRONT_IDENTITIES = frozenset(itertools.product(LOCALES, DEVICES, ROLES)) - {OMITTED_UNAPPROVED_IDENTITY}
STOREFRONT_PATHS = frozenset(
    f"screenshots/{locale}/{device}/{ROLES[role]}"
    for locale, device, role in STOREFRONT_IDENTITIES
)
IAP_IMAGE = "review-only/iap-review.png"
IAP_PROVENANCE = "review-only/iap-review-provenance.json"
# Exact native Screenshot XMP observed in all approved XCTest captures. No
# arbitrary XML, free-form comments, GPS, timestamps or identity fields pass.
NATIVE_SCREENSHOT_XMP = b'XML:com.adobe.xmp\0\0\0\0\0' + b'''<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/">
         <dc:description>
            <rdf:Alt>
               <rdf:li xml:lang="x-default">Screenshot</rdf:li>
            </rdf:Alt>
         </dc:description>
         <tiff:Orientation>1</tiff:Orientation>
         <exif:UserComment>Screenshot</exif:UserComment>
      </rdf:Description>
   </rdf:RDF>
</x:xmpmeta>
'''
NATIVE_UIKIT_PHYS = bytes.fromhex("000021380000213801")
NATIVE_IAP_IDOT = bytes.fromhex("00000002000000000000051f000000280000051f0000051f00017090")
DOCUMENTS = (
    "SUBMISSION.txt", "metadata.zh-Hans.json", "metadata.en-US.json",
    "iap-metadata.json", "privacy-labels.json", "review-notes.txt", "whats-new.txt",
    "official-requirements.txt", "submission-status.json", "field-validation.json",
)
WEB_FILES = ("web/index.html", "web/assets/site.css") + tuple(
    f"web/{locale}/{page}.html"
    for locale in LOCALES for page in ("privacy", "support", "terms", "marketing")
)
SECRET_PATTERNS = (
    rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    rb"\box[ar]_[A-Za-z0-9_-]{20,}\b",
    rb"\bsk-[A-Za-z0-9_-]{20,}\b",
    rb"\bBearer\s+[A-Za-z0-9._-]{24,}",
    rb"\beyJ[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{24,}\b",
)
SUBMISSION_BLOCKERS = (
    "Filing / ICP name, number and public / Apple-review-network reachability remain pending.",
    "ASC still has the old Data Not Collected answer; the new privacy answers have not been saved or published.",
    "The final root CUA check found the Mac locked; build48 final ASC processing completion remains unread.",
    "API-account-specific provider purposes, retention and training / optimization arrangements remain unconfirmed.",
    "Existing 1.0 / build21 remains Waiting for Review with manual release; build48 is not submitted by this package.",
    "ASC association of the first consumable and upload/attachment of the prepared IAP review image still require confirmation against the correct app version/build; the local image is complete.",
    "Non-owner, notification and refund follow-up remains deferred; this package makes no new acceptance claim.",
)


class MaterialError(ValueError):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_file(base, relative):
    """Never follow a manifest path outside the material directory or a symlink."""
    if not isinstance(relative, str) or "\\" in relative:
        raise MaterialError("Invalid relative path")
    parts = PurePosixPath(relative).parts
    if not parts or PurePosixPath(relative).is_absolute() or any(p in {"..", "."} for p in parts):
        raise MaterialError("Path traversal rejected")
    target = base
    for part in parts:
        target = target / part
        if target.is_symlink():
            raise MaterialError("Symlink rejected")
    if not target.resolve().is_relative_to(base.resolve()):
        raise MaterialError("Path outside package rejected")
    if not target.is_file() or not stat.S_ISREG(target.stat().st_mode):
        raise MaterialError("Required regular file is missing")
    if target.stat().st_nlink != 1:
        raise MaterialError("Hard-linked input rejected")
    return target


def read_text_material(base, relative):
    target = safe_file(base, relative)
    if target.stat().st_size > 2 * 1024 * 1024:
        raise MaterialError("Text material is unexpectedly large")
    data = target.read_bytes()
    data.decode("utf-8")
    if any(re.search(pattern, data) for pattern in SECRET_PATTERNS):
        raise MaterialError("Credential-shaped content rejected")
    return data


def native_screenshot_exif(width, height, *, uikit=False):
    """Full reviewed TIFF layouts, allowing only dimensions to follow IHDR.

    XCTest: Description=Screenshot, Orientation=1, UserComment=ASCII Screenshot.
    UIKit: Orientation=1, X/YResolution=216/1, ResolutionUnit=2, ColorSpace=1.
    Both contain only the reviewed IFDs and PixelX/YDimension. Exact comparison
    forbids other tags, offsets, hidden padding, GPS, timestamps and extra bytes.
    """
    if uikit:
        prefix = "4d4d002a000000080005011200030000000100010000011a0005000000010000004a011b0005000000010000005201280003000000010002000087690004000000010000005a00000000000000d800000001000000d8000000010003a00100030000000100010000a002000400000001"
        suffix = "00000000"
    else:
        prefix = "4d4d002a000000080003010e00020000000b0000003201120003000000010001000087690004000000010000003e0000000053637265656e73686f7400000003928600070000001200000068a002000400000001"
        suffix = "00000000415343494900000053637265656e73686f74"
    return bytes.fromhex(prefix) + struct.pack(">I", width) + bytes.fromhex("a003000400000001") + struct.pack(">I", height) + bytes.fromhex(suffix)


def png_info(data):
    """Check PNG integrity/RGB and only the exact reviewed native metadata."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise MaterialError("Not a PNG")
    position, width, height, saw_data, ended = 8, None, None, False, False
    seen = set()
    while position < len(data):
        if position + 12 > len(data):
            raise MaterialError("Truncated PNG")
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        end = position + 12 + length
        if end > len(data):
            raise MaterialError("Truncated PNG chunk")
        chunk = data[position + 8:position + 8 + length]
        checksum = struct.unpack(">I", data[position + 8 + length:end])[0]
        if zlib.crc32(kind + chunk) & 0xffffffff != checksum:
            raise MaterialError("PNG checksum mismatch")
        if width is None:
            if kind != b"IHDR" or length != 13:
                raise MaterialError("PNG header missing")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", chunk)
            if depth != 8 or color != 2 or compression or filtering or interlace:
                raise MaterialError("Screenshot must be a native 8-bit RGB PNG without alpha")
        elif kind == b"IHDR":
            raise MaterialError("Duplicate PNG header")
        if kind != b"IDAT" and kind in seen:
            raise MaterialError("Duplicate PNG metadata chunk")
        seen.add(kind)
        if kind == b"tRNS":
            raise MaterialError("PNG transparency is not permitted")
        if kind == b"eXIf":
            if chunk not in (native_screenshot_exif(width, height), native_screenshot_exif(width, height, uikit=True)):
                raise MaterialError("Unreviewed EXIF structure or dimensions")
        elif kind == b"iTXt":
            if chunk != NATIVE_SCREENSHOT_XMP:
                raise MaterialError("Unreviewed PNG text/XMP metadata")
        elif kind == b"sRGB":
            if chunk != b"\0":
                raise MaterialError("Unreviewed PNG color intent")
        elif kind == b"pHYs":
            if chunk != NATIVE_UIKIT_PHYS:
                raise MaterialError("Unreviewed PNG pixel density")
        elif kind == b"iDOT":
            if chunk != NATIVE_IAP_IDOT or (width, height) != (1206, 2622):
                raise MaterialError("Unreviewed PNG native data layout")
        elif kind not in {b"IHDR", b"IDAT", b"IEND"}:
            raise MaterialError("Unknown PNG metadata chunk")
        if kind == b"IDAT":
            saw_data = True
        if kind == b"IEND":
            if length or end != len(data):
                raise MaterialError("Invalid PNG ending")
            ended = True
            break
        position = end
    if not saw_data or not ended or not width or not height:
        raise MaterialError("Incomplete PNG")
    return width, height


def approved_image(base, entry):
    if not isinstance(entry, dict) or entry.get("approved") is not True:
        raise MaterialError("Screenshot has no explicit approval")
    locale, device, role = entry.get("locale"), entry.get("device"), entry.get("role")
    if locale not in LOCALES or device not in DEVICES or role not in ROLES:
        raise MaterialError("Unknown screenshot locale/device/role")
    relative = f"screenshots/{locale}/{device}/{ROLES[role]}"
    if entry.get("relative_path") != relative or relative not in STOREFRONT_PATHS:
        raise MaterialError("Screenshot is outside its approved storefront path")
    target = safe_file(base, relative)
    if target.stat().st_size > 25 * 1024 * 1024:
        raise MaterialError("Screenshot unexpectedly large")
    data = target.read_bytes()
    if not isinstance(entry.get("sha256"), str) or not re.fullmatch(r"[a-f0-9]{64}", entry["sha256"]):
        raise MaterialError("Screenshot SHA256 missing")
    if sha(data) != entry["sha256"]:
        raise MaterialError("Approved screenshot changed")
    if png_info(data) != DEVICES[device]:
        raise MaterialError("Screenshot dimensions do not match device")
    clean = {
        "relative_path": relative, "sha256": sha(data), "locale": locale,
        "device": device, "role": role, "approved": True,
        "width": DEVICES[device][0], "height": DEVICES[device][1], "has_alpha": False,
    }
    return relative, data, clean


def validate_storefront_coverage(identities):
    if identities != STOREFRONT_IDENTITIES:
        raise MaterialError("All twenty-nine reviewed screenshot roles are required; only en-US iPad local-bazi-preview is excluded")


def approved_iap_review(base, provenance, iap):
    """One explicitly approved fixture image, distinct from storefront captures."""
    if not isinstance(provenance, dict) or provenance.get("approved") is not True:
        raise MaterialError("IAP review screenshot has no explicit approval")
    if (provenance.get("version"), str(provenance.get("build"))) != (VERSION, BUILD):
        raise MaterialError("IAP review screenshot version/build mismatch")
    if (provenance.get("role"), provenance.get("relative_path"), provenance.get("rendered_view")) != ("iap_review", IAP_IMAGE, "AccountTopUpView"):
        raise MaterialError("Unexpected IAP review screenshot provenance")
    if provenance.get("fixture_no_financial_event") is not True or provenance.get("financial_event_performed") is not False or provenance.get("contains_private_user_data") is not False:
        raise MaterialError("IAP fixture / financial-event / private-data declaration missing")
    if provenance.get("product_id") != iap["productId"] or provenance.get("currency") != "CNY" or provenance.get("price_milliunits") != 6000:
        raise MaterialError("IAP fixture SKU/currency/price mismatch")
    if iap.get("reviewScreenshot", {}).get("file") != IAP_IMAGE:
        raise MaterialError("IAP metadata does not reference its approved review image")
    path = safe_file(base, IAP_IMAGE)
    if path.stat().st_size > 25 * 1024 * 1024:
        raise MaterialError("IAP review screenshot unexpectedly large")
    data = path.read_bytes()
    if sha(data) != provenance.get("sha256"):
        raise MaterialError("Approved IAP review screenshot changed")
    dimensions = png_info(data)
    if dimensions not in DEVICES.values():
        raise MaterialError("IAP review image dimensions are not a supported capture size")
    clean = {key: provenance[key] for key in (
        "version", "build", "role", "approved", "relative_path", "sha256", "rendered_view",
        "fixture_no_financial_event", "financial_event_performed", "contains_private_user_data",
        "product_id", "currency", "price_milliunits",
    )}
    clean.update({
        "width": dimensions[0], "height": dimensions[1], "app_review_only": True,
        "disclosure": "Actual AccountTopUpView rendered with an isolated CNY6 SKU fixture. No financial event, live Apple product lookup, or successful purchase is asserted. Not a storefront marketing screenshot.",
    })
    return data, clean


def check_metadata(documents):
    for locale in LOCALES:
        document = documents[f"metadata.{locale}.json"]
        if (document.get("version"), str(document.get("build"))) != (VERSION, BUILD):
            raise MaterialError("Metadata version/build mismatch")
        if document.get("status") != "draft_not_submitted":
            raise MaterialError("Metadata must retain its draft state")
        info, version = document["app_information_localization"], document["version_localization"]
        for value, limit in ((info["name"], 30), (info["subtitle"], 30), (version["promotionalText"], 170),
                             (version["description"], 4000), (version["keywords"], 100), (version["whatsNew"], 4000)):
            if not isinstance(value, str) or len(value) > limit:
                raise MaterialError("App Store text limit failed")
        if len(version["keywords"].encode("utf-8")) > 100:
            raise MaterialError("Keyword UTF-8 byte limit failed")
        prefix = f"https://wellecho.cn/xiazi/{locale}/"
        if info["privacyPolicyUrl"] != prefix + "privacy.html" or version["supportUrl"] != prefix + "support.html" or version["marketingUrl"] != prefix + "marketing.html":
            raise MaterialError("Unexpected review-package public URL")
        if document.get("public_url_verification", {}).get("external_reachability_verified") is not False:
            raise MaterialError("This material snapshot must preserve its pending external verification")
    labels = documents["privacy-labels.json"]
    if len(labels.get("types", [])) != 11 or labels.get("collects_data") is not True:
        raise MaterialError("Expected the reviewed eleven data types")
    for entry in labels["types"]:
        if entry.get("collected") is not True or entry.get("linked_to_user") is not True or entry.get("used_for_tracking") is not False:
            raise MaterialError("Unexpected privacy-label data/linkage/tracking declaration")
    if labels.get("provider_specific_final_confirmation_pending") is not True:
        raise MaterialError("Provider-specific confirmation must remain pending")
    additional = {entry["type"] for entry in labels["types"] if "OTHER_PURPOSES" in entry["purposes"]}
    if additional != {"NAME", "PRECISE_LOCATION", "COARSE_LOCATION", "OTHER_USER_CONTENT", "OTHER_DATA_TYPES"}:
        raise MaterialError("Provider-purpose scope differs from the reviewed draft")
    iap = documents["iap-metadata.json"]
    if iap.get("productId") != "com.lihao.BlindOracle.quota.1m" or iap.get("inAppPurchaseType") != "CONSUMABLE":
        raise MaterialError("Unexpected consumable SKU")
    for item in iap["localizations"]:
        if not 2 <= len(item["name"]) <= 30 or len(item["description"]) > 45:
            raise MaterialError("IAP localized text limit failed")


def sanitized_artifacts(document):
    if (document.get("version"), str(document.get("build"))) != (VERSION, BUILD):
        raise MaterialError("Final artifact record version/build mismatch")
    fields = ("archive_verified", "export_verified", "privacy_manifest_verified")
    if any(document.get(key) is not True for key in fields):
        raise MaterialError("Final archive/export/privacy-manifest checks are incomplete")
    upload = document.get("upload", {})
    if upload.get("record_complete") is not True or upload.get("status") not in {"not_uploaded", "uploaded", "processed"}:
        raise MaterialError("An explicit, complete upload-state record is required")
    result = {"version": VERSION, "build": BUILD, **{key: True for key in fields},
              "upload": {"record_complete": True, "status": upload["status"]}, "ipa_included": False}
    for key in ("testflight_internal_only", "submitted_for_review"):
        if key in upload:
            if not isinstance(upload[key], bool):
                raise MaterialError("Invalid upload-state boolean")
            result["upload"][key] = upload[key]
    if "ipa_sha256" in document:
        if not isinstance(document["ipa_sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", document["ipa_sha256"]):
            raise MaterialError("Invalid IPA SHA256")
        result["ipa_sha256"] = document["ipa_sha256"]
    return result


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def collect(base, artifact_record):
    payload, documents, errors, pending = {}, {}, [], []
    for relative in DOCUMENTS + WEB_FILES:
        try:
            data = read_text_material(base, relative)
            payload[relative] = data
            if relative.endswith(".json"):
                documents[relative] = json.loads(data)
                if not isinstance(documents[relative], dict):
                    raise MaterialError("Expected a JSON object")
            if relative.startswith("web/") and relative.endswith(".html"):
                if b"3.0.22 (48)" not in data or re.search(rb"<(?:script|form)\b", data, re.I):
                    raise MaterialError("Web page version or static-only check failed")
        except (OSError, UnicodeError, ValueError) as error:
            errors.append(f"{relative}: {type(error).__name__}")
    if not errors:
        try:
            check_metadata(documents)
            if len(payload["review-notes.txt"]) > 4000:
                raise MaterialError("Review notes exceed 4000 UTF-8 bytes")
        except (KeyError, TypeError, ValueError) as error:
            errors.append(f"Metadata validation: {str(error) if isinstance(error, MaterialError) else type(error).__name__}")
    approved = base / "screenshots-approved.json"
    clean_images, seen = [], set()
    if not approved.exists():
        pending.append("screenshots-approved.json is not ready")
    else:
        try:
            document = json.loads(read_text_material(base, "screenshots-approved.json"))
            if document.get("status") != "approved":
                raise MaterialError("Screenshot approval is not final")
            if (document.get("version"), str(document.get("build"))) != (VERSION, BUILD):
                raise MaterialError("Screenshot approval version/build mismatch")
            for entry in document["images"]:
                relative, data, clean = approved_image(base, entry)
                identity = (clean["locale"], clean["device"], clean["role"])
                if identity in seen:
                    raise MaterialError("Duplicate screenshot role")
                seen.add(identity); payload[relative] = data; clean_images.append(clean)
            validate_storefront_coverage(seen)
            payload["screenshots-approved.json"] = json_bytes({
                "version": VERSION, "build": BUILD, "status": "approved",
                "images": sorted(clean_images, key=lambda item: item["relative_path"]),
            })
        except (OSError, KeyError, TypeError, ValueError) as error:
            errors.append(f"Screenshot approval: {str(error) if isinstance(error, MaterialError) else type(error).__name__}")
    iap_review_approved = False
    if not (base / IAP_IMAGE).exists() or not (base / IAP_PROVENANCE).exists() or documents.get("iap-metadata.json", {}).get("reviewScreenshot", {}).get("file") is None:
        pending.append("Approved review-only IAP fixture screenshot / provenance / metadata reference is not ready")
    else:
        try:
            provenance = json.loads(read_text_material(base, IAP_PROVENANCE))
            data, clean = approved_iap_review(base, provenance, documents["iap-metadata.json"])
            payload[IAP_IMAGE] = data; payload[IAP_PROVENANCE] = json_bytes(clean)
            iap_review_approved = True
        except (OSError, KeyError, TypeError, ValueError) as error:
            errors.append(f"IAP review image: {str(error) if isinstance(error, MaterialError) else type(error).__name__}")
    artifacts = None
    if not (base / artifact_record).exists():
        pending.append("Final artifact/upload-state record is not ready")
    else:
        try:
            artifacts = sanitized_artifacts(json.loads(read_text_material(base, artifact_record)))
            payload["final-artifacts.json"] = json_bytes(artifacts)
        except (OSError, KeyError, TypeError, ValueError) as error:
            errors.append(f"Final artifact record: {str(error) if isinstance(error, MaterialError) else type(error).__name__}")
    report = {
        "version": VERSION, "build": BUILD, "status": "FAIL" if errors else "PENDING" if pending else "PASS_WITH_SUBMISSION_BLOCKERS",
        "errors": errors, "pending": pending, "approved_storefront_screenshots": len(clean_images),
        "expected_storefront_screenshots": len(STOREFRONT_IDENTITIES),
        "iap_review_fixture_screenshot_approved": iap_review_approved,
        "submission_ready": False, "external_reachability_verified": False,
        "asc_privacy_saved_or_published_by_this_tool": False,
        "submission_blockers": list(SUBMISSION_BLOCKERS), "ipa_included": False,
        "actions_performed": ["Offline file validation only"],
    }
    return payload, report


def zip_bytes(payload, report):
    prefix = f"BlindOracle-{VERSION}-{BUILD}-review-materials/"
    manifest = {"validation": report, "files": [
        {"path": name, "bytes": len(data), "sha256": sha(data)} for name, data in sorted(payload.items())
    ]}
    files = {**payload, "PACKAGE-CONTENTS.json": json_bytes(manifest)}
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            if name not in DOCUMENTS + WEB_FILES + ("screenshots-approved.json", "final-artifacts.json", "PACKAGE-CONTENTS.json", IAP_IMAGE, IAP_PROVENANCE) and name not in STOREFRONT_PATHS:
                raise MaterialError("Non-allowlisted archive member")
            info = zipfile.ZipInfo(prefix + name, date_time=(2026, 11, 7, 0, 0, 0))
            info.create_system = 3; info.external_attr = 0o100644 << 16; info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    return output.getvalue()


def self_test():
    class Guards(unittest.TestCase):
        def test_paths_reject_traversal_absolute_and_symlink(self):
            with tempfile.TemporaryDirectory() as folder:
                base = Path(folder); (base / "safe.txt").write_text("safe")
                (base / "link.txt").symlink_to(base / "safe.txt")
                self.assertEqual(safe_file(base, "safe.txt").read_text(), "safe")
                for name in ["../safe.txt", "/etc/passwd", "link.txt", "a\\safe.txt"]:
                    with self.subTest(name=name), self.assertRaises(MaterialError): safe_file(base, name)

        def test_credentials_rejected_without_printing_them(self):
            with tempfile.TemporaryDirectory() as folder:
                base = Path(folder); (base / "note.txt").write_text("oxa_" + "a" * 40)
                with self.assertRaises(MaterialError): read_text_material(base, "note.txt")

        def test_hard_link_rejected(self):
            with tempfile.TemporaryDirectory() as folder:
                base = Path(folder); (base / "a.txt").write_text("private")
                os.link(base / "a.txt", base / "b.txt")
                with self.assertRaises(MaterialError): safe_file(base, "b.txt")

        def test_review_evidence_cannot_be_approved_as_storefront(self):
            with tempfile.TemporaryDirectory() as folder:
                entry = {"approved": True, "locale": "en-US", "device": "iphone-large", "role": "question",
                         "relative_path": "review-evidence/phone.png", "sha256": "a" * 64}
                with self.assertRaises(MaterialError): approved_image(Path(folder), entry)

        def test_changed_approved_screenshot_rejected(self):
            with tempfile.TemporaryDirectory() as folder:
                base = Path(folder); relative = "screenshots/en-US/iphone-large/01-question.png"
                path = base / relative; path.parent.mkdir(parents=True); path.write_bytes(b"changed")
                entry = {"approved": True, "locale": "en-US", "device": "iphone-large", "role": "question",
                         "relative_path": relative, "sha256": "a" * 64}
                with self.assertRaises(MaterialError): approved_image(base, entry)

        def test_only_the_unapproved_english_ipad_preview_is_omitted(self):
            reviewed = set(itertools.product(LOCALES, DEVICES, ROLES))
            reviewed.remove(("en-US", "ipad-13", "local-bazi-preview"))
            self.assertEqual(len(reviewed), 29)
            validate_storefront_coverage(reviewed)
            self.assertNotIn("screenshots/en-US/ipad-13/05-local-bazi-preview.png", STOREFRONT_PATHS)
            for wrong in [reviewed - {("zh-Hans", "ipad-13", "local-bazi-preview")},
                          reviewed | {("en-US", "ipad-13", "local-bazi-preview")}]:
                with self.assertRaises(MaterialError): validate_storefront_coverage(wrong)

        def test_png_corruption_alpha_and_exif_rejected(self):
            def chunk(kind, data): return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
            def image(color=2, extra=b""):
                return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, color, 0, 0, 0)) + extra + chunk(b"IDAT", zlib.compress(b"\0" + b"\0" * 6) * 2) + chunk(b"IEND", b"")
            self.assertEqual(png_info(image()), (2, 2))
            for data in [image(6), image(extra=chunk(b"eXIf", b"test")), image()[:-1] + b"x"]:
                with self.assertRaises(MaterialError): png_info(data)

        def test_reviewed_native_exif_and_xmp_are_accepted_without_changing_bytes(self):
            def chunk(kind, data): return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
            for uikit in [False, True]:
                native = native_screenshot_exif(2, 2, uikit=uikit)
                self.assertEqual(len(native), 132 if uikit else 122)
                image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)) + chunk(b"eXIf", native) + chunk(b"iTXt", NATIVE_SCREENSHOT_XMP) + chunk(b"IDAT", zlib.compress(b"\0" + b"\0" * 6) * 2) + chunk(b"IEND", b"")
                before = sha(image)
                self.assertEqual(png_info(image), (2, 2))
                self.assertEqual(sha(image), before)

        def test_exif_gps_extra_fields_or_mismatching_dimensions_are_rejected(self):
            def chunk(kind, data): return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
            native = native_screenshot_exif(2, 2)
            bad = [native.replace(b"\x01\x0e", b"\x88\x25", 1), native + b"extra", native_screenshot_exif(3, 2), native_screenshot_exif(2, 3, uikit=True)]
            for metadata in bad:
                image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)) + chunk(b"eXIf", metadata) + chunk(b"IDAT", b"data") + chunk(b"IEND", b"")
                with self.assertRaises(MaterialError): png_info(image)

        def test_unknown_text_xmp_fields_and_transparency_remain_rejected(self):
            def chunk(kind, data): return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
            for kind, metadata in [(b"iTXt", NATIVE_SCREENSHOT_XMP.replace(b"</rdf:Description>", b"<exif:GPSLatitude>1</exif:GPSLatitude></rdf:Description>")), (b"tEXt", b"comment\0private"), (b"tRNS", b"\0" * 6), (b"abCd", b"extra")]:
                image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)) + chunk(kind, metadata) + chunk(b"IDAT", b"data") + chunk(b"IEND", b"")
                with self.assertRaises(MaterialError): png_info(image)

        def test_artifact_summary_discards_private_fields_and_accepts_truthful_no_upload(self):
            raw = {"version": VERSION, "build": BUILD, "archive_verified": True, "export_verified": True,
                   "privacy_manifest_verified": True, "upload": {"record_complete": True, "status": "not_uploaded", "private_log": "omit"}, "token": "omit"}
            clean = sanitized_artifacts(raw)
            self.assertNotIn("token", clean); self.assertNotIn("private_log", clean["upload"])

        def test_iap_review_requires_honest_fixture_and_private_data_declarations(self):
            provenance = {"version": VERSION, "build": BUILD, "role": "iap_review", "approved": True,
                          "relative_path": IAP_IMAGE, "rendered_view": "AccountTopUpView", "fixture_no_financial_event": False}
            with tempfile.TemporaryDirectory() as folder, self.assertRaises(MaterialError):
                approved_iap_review(Path(folder), provenance, {"productId": "com.lihao.BlindOracle.quota.1m"})

        def test_zip_is_repeatable_and_rejects_private_artifacts(self):
            report = {"submission_ready": False}
            first = zip_bytes({"SUBMISSION.txt": b"safe"}, report)
            self.assertEqual(first, zip_bytes({"SUBMISSION.txt": b"safe"}, report))
            with zipfile.ZipFile(io.BytesIO(first)) as archive:
                self.assertFalse(any("evidence" in name or ".p8" in name for name in archive.namelist()))
            for name in ["evidence/private.png", ".secrets/key.p8", "archive.xcresult/data", "review-evidence/phone.png", "app.ipa", "screenshots/../../key.p8", "screenshots/private-phone.png", "screenshots/en-US/ipad-13/05-local-bazi-preview.png"]:
                with self.subTest(name=name), self.assertRaises(MaterialError): zip_bytes({name: b"private"}, report)
    result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(Guards))
    return 0 if result.wasSuccessful() else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--check", action="store_true", help="Validate without creating a ZIP (default)")
    actions.add_argument("--assemble", action="store_true", help="Create the allowlisted ZIP after all inputs are approved")
    actions.add_argument("--self-test", action="store_true", help="Run offline path/secret/screenshot/ZIP safety checks")
    parser.add_argument("--artifact-record", default="final-artifacts.json", help="Safe final artifact summary relative to this directory")
    parser.add_argument("--output", default=f"BlindOracle-{VERSION}-{BUILD}-review-materials.zip", help="Output ZIP relative to this directory")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    # Validate these argument paths before checking existence; no private input paths.
    for value in [args.artifact_record, args.output]:
        if not value or "\\" in value or PurePosixPath(value).is_absolute() or ".." in PurePosixPath(value).parts or len(PurePosixPath(value).parts) != 1:
            parser.error("Artifact record and output must be filenames in the version directory")
    if not args.artifact_record.endswith(".json") or not args.output.endswith(".zip"):
        parser.error("Expected a JSON artifact summary and ZIP output")
    payload, report = collect(HERE, args.artifact_record)
    if args.assemble and not report["errors"] and not report["pending"]:
        output = HERE / args.output
        if output.is_symlink() or (output.exists() and not output.is_file()):
            parser.error("Output must be a regular file")
        data = zip_bytes(payload, report)
        fd, temporary = tempfile.mkstemp(prefix=".review-package-", suffix=".tmp", dir=HERE)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(data); stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, output)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
        report.update({"zip": output.name, "zip_sha256": sha(data), "zip_bytes": len(data), "file_count": len(payload) + 1})
        report["actions_performed"] = ["Offline validation", "Local allowlisted ZIP assembly; no IPA or uploads"]
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if report["errors"] else 2 if report["pending"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
