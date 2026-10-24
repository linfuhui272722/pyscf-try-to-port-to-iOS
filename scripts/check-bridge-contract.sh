#!/usr/bin/env bash
# Verify the Swift models decode exactly what the Python bridge emits.
#
# Step 1 generates fixtures by calling ``pyscf_mobile.bridge.handle_json`` with
# the same payloads the app sends.  Step 2 compiles the model types together
# with the assertions in ios/tests/BridgeContract and runs them on the host.
#
# The models depend only on Foundation, so a plain Linux Swift toolchain is
# enough — no iOS SDK required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/contract"
SWIFT="${HOST_SWIFT:-$(command -v swiftc || echo /tmp/swift-toolchain/usr/bin/swiftc)}"

mkdir -p "$OUT"

echo ">> generating fixtures from the Python bridge"
PYSCF_ROOT="$ROOT" python3 - "$OUT/fixtures.json" <<'PY'
import json, sys, os

sys.path.insert(0, os.path.join(os.environ["PYSCF_ROOT"], "src"))

from pyscf_mobile import bridge

WATER = "O 0 0 0; H 0 0 0.9584; H 0 0.9267 -0.2421"

def call(method, params):
    return bridge.handle_json(json.dumps({"id": 1, "method": method, "params": params}))

fixtures = {
    "capabilities": call("capabilities", {}),
    "elements": call("elements", {}),
    "presets": call("presets", {}),
    "geometry": call("geometry", {"atoms": WATER}),
    "scf": call("scf", {"atoms": WATER, "basis": "sto-3g", "method": "RHF", "include": ["grid", "mo"]}),
    "dft": call("dft", {"atoms": WATER, "basis": "sto-3g", "method": "RKS", "xc": "b3lyp", "include": []}),
    "mp2": call("mp2", {"atoms": WATER, "basis": "sto-3g", "reference": "RHF", "include": []}),
    "ccsd": call("ccsd", {"atoms": WATER, "basis": "sto-3g", "reference": "RHF", "include": []}),
    "bond_scan": call("bond_scan", {"atoms": WATER, "i": 0, "j": 1, "method": "RHF",
                                    "basis": "sto-3g", "steps": 5, "start": 0.7, "stop": 1.5}),
    "error": call("scf", {"atoms": "Xx 0 0 0", "basis": "sto-3g"}),
}

with open(sys.argv[1], "w") as handle:
    json.dump(fixtures, handle)
print(f"   wrote {len(fixtures)} fixtures to {sys.argv[1]}")
PY

echo ">> compiling the contract check"
LD_LIBRARY_PATH="/tmp/swift-libs:${LD_LIBRARY_PATH:-}" \
  "$SWIFT" -o "$OUT/contract" \
  "$ROOT/ios/tests/BridgeContract/main.swift" \
  "$ROOT/ios/PySCF/Models/PySCFModels.swift"

echo ">> running the contract check"
FIXTURES="$OUT/fixtures.json" "$OUT/contract"
