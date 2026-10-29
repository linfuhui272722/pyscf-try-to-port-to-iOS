# AGENTS.md

PySCF ported to iOS: the PySCF quantum-chemistry engine cross-compiled to
arm64 iOS, wrapped in a SwiftUI app with an embedded CPython interpreter.

## Layout

```
src/pyscf_mobile/     Python engine + JSON-RPC bridge (the thing iOS imports)
ios/PySCF/            SwiftUI app sources
ios/tests/            host-side Swift tests (not part of the app target)
tests/                Python test suite
scripts/              toolchain + build scripts
build/                all generated artefacts (not source; safe to delete)
```

## Build pipeline

Run in this order. Each step is incremental and skips work already done, so
re-running the whole list is cheap. Everything installs under `build/`, so a
fresh clone only needs network access on the first run.

```bash
scripts/setup-ios-toolchain.sh   # iOS SDK 15.6 + Darwin cross-toolchain
scripts/fetch-swift-ios.sh       # Linux Swift 5.6 toolchain (with ld64.lld)
scripts/build-numpy-ios.sh       # NumPy wheel for arm64 iOS
scripts/build-libomp-ios.sh      # OpenMP runtime (libomp) for arm64 iOS
scripts/build-pyscf-ios.sh       # PySCF + libcint/libxc + native ext
scripts/build-ios-app.sh         # assemble PySCF.app
```

Downloads are pinned and checksum-verified:

| Artefact | Source | Installed to |
|---|---|---|
| iPhoneOS15.6.sdk | `theos/sdks` release `master-146e41f` | `build/sdk/` |
| Darwin toolchain | `L1ghtmann/llvm-project` release `test-210562a` | `build/toolchain/` |
| Swift 5.6 | `download.swift.org` ubuntu20.04 release | `build/swift/` |
| libomp | `llvm/llvm-project` commit `1fdec59b` (`llvmorg-11.1.0`) | `build/src/llvm-openmp-11.1.0/` |

Pin new versions by updating the URL *and* the matching `*_SHA256` default in
the script; an unpinned `latest` URL would silently change the bytes and
invalidate the hash.

`build-ios-app.sh` depends on the earlier steps having populated `build/`; it
fails fast with a message naming the script to run when something is missing.

## Verification

```bash
python3 tests/run_tests.py          # Python engine + vendored-shim tests
scripts/check-bridge-contract.sh    # Swift models decode real bridge JSON
                                    #   (also runs ios/tests/LayoutTests and
                                    #   ios/tests/HistoryTests)
scripts/validate-ios-app.sh         # the built .app is a genuine iOS bundle
```

All three must pass before the app is considered good. They are cheap (a few
seconds each except the Python suite) and each catches a different class of
breakage:

* `run_tests.py` — chemistry correctness and the vendored SciPy/h5py shims.
* `check-bridge-contract.sh` — a field renamed in Python silently breaks the UI
  at runtime; this turns that into a test failure.
* `ios/tests/LayoutTests` — the 3D preview's sizing and framing rules. A wrong
  radius or camera distance still produces a valid scene, so it renders as an
  empty-looking molecule rather than an error.
* `ios/tests/HistoryTests` — the saved-calculation store and its text export.
  Both failures are silent on a device: a field dropped on the way to disk still
  lists and still shows energies, and an export with an empty section still
  produces a file. The checks drive real entries through a real directory.
* `validate-ios-app.sh` — architecture, min-OS, dependency closure, and
  accidental host-path leakage in the shipped bundle.

## Non-obvious constraints

These all cost real debugging time; do not "clean them up".

**Density fitting helps the gradient and hurts the SCF, so it is opt-in.**
`_wants_density_fit` returns False for a plain request; only
`run_geometry_optimisation` turns it on by itself, and only once
`mol.nao_nr() >= DENSITY_FIT_MIN_BASIS` (24).

The asymmetry is the whole point and is easy to get backwards. DF removes the
four-centre two-electron integrals, which dominate a *gradient* -- benzene in
6-31G goes 2.8x faster. A *single-point* SCF has no such gradient work to
remove, so the auxiliary basis build and its three-centre integrals are pure
added cost: measured on the alkanes in 6-31G, a density-fitted SCF is slower at
every size tried, from ethane (0.30x) to C16H34 with 208 functions (0.65x).
Enabling DF globally therefore makes every single-point calculation slower *and*
silently shifts its energy by up to 7e-4 Ha with nothing in the payload to say
so. Keep it on the optimiser path.

Below the crossover a relaxation is slower with DF too -- methane runs 6x slower
-- so the size gate matters there as well. `densityFit` in a request overrides
the choice in either direction, and the optimiser forwards it through the `base`
whitelist; a key missing from that list is silently dropped, so the setting
looks inert.

The approximation enters through the two-electron integrals only. Measured over
every basis in `BASIS_SETS`, on water and on benzene, the energy moves by at most
7e-4 Ha and the gradient by at most 5e-5 Ha/Bohr. The gradient bound is what
governs a relaxation, and it sits an order of magnitude below the default
`convTolGrad` of 3e-4, so both paths stop in the same place (measured agreement:
3e-5 A in the coordinates, identical step counts).

**NBO is not available, and NPA is not a substitute for it.** PySCF ships
`pyscf/lo/nao.py`, which builds natural atomic orbitals -- the *first* step of
Weinhold's NBO method -- and nothing beyond it. There is no NBO transform, no
E(2) second-order perturbation analysis, and no natural bond orbital output
anywhere in the tree. This is not a gap in PySCF's packaging: the reference NBO
implementation (NBO6/NBO7) is licensed software, and the other packages that
advertise NBO do not contain an implementation either. Psi4's `write_nbo()` is
the clearest example -- it writes a `$GENNBO` input file for the proprietary
binary to read, and Psi4 itself computes nothing.

`src/pyscf_mobile/nbo.py` therefore implements only the population half, which
is exact and checkable. Two shortcuts to the orbital half were tried and both
give demonstrably wrong answers, so do not "finish the job" by re-adding either:

* Diagonalising the density over the whole NAO space returns *natural orbitals*.
  The Fock matrix is diagonal in that basis, so every E(2) comes out identically
  zero -- a silent, plausible-looking empty result.
* Building bond and lone-pair orbitals from the natural hybrid orbitals in one
  shot gives water O-H occupancies of 1.62 against the correct 1.9998, and E(2)
  values of 250+ kcal/mol against the correct 7-12.

The reason is that NAOs are orthonormal, so cross-atom NHO overlap is zero and
cannot identify a bond; bonds must be found by density coupling instead. Getting
the occupancies right then needs the published iterative sequence of 2x2
rotations, which is the part that is not openly specified. A wrong E(2) is worse
than no E(2) in a chemistry tool, so the module stops at NPA and says so in its
docstring.

NPA itself is worth having on its own: its charges are basis-set stable (water's
oxygen is -0.95 in 6-31G, -0.96 in 6-31G\*, -0.92 in cc-pVDZ) where Mulliken
moves by more than half an electron over the same three bases, so the results
view shows both. `tests/test_nbo.py` pins the charges against published NPA
values and asserts the Mulliken drift as the contrast.

One trap when reading the output: the shell labels must be the *natural* ones,
not the basis set's. 6-31G's valence s contraction is labelled `3s` in the
basis, but NBO reports it as 2s, and cc-pVDZ packs 1s and 2s into a single
shell -- numbering by shell there merges the core with the valence and reports
a 1s population near 4. Number the distinct basis labels per atom and angular
momentum instead.

**Never filter the package tree by a list of file extensions.** The staging step
in `build-pyscf-ios.sh` used to copy `*.py` and `*.dat`, which dropped
`pyscf/gto/basis/bse_meta.json`. `pyscf/gto/mole.py` opens that file while it is
being imported, so `import pyscf` raised `FileNotFoundError` and the engine
reported itself unavailable — while the bridge, NumPy and all 107 signed shared
libraries loaded fine. The same filter was also silently dropping
`GTH_POTENTIALS`, `POTENTIAL_UZH`, `BASIS_MOLOPT*`, `HFX_BASIS` and
`GTH_BASIS_SETS`, which the CP2K parsers open. Data files that are *opened*
rather than *imported* have no distinguishing extension, and `bse_meta.json` is
the only `.json` in the tree, so an allowlist will always be incomplete. Copy
everything and exclude build sources by name. `validate-ios-app.sh` checks that
the known runtime data files are present, because the build host cannot: the
source tree always has them, so nothing fails until the app runs on a device.

**Every Mach-O in the bundle must be signed, not just the executable.** On arm64
iOS the kernel refuses to map an image that carries no code signature, so
`dlopen` of an unsigned `.so` fails and CPython reports it as `ImportError` for
the module inside it. The failure looks like a missing or unlinked library, and
it is not: the file is present, correctly linked, and the right platform. It
happens because signing only `CFBundleExecutable` leaves the Python framework and
all ~106 extension modules unsigned. `build-ios-app.sh` now signs every file
whose magic identifies it as a Mach-O, and `validate-ios-app.sh` fails the build
if any image lacks `LC_CODE_SIGNATURE` — with a companion check that at least one
image *is* signed, so the rule cannot pass vacuously.

The symptom that identifies this class of bug: pure Python loads, so the
JSON-RPC envelope resolves and `protocol v1 · package 0.1.0` renders in the
footer, while every native import fails. When part of the payload works, the
problem is in what is missing from it, not in how it is reached.

**A `.strings` file in the bundle must be a *binary* plist.** iOS ignores a
text `.strings` file inside an `.lproj` directory: every `NSLocalizedString`
lookup falls through to the development language, so the app renders entirely in
English and looks like the translation was never wired up. Xcode compiles
`.strings` during a normal build; a hand-assembled bundle has no such step, so
`build-ios-app.sh` runs `scripts/compile-strings.py` on each `.lproj` and
`validate-ios-app.sh` fails the build if it finds a text file. The validator also
requires that both languages define the same keys and that their format
specifiers agree, since a key missing from one table reverts that one screen to
English and a `%@`/`%d` mismatch crashes only on the affected language.

**The 3D preview must not size atoms from the molecule's own extent.** Deriving
the sphere radius from the geometry's bounding radius made the same element
render at 0.079 Å in water and 0.180 Å in benzene, and water — whose whole extent
is under 1 Å — came out as specks about 4% of a bond length across. The camera
was also placed at 6.8× the bounding radius, filling 37% of the viewport. Sizing
and framing now live in `MoleculeLayout.swift`, which is Foundation only so
`ios/tests/LayoutTests` can assert them on the build host. SceneKit exists only
on iOS, and a scene with wrong radii still renders — it just looks empty — so
nothing on the device reports this class of bug.

**`updateUIView` must not replace the scene.** It runs on every keystroke in the
atom editor. Assigning a new `SCNScene` resets `pointOfView`, so the molecule
snapped back to its start orientation while the user was rotating it. The
renderer updates the node graph in place and only reframes the camera, preserving
its current orbit direction.

**Never put a top-level `Resources` directory in the .app.** A `Resources`
folder is a *macOS* bundle convention, not an iOS one. iOS apps keep resources at
the top level of the `.app`. MobileInstallation rejects a bundle that contains a
top-level `Resources` directory during package inspection, before registration,
and TrollStore reports it as exit 181 *after* signing has already succeeded. So
the log shows a valid signature and a complete registration dictionary and still
fails, which makes it look like a plist or Mach-O problem when it is not.

The runtime therefore lives at `<app>/python`, not `<app>/Resources/python`.
`validate-ios-app.sh` fails the build if a top-level `Resources` directory
appears. This cost four releases' worth of wrong fixes (plist formats, Mach-O
headers, fat binaries) before a probe that renamed the directory found it. When
an install fails, bisect the bundle before theorising about its contents.

**The JSON-RPC envelope is nested.** The Python bridge returns
`{"jsonrpc": "2.0", "id": N, "result": {...}}`, and `RPCResponse.decode` unwraps
the `result` level. Models read the payload's own fields, so they must be handed
the inner object. If a view shows placeholder values everywhere at once
("Engine unavailable", "unknown", `v0`, `0.0.0`, an empty basis menu), suspect a
missing unwrap rather than a broken interpreter: every field falling back to its
default is the signature.

The contract test in `ios/tests/BridgeContract` must decode through
`RPCResponse.decode`, never by reaching into `"result"` itself. The earlier
version did that by hand, which duplicated the very step the app got wrong and
hid the bug on device.

**Cross-compiling from Linux.** Apple's toolchain cannot run on Linux, so the
build uses the Darwin cross-toolchain from `L1ghtmann/llvm-project` (clang,
`ld`, `install_name_tool`) plus `ld64.lld`. LLD 13, shipped in the Swift 5.6
Linux toolchain, is the only version that accepts `-platform_version ios`; the
newer LLD 17 refuses iOS outright. Keep LLD 13 for linking.

`install_name_tool` in that toolchain is a no-op — it exits successfully without
modifying anything. Load commands must therefore be produced correctly at link
time; post-processing a binary is not an option.

**`find_package(OpenMP)` must be answered, not probed.** The module decides by
compiling *and running* a program, so while cross-compiling it always fails and
PySCF quietly builds serial code — the build succeeds, the library is correct,
and the only symptom is that one core is used. `ios-cmake-arch.inc` pre-defines
`OpenMP_<lang>_FLAGS`, `OpenMP_<lang>_LIB_NAMES`, `OpenMP_omp_LIBRARY` and
`OpenMP_<lang>_INCLUDE_DIR`; when those are already set, the module skips its
probe and reports success. It must be done for **both** C and CXX: the project
enables both languages, and `OpenMP_FOUND` is only true when *every* loaded
language was found. Answering C alone leaves it false, which looks exactly like
OpenMP not being wired up at all. Confirm with `Found OpenMP: TRUE` in
`build/logs/pyscf-configure.log`, then check that the extensions really
reference `___kmpc_fork_call` — `config.h` only switches on `_OPENMP`, so it
cannot tell you whether the flag reached the compile line.

**libomp needs two source patches, both carried in the build script.** LLVM
11.1.0 is pinned deliberately: libomp and clang must agree on the ABI the
compiler emits for `#pragma omp`, so the runtime is built from the same release
as the cross-toolchain's clang. Two things then break on iOS:

* `z_Linux_asm.S` emits `.size` in the AARCH64 critical-section block. That is
  an ELF directive and the Mach-O assembler rejects the whole file, so the
  library never links. The Darwin branch needs the underscored symbol and no
  `.size`. This one only shows up at link time, after every C++ file has
  compiled.
* `kmp_atomic.cpp` calls `__divdc3`/`__divsc3`. Those live in compiler-rt,
  which iOS does not ship, and `ld64.lld` will not resolve them out of
  libSystem's `.tbd` even though it lists them. The two canonical
  implementations are compiled into libomp instead.

Do not "clean up" the guard on the first patch to a simple grep for the
underscored symbol: the x86 Darwin block already defines it, so that test
matches on the unpatched file and the patch is silently skipped.

**libomp is a `.so`, not a `.dylib`.** `ios-cmake-project-include.cmake`
overrides the shared-library suffix for *every* target, including this one, so
CMake links `libomp.so`. PySCF links it by absolute path rather than `-lomp`
(so the OpenMP target carries the location), and the extension modules already
have an `@loader_path` rpath, which is what lets `@rpath/libomp.so` resolve once
it is copied beside them. Name it `libomp.dylib` anywhere in this pipeline and
the link will succeed while every import fails at runtime.

**`-lPython` and the framework modulemap.** `Python.framework`'s modulemap
contains `link "Python"`, so Swift autolinking emits `-lPython`. ld64 would find
`Python.framework/Python`, but LLD only searches `-L` paths, so
`build-ios-app.sh` creates `build/products/ios-arm64/lib/libPython.dylib` as a
symlink to the framework binary. Do not remove it.

**LC_RPATH is `0x8000001C`, not `0x1F`.** `LC_RPATH` is `LC_REQ_DYLD | 0x1C`.
Parsing it as `0x1F` reports "no rpath" for binaries that have one. The rpath
*is* present in the linked executable; the Swift driver just does not print it.

**Symlinked shared libraries.** The PySCF wheel expresses versioned libraries as
symlinks (`libcint.so -> libcint.6.so -> libcint.6.1.3.so`). `cp -R` and tar
materialise these as full copies, which triples the size of the largest
libraries (~96 MB of waste). The build collapses byte-identical siblings back
into symlinks; grouping must be by size+hash only, since a filename-based key
misses `libcint.so` vs `libcint.6.1.3.so`.

**Python home location.** On iOS `Bundle.main.resourceURL` *is* the `.app`
directory, while the payload is staged under `Resources/python`. `PythonBridge`
checks both locations. Staging under `python/` instead would also work, but the
dual lookup keeps the layout free to change.

**The Swift driver adds `<resource-dir>/iphoneos` to `-L`.** Harmless, but it
warns on every link unless that directory exists, so the build creates it.

**NumPy's `__config__.py` embeds the build host's paths.** It is diagnostic only;
the build rewrites the build root to `<build-host>` so the shipped bundle does
not carry the developer's directory layout.

## Swift / UI

The app targets **iOS 15.6**. Do not use iOS 16-only APIs; the following have
already been substituted once and must not creep back:

* `NavigationView`, not `NavigationSplitView` or `NavigationStack`.
* No `.autocorrectionDisabled()`, and no `.never` text-input autocapitalisation
  values.
* Keep view bodies simple enough for the type checker; a single large
  expression in `PlotViews.swift` previously caused a slow type-check failure
  and had to be split into smaller pieces.

The Python bridge is a serial queue that holds the GIL around every request, so
`PythonBridge.call` is safe from any actor. `handle_json` never raises — all
failures come back as JSON-RPC error objects.

**The interpreter must release the GIL after boot.** `Py_Initialize()` leaves the
GIL held by the calling thread and never releases it. `PySCFEngine.run()`
dispatches every request onto the global concurrent queue, so the request that
boots the interpreter succeeds and the next one, running on a different thread,
blocks forever inside `PyGILState_Ensure`. The visible symptom is a panel stuck
on "Loading presets…" rather than an error. `PythonBridge.boot` therefore calls
`PyEval_SaveThread()` immediately after `Py_Initialize()`, and
`validate-ios-app.sh` asserts the built binary imports `_PyEval_SaveThread`.

`PyEval_SaveThread` is declared in the framework's top-level `ceval.h`, which the
module map exposes to Swift. The `cpython/ceval.h` exclusion in the module map
does not hide it.

`check-bridge-contract.sh` runs on the host, so it must build its own ncurses and
linker aliases. Do not reintroduce a hardcoded `/tmp/swift-toolchain` or
`/tmp/swift-libs` path: `/tmp` does not survive a container restart, and a missing
compiler then looks like a test failure rather than a setup gap.

### The orbital viewer draws an isosurface, not a slice

The viewer shows the familiar picture: the whole molecule in 3D with a
translucent envelope around each lobe of the chosen orbital. It is *not* a 2D
density or amplitude slice, and the old slice path (`orbital_grid` RPC,
`OrbitalCube`, `OrbitalSliceView`) has been removed. Do not reintroduce it as a
fallback; the isosurface is the feature.

* `src/pyscf_mobile/orbital_surface.py` — marching tetrahedra, welding vertices
  and averaging normals so a lobe shades smoothly. It accepts **both** triangle
  windings (the edge order flips with the sign of the field), which is why the
  edge lookup is a sorted pair rather than an ordered one. Verified against an
  analytic sphere: max radius error 0.0021 at grid step 0.085, unit normals.
* `run_orbital_surface` in `engine.py` — returns both phases as separate meshes
  in **absolute ångström**, the same frame as `geometry`, so the Swift side adds
  them to the existing SceneKit scene with no transform. `source` is `"mo"` or an
  intrinsic localisation method; `isovalue` is a **fraction of the orbital's own
  peak** (default 0.05), not an absolute amplitude, because orbitals differ in
  scale by orders of magnitude between basis sets.
* `_orbital_column` handles the unrestricted case. PySCF's UHF/UKS stores
  `mo_coeff` as a `(2, nao, nmo)` stack (not a tuple), while the ladder the app
  shows concatenates alpha then beta, so the index must be mapped into the
  blocks. Reading it as one block raises on the shape.
* `MoleculeView` takes `surface`/`showsOrbital` and keeps the orbital in its own
  `SCNNode` so hiding it does not disturb the molecule or the camera. The two
  lobes are translucent and `writesToDepthBuffer = false`, or the two phases
  fight where they meet.

Two failure modes are silent on a device and are covered by tests instead of by
looking at the screen: a mesh decoded from nested `[[x,y,z],…]` JSON with the
flat accessor yields **no vertices** while the triangle count stays right (see
`OrbitalPhase.points`), and a surface centred in the wrong frame still renders —
just offset from the molecule (`OrbitalMesh` centres on the same vector as
`MoleculeLayout`).

## Testing notes

`test_shims.py` rewrites `sys.path` to put the vendored shims ahead of the real
SciPy/h5py, and that global state leaks into `test_engine.py`. `run_tests.py`
therefore runs each module in its own interpreter. Do not merge them into one
process.

A shim routine is only covered when a test calls it with the shims installed.
The host has the real SciPy, so anything the engine reaches through `scipy` runs
against the real thing unless the test explicitly forces the vendored copy --
and then the failure appears on a device, not in CI. The `trsm` bug that broke
density fitting on iOS was invisible for exactly this reason: the DF builder is
its only caller, and no shim test exercised DF. Any new shim routine needs a
comparison against the real SciPy *and* a test that drives the engine path which
uses it, both with the shims forced in.

Watch for f2py conventions when reimplementing a BLAS/LAPACK wrapper. SciPy's
`trsm`, for instance, selects the triangle from `a` before applying the
transpose and solves on the right (`alpha * b @ inv(op(a))`); the naive reading
returns a plausible-looking array for a square operand and only falls over when
`b` is non-square, which is what a blocked integral build produces.

## Geometry optimisation

The app relaxes geometries with `src/pyscf_mobile/geomopt.py`, not with PySCF's
own solvers. `pyscf.geomopt.berny_solver` needs the `berny` package and
`geometric_solver` needs `geometric`, and neither can be cross-compiled for iOS
(`geometric` pulls in SciPy's Fortran linear algebra, which this toolchain has
no compiler for). `geomopt.minimise` is a BFGS minimiser on the analytic
gradients PySCF already provides, written on NumPy alone.

Three things about it are load-bearing and easy to break:

* **Units.** PySCF coordinates and gradients are in Bohr, the UI and
  `geometry.py` are in Angstrom. The relaxation runs entirely in Bohr and
  converts at the boundary in `engine.run_geometry_optimisation`.
* **Rigid-body projection.** Translations and rotations cost no energy, so an
  unprojected gradient makes the molecule drift and tumble until the atoms
  wander out of the basis-set region. Every gradient is projected against the
  rigid-body basis before it becomes a step direction. `test_geomopt.py`
  asserts the centroid is unchanged.
* **Every basis set must work.** The gradient driver is taken from the
  mean-field object (`mf.nuc_grad_method()`), so all of `BASIS_SETS` is covered
  without special cases. `test_optimise_works_for_every_basis_set` runs the
  whole list, which is why that suite is slow.

`wb97x-d` has no gradient implementation upstream and raises
`NotImplementedError` for both single points and relaxation; it is a
pre-existing PySCF limitation, not something the optimiser introduced.

## The engine payload is overlaid, not trusted

`scripts/build-ios-app.sh` unpacks a prebuilt tarball
(`build/products/ios-arm64/pyscf-2.14.0-ios-arm64.tar.gz`) into site-packages,
and that tarball is a snapshot taken by `scripts/build-pyscf-ios.sh`. Editing
`src/pyscf_mobile/` alone therefore does **not** reach the app: the build
succeeds and ships the previous revision, so the edited module appears to run
and behaves exactly as before.

The script now copies the current sources over the unpacked package on every
build. The copy uses `src/pyscf_mobile/.` into the existing directory, because
`cp -R src/pyscf_mobile target/` where `target/pyscf_mobile` exists copies
*into* it and produces `pyscf_mobile/pyscf_mobile`.

Deleting a module has the mirror problem: the copy only adds, so a `.py` removed
from `src/` stays in the tarball's copy and keeps shipping. The overlay now walks
the staged package and removes any `.py` that `src/` no longer has, which is how
`nbo.py` stopped going out. Compiled modules such as
`_pyscf_mobile_accel.cpython-313-iphoneos.so` are not in `src/` at all, so the
prune skips them; check they are still present after changing the staging code.

If a Python change seems to have no effect on device, verify it is actually in
the bundle before debugging anything else:

```
grep -c SOME_NEW_SYMBOL \
  build/products/ios-arm64/PySCF.app/python/lib/python3.13/site-packages/pyscf_mobile/engine.py
```

## Numeric tests against a Java reference

The LPO/CLPO port (`src/pyscf_mobile/localized_orbitals.py`) is checked against
JANPA 2.02 itself: write a MOLDEN with `pyscf.tools.molden.from_scf`, run
`java -jar janpa.jar -i file.molden`, and read the `>> LPO` / `>> CLPO` tables.
A hand-transcribed table is not good enough -- the first one in the test file
was wrong and made an exact port look broken.

Two things make that comparison looser than it looks, and both are properties of
the reference, not of the port:

* JANPA stops its hybrid optimiser at a target-function change of 1e-5, the same
  order as the last digit it prints, so re-running it on one unchanged
  wavefunction moves a sum by up to 2e-5. `OCCUPANCY_TOLERANCE` is 3e-5 for that
  reason.
* The LPO functional has two near-degenerate optima for some molecules (water in
  cc-pvdz, carbon dioxide in 6-31g). JANPA prints both across runs, and which one
  a run reaches depends on the last bits of the density -- which BLAS sets by
  summing a contraction in whatever order the thread count implies. The test
  accepts either optimum from `LPO_ALTERNATIVES`.

So a threaded build can disagree with a serial one for identical input. Before
suspecting the port, reproduce with `OMP_NUM_THREADS=1`: if the answer snaps to
the reference, it was thread-order noise, not a bug.

## Crash diagnostics

`src/pyscf_mobile/diaglog.py` writes an append-only log, and the same file is
written from Swift by `DiagnosticsLog`. Three details are deliberate:

* **The Swift side writes synchronously and fsyncs.** The point of the log is
  the last line before the process dies; an async write is still queued when
  the process is killed and is lost.
* **Both sides open with `O_APPEND`.** Python opens with `"a"` and Swift with
  `O_APPEND`, so neither can interleave with or overwrite the other's lines.
  A seek-then-write on the Swift side would.
* **Swift passes the path to Python via `PYSCF_MOBILE_LOG`.** Left to resolve
  their own preferred location the two sides can disagree and split the record
  across two files, each missing the lines that explain the other.

The Diagnostics screen has a log viewer, a clear button, and an OpenMP probe.
The probe (`omp_probe.openmp_report`) runs a real parallel region through
`NPomp_dcopy`; a thread count only proves libomp loaded, not that it can start
a worker. On iOS the probe runs in-process, so a crash inside the region ends
the log immediately after the "entering parallel region" line — that line is
the finding.

`OMP_STACKSIZE` is set to 8192K at boot in `PythonBridge.configureOpenMP`.
LLVM's libomp gives x86/x86_64 workers 2 MB/4 MB but falls through to 1 MB for
every other architecture, and AArch64 also has no `KMP_BACKUP_STKSIZE`
fallback. The runtime reads this once, when the pool initialises, so it has to
be set before the first parallel region. `max_memory` is likewise capped in
`engine._make_method`; PySCF defaults to 2000 MB, a desktop figure.

Note that a jetsam (memory) kill and a segfault both leave no crash report.
Raising the memory ceiling via `ios/PySCF.entitlements` is what distinguishes
them; the entitlement is embedded on the main executable only.

## Packaging and distribution

The IPA is not committed. `*.ipa` is gitignored and every release attaches it
to a tag instead: it is 73 MB, and a file that size in the tree would exceed
GitHub's push limit while making every clone pay for a binary that only the
device needs.

```
scripts/build-ios-app.sh                                  # -> build/products/ios-arm64/PySCF.app
scripts/package-ipa.sh build/products/ios-arm64/PySCF.app build/PySCF-beta-19-unsigned.ipa
```

`package-ipa.sh` exists because of a symlink trap. The Python payload reaches
its native libraries through symlinks — `pyscf/lib/libcint.so` points at
`libcint.6.1.3.so` — and the obvious packaging steps dereference them:
`shutil.make_archive` does, and `zip` without `-y` does. Dereferencing stores a
second full copy of each library (29 MB for libcint, 34 MB for libxc) and turns
a 73 MB archive into a 146 MB one. The script writes the symlink entries
explicitly, so do not replace it with a one-liner.

Release assets keep the fixed name `PySCF-beta-1.0-unsigned.ipa` regardless of
version, matching the earlier releases; the tag distinguishes them. `ipa.sha256`
goes up alongside.

To publish, in this order. The rebuild is the step to not skip: the app bundle
carries its own copy of `pyscf_mobile` under
`PySCF.app/python/lib/python3.13/site-packages/`, so a source change that is
committed but not rebuilt ships an IPA containing the *old* Python while every
test still passes. Check the fix reached the bundle before packaging:

```
scripts/build-ios-app.sh
scripts/validate-ios-app.sh
diff build/products/ios-arm64/PySCF.app/python/lib/python3.13/site-packages/pyscf_mobile/engine.py src/pyscf_mobile/engine.py
scripts/package-ipa.sh build/products/ios-arm64/PySCF.app <out.ipa>
sha256sum <out.ipa> > ipa.sha256
git tag -a ios-v1.0.0-beta.N -m "..." && git push origin ios-v1.0.0-beta.N
```

The `diff` must be empty. Then create the release over the API -- POST to
`/repos/{repo}/releases` with `prerelease: true` -- and upload both assets to
`https://uploads.github.com/repos/{repo}/releases/{id}/assets?name=...`. Read
the release back afterwards and check both assets report `uploaded`; the upload
endpoint returns before the asset is servable.

Pushes go to `master`, from the working branch `ios-port`:

```
git push origin ios-port:master
```

A stored credential at `~/.git-credentials` (`credential.helper = store`) holds
the push token, so no token goes into the command or the shell history. The
token that ships in the environment as `GITHUB_TOKEN` is a GitHub App
installation token with read-only contents; it answers the API but cannot push
(`Resource not accessible by integration`). Do not spend time retrying it.

In a fresh sandbox the store may be absent -- `git config --get
credential.helper` returns nothing and `~/.git-credentials` does not exist. Then
there is no push path at all: `GITHUB_TOKEN` is refused with a 403 that reads
`Permission to <owner>/<repo>.git denied`, even though the API reports
`permissions: push: true` for the same token. That is the read-only contents
permission, not a scope the push can be retried into, so commit locally and ask
for the credential to be provisioned rather than retrying.

A tag on its own publishes nothing. A release needs the tag, the IPA, and the
sha256; a tag without a release leaves the version with no downloadable
artifact.

The IPA is unsigned and ad-hoc signed internally, so it needs a sideloading tool
or a self-signed certificate on the device.
