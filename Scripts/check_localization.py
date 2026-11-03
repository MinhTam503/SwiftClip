#!/usr/bin/env python3
"""Audit application-owned UI strings; clipboard data/protocol identifiers are not translated."""
from pathlib import Path
import json
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
source = root / "Sources/SwiftClip"
localizer = (source / "Localization.swift").read_text(encoding="utf-8")
key_block = localizer.split("enum Key: String, CaseIterable {", 1)[1].split("}", 1)[0]
keys = set(re.findall(r"case\s+(\w+)", key_block))
catalogs = {}
problems = []
for language in ["en", "vi"]:
    path = source / "Resources" / (language + ".lproj") / "Localizable.strings"
    catalog = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))
    catalogs[language] = catalog
    if set(catalog) != keys:
        problems.append(f"{language}: missing={sorted(keys-set(catalog))}; extra={sorted(set(catalog)-keys)}")
    occurrences = re.findall(r'^"([^"\n]+)"\s*=', path.read_text(encoding="utf-8"), re.M)
    if len(occurrences) != len(set(occurrences)):
        problems.append(f"{language}: duplicate localization keys")
for key in keys:
    values = [catalogs[language].get(key, "") for language in ["en", "vi"]]
    if not all(values):
        problems.append(f"{key}: empty translation")
    signatures = [re.findall(r"%[0-9$]*l?[d@]|%%", value) for value in values]
    if signatures[0] != signatures[1]:
        problems.append(f"{key}: placeholder mismatch {signatures}")
patterns = [
    re.compile(r'\b(?:Text|Button|Label|Section|Toggle|Picker|TextField)\s*\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\.(?:help|accessibilityLabel)\s*\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\b(?:title|messageText|informativeText)\s*[:=]\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'NSLocalizedDescriptionKey\s*:\s*"((?:[^"\\]|\\.)*)"'),
]
for path in source.glob("*.swift"):
    text = path.read_text(encoding="utf-8")
    for pattern in patterns:
        for match in pattern.finditer(text):
            if match.group(1):
                line = text.count("\n", 0, match.start()) + 1
                problems.append(f"{path.name}:{line}: hard-coded UI string: {match.group(1)}")
if problems:
    print("\n".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"Localization audit passed: {len(keys)} keys in both EN/VI; placeholder parity; no direct app-owned UI literals.")
