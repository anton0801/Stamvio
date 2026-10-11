#!/usr/bin/env python3
"""Checks Localizable.xcstrings against the keys used in Swift code.

- every key used in code exists in the catalog,
- every key has a translated value in EN/ES/RU/DE/FR (plural variations included),
- printf-style specifiers (%@, %lld, %d …) match across languages,
- reports keys in the catalog that are no longer used.

Dynamic keys (built from enum raw values) are expanded from DYNAMIC below.
Usage: python3 Tools/check_localization.py [--list-missing]
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "TimestampCameraWorkPhotos"
CATALOG = SOURCES / "Resources" / "Localizable.xcstrings"
LANGUAGES = ["en", "es", "ru", "de", "fr"]

STATIC_PATTERNS = [
    re.compile(r'\bL\(\s*"([A-Za-z0-9_.]+)"'),
    re.compile(r'\.t\(\s*"([A-Za-z0-9_.]+)"'),
]

ERROR_CODES = re.findall(r'case \w+ = "([A-Z]{3}-\d{3})"',
                         (SOURCES / "Core" / "AppError.swift").read_text())

DYNAMIC = {
    # AppError.messageKey
    "error.": ERROR_CODES,
    # PaywallTrigger.titleKey / messageKey
    "paywall.trigger.": [f"{t}.{p}" for t in ["secondProject", "freePhotos", "photoLimit", "beforeAfterExport", "branding",
                                               "batchExport", "brandPresets", "originalResolution", "reportLimit",
                                               "settings"] for p in ["title", "message"]],
    # SupportCategory.titleKey
    "support.category.": ["cameraImport", "dateLocation", "pdf", "purchase", "backup", "other"],
    # StampPositionPicker accessibility labels
    "stamp.position.": ["topLeft", "topRight", "bottomLeft", "bottomRight"],
    # stamp preset names (photo detail)
    "stamp.preset.": ["compact", "work", "location", "custom"],
    # HelpView topics
    "help.": [f"{t}.{p}" for t in ["location", "import", "missingDate", "largePDF", "restore", "offline", "proof"]
              for p in ["title", "body"]],
    # PhotoDateInfo.provenanceKey
    "provenance.time.": ["device", "imported", "importedNoZone", "manual", "unavailable"],
}

SPEC = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h|hh|q|z|t|j)?[@dDuUxXoOfFeEgGcCsSpaA%]')


def used_keys():
    keys = set()
    for path in SOURCES.rglob("*.swift"):
        text = path.read_text()
        for pattern in STATIC_PATTERNS:
            keys.update(pattern.findall(text))
    for prefix, values in DYNAMIC.items():
        keys.update(prefix + v for v in values)
    return keys


def specifiers(value):
    found = [s for s in SPEC.findall(value) if s != "%%"]
    normalized = []
    for s in found:
        kind = s[-1]
        if kind in "dDuUxXoO":
            kind = "int"
        normalized.append(kind)
    return sorted(normalized)


def values_for(entry, lang):
    """Returns [(plural category or None, value)] or None when not fully translated."""
    loc = entry.get("localizations", {}).get(lang)
    if not loc:
        return None
    if "stringUnit" in loc:
        unit = loc["stringUnit"]
        return [(None, unit.get("value", ""))] if unit.get("state") == "translated" else None
    plural = loc.get("variations", {}).get("plural")
    if plural:
        if "other" not in plural:
            return None
        out = []
        for category, form in plural.items():
            unit = form.get("stringUnit", {})
            if unit.get("state") != "translated":
                return None
            out.append((category, unit.get("value", "")))
        return out
    return None


def main():
    catalog = json.loads(CATALOG.read_text())
    strings = catalog["strings"]
    used = used_keys()
    problems = 0
    missing = sorted(k for k in used if k not in strings)
    for key in missing:
        print(f"MISSING in catalog: {key}")
    problems += len(missing)
    for key, entry in sorted(strings.items()):
        reference = values_for(entry, "en")
        if reference is None:
            print(f"NO ENGLISH: {key}")
            problems += 1
            continue
        ref_value = dict(reference).get("other", reference[-1][1])
        ref_spec = specifiers(ref_value)
        for lang in LANGUAGES:
            vals = values_for(entry, lang)
            if vals is None:
                print(f"UNTRANSLATED {lang}: {key}")
                problems += 1
                continue
            for category, value in vals:
                if not value.strip():
                    print(f"EMPTY {lang}: {key}")
                    problems += 1
                spec = specifiers(value)
                # A plural "one"/"zero" form may omit the number ("month" instead of "1 month").
                if spec != ref_spec and not (category in ("one", "zero") and not spec):
                    print(f"SPECIFIER MISMATCH {lang}: {key}: {value!r} vs en {ref_value!r}")
                    problems += 1
    unused = sorted(k for k in strings if k not in used)
    for key in unused:
        print(f"UNUSED: {key}")
    print(f"keys used: {len(used)}, in catalog: {len(strings)}, problems: {problems}, unused: {len(unused)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
