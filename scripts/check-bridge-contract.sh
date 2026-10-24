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

BENZENE = ("C 1.3965 0 0; C 0.69825 1.2095 0; C -0.69825 1.2095 0; C -1.3965 0 0; "
           "C -0.69825 -1.2095 0; C 0.69825 -1.2095 0; H 2.4793 0 0; H 1.23965 2.1472 0; "
           "H -1.23965 2.1472 0; H -2.4793 0 0; H -1.23965 -2.1472 0; H 1.23965 -2.1472 0")

ETHANOL = ("C -1.2 0.2 0; C 0.1 -0.5 0; O 1.2 0.4 0; H -2.0 0.5 0.6; H -1.3 0.8 -0.8; "
           "H -1.3 -0.7 -0.4; H 0.2 -1.1 0.8; H 0.2 -1.1 -0.8; H 1.9 0.0 0.3")

def call(method, params):
    return bridge.handle_json(json.dumps({"id": 1, "method": method, "params": params}))

fixtures = {
    "capabilities": call("capabilities", {}),
    "elements": call("elements", {}),
    "presets": call("presets", {}),
    "geometry": call("geometry", {"atoms": WATER}),
    # Extra geometries for the preview-layout checks: one large molecule, one
    # two-atom molecule and a lone atom.  The layout rules must hold for all of
    # them, which is the whole point - the old sizing came out of the molecule's
    # own extent, so the same element rendered at a different size in each.
    "geometry_benzene": call("geometry", {"atoms": BENZENE}),
    "geometry_ethanol": call("geometry", {"atoms": ETHANOL}),
    "geometry_h2": call("geometry", {"atoms": "H 0 0 0; H 0 0 0.7414"}),
    "geometry_helium": call("geometry", {"atoms": "He 0 0 0"}),
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

# The preview's sizing and framing rules are plain Foundation so they can be
# tested here; SceneKit itself only exists on iOS, and a scene with wrong
# sphere radii still renders - it just looks empty, which no device-side
# screenshot catches.
echo ">> compiling the preview layout checks"
LD_LIBRARY_PATH="/tmp/swift-libs:${LD_LIBRARY_PATH:-}" \
  "$SWIFT" -o "$OUT/layout" \
  "$ROOT/ios/tests/LayoutTests/main.swift" \
  "$ROOT/ios/PySCF/Models/PySCFModels.swift" \
  "$ROOT/ios/PySCF/Views/MoleculeLayout.swift"

echo ">> running the preview layout checks"
FIXTURES="$OUT/fixtures.json" "$OUT/layout"
