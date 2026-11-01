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

# Prefer the toolchain this repo downloaded, then anything on PATH.  A bare
# /tmp location is not used: /tmp does not survive a container restart, and a
# missing compiler then looked like a test failure rather than a setup gap.
if [ -n "${HOST_SWIFT:-}" ]; then
  SWIFT="$HOST_SWIFT"
elif [ -x "$ROOT/build/swift/usr/bin/swiftc" ]; then
  SWIFT="$ROOT/build/swift/usr/bin/swiftc"
else
  SWIFT="$(command -v swiftc || true)"
fi
if [ -z "$SWIFT" ] || [ ! -x "$SWIFT" ]; then
  echo "no Swift compiler found; run scripts/fetch-swift-ios.sh or set HOST_SWIFT" >&2
  exit 1
fi

# The Linux Swift toolchain links against ncurses6 and names its linker through
# the driver, so expose the aliases the loader and driver look for.  Everything
# is rebuilt here rather than assumed to be present in /tmp.
SWIFTLIBS="$OUT/swift-libs"
mkdir -p "$SWIFTLIBS"
for lib in libncursesw.so.6 libtinfo.so.6; do
  for candidate in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    if [ -e "$candidate/$lib" ] && [ ! -e "$SWIFTLIBS/$lib" ]; then
      ln -s "$candidate/$lib" "$SWIFTLIBS/$lib"
    fi
  done
done
if [ ! -e "$SWIFTLIBS/libncurses.so.6" ] && [ -e "$SWIFTLIBS/libncursesw.so.6" ]; then
  ln -s libncursesw.so.6 "$SWIFTLIBS/libncurses.so.6"
fi

# The Swift driver on Linux asks clang for -fuse-ld=gold, but gold is not
# installed everywhere and clang rejects the flag outright when it is absent.
# Expose the system linker under the name the driver requests.
LDSHIM="$OUT/ldshim"
mkdir -p "$LDSHIM"
if ! command -v ld.gold >/dev/null 2>&1 && [ ! -e "$LDSHIM/ld.gold" ]; then
  ln -s "$(command -v ld)" "$LDSHIM/ld.gold"
fi
PATH="$LDSHIM:$PATH"

mkdir -p "$OUT"

# Prefer the repository's interpreter, then anything on PATH.  The host image is
# reset between sessions and takes system packages with it, so a bare ``python3``
# finds no NumPy while the repo's own .venv still has it — which looks like a
# broken bridge rather than a missing dependency.
if [ -n "${HOST_PYTHON:-}" ]; then
  PYTHON="$HOST_PYTHON"
elif [ -x "$ROOT/.venv/bin/python" ]; then
  PYTHON="$ROOT/.venv/bin/python"
else
  PYTHON="$(command -v python3 || true)"
fi
if [ -z "$PYTHON" ] || [ ! -x "$PYTHON" ]; then
  echo "no Python interpreter found; run scripts/host-test-env.sh setup or set HOST_PYTHON" >&2
  exit 1
fi

echo ">> generating fixtures from the Python bridge"
# PySCF's own shared libraries link against a BLAS that the host image does not
# keep, so the repository carries a copy and it has to be on the loader path.
# Same reason as the interpreter above: without it the import fails and reads as
# a broken bridge.
PYSCF_ROOT="$ROOT" LD_LIBRARY_PATH="$ROOT/.venv/lib/blas${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$PYTHON" - "$OUT/fixtures.json" <<'PY'
import json, sys, os

# ``src`` for the package, and the repository root for the in-tree PySCF build.
# The root is added explicitly rather than relied on as the working directory,
# because the script is runnable from anywhere and a missing PySCF reads as a
# broken bridge rather than a path that was never set.
_ROOT = os.environ["PYSCF_ROOT"]
sys.path.insert(0, os.path.join(_ROOT, "src"))
sys.path.insert(0, _ROOT)

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
    # Intrinsic localisation is opt-in, so it needs its own fixture: the panel
    # is driven by a field the default SCF call does not produce.
    "scf_localized": call("scf", {"atoms": WATER, "basis": "6-31g", "method": "RHF",
                                  "include": ["localization"]}),
    "scf_boys": call("scf", {"atoms": WATER, "basis": "6-31g", "method": "RHF",
                             "include": ["localization:boys"]}),
    # The 3D viewer draws an isosurface rather than a slice.  Two fixtures: a
    # canonical MO, whose two lobes are on opposite sides of the plane, and a
    # localised orbital, which is the picture that reads as a bond or lone pair.
    # The resolution is deliberately below the app's default to keep the fixture
    # small; the geometry rules do not depend on it.
    "orbital_surface": call("orbital_surface", {"atoms": WATER, "basis": "sto-3g", "method": "RHF",
                                                "source": "mo", "index": 4, "pointsPerAxis": 24}),
    "orbital_surface_lmo": call("orbital_surface", {"atoms": WATER, "basis": "sto-3g", "method": "RHF",
                                                    "source": "pm-mulliken", "index": 0,
                                                    "pointsPerAxis": 24}),
    # The Density screen draws the total density the same way, as one surface at
    # a single contour coloured by the density at each atom's nucleus, rather
    # than as a plane through the cube.  The contour is the app's default and the
    # resolution is below the app's, both to keep the fixture small: the
    # colouring and framing rules do not depend on either.
    "density_surface": call("density_surface", {"atoms": WATER, "basis": "sto-3g", "method": "RHF",
                                                "level": 0.002, "pointsPerAxis": 24}),
    "mp2": call("mp2", {"atoms": WATER, "basis": "sto-3g", "reference": "RHF", "include": []}),
    "ccsd": call("ccsd", {"atoms": WATER, "basis": "sto-3g", "reference": "RHF", "include": []}),
    "bond_scan": call("bond_scan", {"atoms": WATER, "i": 0, "j": 1, "method": "RHF",
                                    "basis": "sto-3g", "steps": 5, "start": 0.7, "stop": 1.5}),
    # Geometry relaxation.  A stretched water so the relaxation actually has
    # something to do and the payload carries a multi-step trajectory.
    "optimise": call("optimise", {"atoms": "O 0 0 0; H 0 0 1.30; H 0 1.10 -0.30",
                                  "method": "RKS", "xc": "b3lyp", "basis": "sto-3g",
                                  "maxSteps": 30, "include": ["mo"]}),
    # Density fitting, forced on for a molecule that would not select it.  The
    # engine decides from the basis-function count by default; this proves the
    # explicit override travels through the bridge and still converges.
    "optimise_df": call("optimise", {"atoms": "O 0 0 0; H 0 0 1.30; H 0 1.10 -0.30",
                                     "method": "RHF", "basis": "6-31g",
                                     "maxSteps": 30, "densityFit": True}),
    # Explicitly off, on a molecule large enough that the engine would otherwise
    # turn it on.  A ``false`` here has to survive as a decision rather than be
    # read as "unset", which is the difference the UI's three-way choice makes.
    "optimise_no_df": call("optimise", {"atoms": "O 0 0 0; H 0 0 1.30; H 0 1.10 -0.30",
                                        "method": "RHF", "basis": "6-31g",
                                        "maxSteps": 30, "densityFit": False}),
    "error": call("scf", {"atoms": "Xx 0 0 0", "basis": "sto-3g"}),
    # E(2) over the CLPO Lewis orbitals.  The payload is nested twice over: the
    # interactions carry their own per-pair energies, and the orbitals are a
    # separate list, so a model that reads only the top level decodes as a set of
    # zeroes and still renders.  The default SCF payload does not contain these
    # fields at all, so this needs its own fixture.
    "perturbation": call("e2", {"atoms": WATER, "basis": "6-31g", "method": "RHF"}),
    # The plain LPO set, which is a different orbital choice and so a different
    # set of numbers; the two must not be conflated in the UI.
    "perturbation_lpo": call("e2", {"atoms": WATER, "basis": "6-31g", "method": "RHF",
                                    "kind": "lpo"}),
    # A periodic cell.  The cell summary is the part a molecular payload does not
    # have, and the analyses that are deliberately absent for a cell are reported
    # as absent rather than omitted, so the model has to decode both.
    "scf_cell": call("scf", {"atoms": "Si 0 0 0; Si 0.25 0.25 0.25",
                             "lattice": [[5.43, 0, 0], [0, 5.43, 0], [0, 0, 5.43]],
                             "dimension": 3, "method": "RHF", "include": []}),
}

with open(sys.argv[1], "w") as handle:
    json.dump(fixtures, handle)
print(f"   wrote {len(fixtures)} fixtures to {sys.argv[1]}")
PY

echo ">> compiling the contract check"
LD_LIBRARY_PATH="$SWIFTLIBS:${LD_LIBRARY_PATH:-}" \
  "$SWIFT" -o "$OUT/contract" \
  "$ROOT/ios/tests/BridgeContract/main.swift" \
  "$ROOT/ios/PySCF/Models/PySCFModels.swift" \
  "$ROOT/ios/PySCF/Models/DensityPalette.swift" \
  "$ROOT/ios/PySCF/Views/OrbitalMesh.swift"

echo ">> running the contract check"
FIXTURES="$OUT/fixtures.json" "$OUT/contract"

# The preview's sizing and framing rules are plain Foundation so they can be
# tested here; SceneKit itself only exists on iOS, and a scene with wrong
# sphere radii still renders - it just looks empty, which no device-side
# screenshot catches.
echo ">> compiling the preview layout checks"
LD_LIBRARY_PATH="$SWIFTLIBS:${LD_LIBRARY_PATH:-}" \
  "$SWIFT" -o "$OUT/layout" \
  "$ROOT/ios/tests/LayoutTests/main.swift" \
  "$ROOT/ios/PySCF/Models/PySCFModels.swift" \
  "$ROOT/ios/PySCF/Models/Formatting.swift" \
  "$ROOT/ios/PySCF/Models/DensityPalette.swift" \
  "$ROOT/ios/PySCF/Views/OrbitalMesh.swift" \
  "$ROOT/ios/PySCF/Views/MoleculeLayout.swift"

echo ">> running the preview layout checks"
FIXTURES="$OUT/fixtures.json" "$OUT/layout"

# The history store and its text export are Foundation only, so the same host
# toolchain checks them. Their failures are silent on a device -- a dropped
# field still lists, an empty section still exports -- which is why they are
# driven through a real directory and read back rather than unit-tested in
# isolation.
echo ">> compiling the history checks"
LD_LIBRARY_PATH="$SWIFTLIBS:${LD_LIBRARY_PATH:-}" \
  "$SWIFT" -o "$OUT/history" \
  "$ROOT/ios/tests/HistoryTests/main.swift" \
  "$ROOT/ios/PySCF/Models/PySCFModels.swift" \
  "$ROOT/ios/PySCF/Models/Formatting.swift" \
  "$ROOT/ios/PySCF/Models/AtomSpec.swift" \
  "$ROOT/ios/PySCF/Models/DensityPalette.swift" \
  "$ROOT/ios/PySCF/Models/HistoryEntry.swift" \
  "$ROOT/ios/PySCF/Models/ViewRecords.swift" \
  "$ROOT/ios/PySCF/Models/HistoryStore.swift" \
  "$ROOT/ios/PySCF/Models/HistoryGrouping.swift" \
  "$ROOT/ios/PySCF/Models/HistoryReport.swift"

echo ">> running the history checks"
FIXTURES="$OUT/fixtures.json" "$OUT/history"
