#!/usr/bin/env bash
# Rebuilds the manufacturer table the Network feature uses to name a device
# from its MAC address, from the IEEE MA-L registry.
#
# The IEEE site refuses scripted downloads, so the file is fetched by hand:
#   1. Open https://standards-oui.ieee.org/oui/oui.csv in a browser and save it.
#   2. Run: scripts/update-oui.sh ~/Downloads/oui.csv
#
# Writes SignalBarCore/Sources/SignalBarCore/Resources/oui.tsv: one
# "AABBCC<tab>Organization" line per prefix, sorted, nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:?usage: scripts/update-oui.sh path/to/oui.csv}"
OUTPUT="SignalBarCore/Sources/SignalBarCore/Resources/oui.tsv"

python3 -I - "$SOURCE" "$OUTPUT" <<'PY'
import csv, sys

source, output = sys.argv[1], sys.argv[2]
rows = {}
with open(source, newline="", encoding="utf-8") as handle:
    for record in csv.DictReader(handle):
        if record.get("Registry") != "MA-L":
            continue
        prefix = record.get("Assignment", "").strip().upper()
        name = " ".join(record.get("Organization Name", "").split())
        if len(prefix) == 6 and all(c in "0123456789ABCDEF" for c in prefix) and name:
            rows[prefix] = name.replace("\t", " ")

if len(rows) < 10000:
    sys.exit(f"Only {len(rows)} prefixes found; is {source} the IEEE oui.csv?")
with open(output, "w", encoding="utf-8") as handle:
    for prefix in sorted(rows):
        handle.write(f"{prefix}\t{rows[prefix]}\n")
print(f"Wrote {len(rows)} prefixes to {output}")
PY
