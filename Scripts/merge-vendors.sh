#!/bin/sh
# Merge every vendors/*.json file into a single vendors.json for the app bundle.
# Usage: merge-vendors.sh <vendors dir> <output file>
# Files are merged in filename order. Each file holds one vendor object.
set -eu
SRC="${1:?vendors directory}"
OUT="${2:?output file}"
mkdir -p "$(dirname "$OUT")"
/usr/bin/python3 - "$SRC" "$OUT" <<'PY'
import json, os, sys
src, out = sys.argv[1], sys.argv[2]
required = {"id", "name", "platform", "baseURL"}
vendors, seen = [], set()
for name in sorted(os.listdir(src)):
    if not name.endswith(".json"):
        continue
    with open(os.path.join(src, name)) as f:
        v = json.load(f)
    missing = required - set(v)
    if missing:
        sys.exit(f"{name}: missing keys {sorted(missing)}")
    if v["id"] in seen:
        sys.exit(f"{name}: duplicate vendor id {v['id']}")
    seen.add(v["id"])
    v.setdefault("enabled", True)
    v.setdefault("probes", [])
    vendors.append(v)
with open(out, "w") as f:
    json.dump({"version": 1, "vendors": vendors}, f, indent=2)
    f.write("\n")
print(f"merged {len(vendors)} vendors into {out}")
PY
