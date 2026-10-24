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
scripts/build-pyscf-ios.sh       # PySCF + libcint/libxc + native ext
scripts/build-ios-app.sh         # assemble PySCF.app
```

Downloads are pinned and checksum-verified:

| Artefact | Source | Installed to |
|---|---|---|
| iPhoneOS15.6.sdk | `theos/sdks` release `master-146e41f` | `build/sdk/` |
| Darwin toolchain | `L1ghtmann/llvm-project` release `test-210562a` | `build/toolchain/` |
| Swift 5.6 | `download.swift.org` ubuntu20.04 release | `build/swift/` |

Pin new versions by updating the URL *and* the matching `*_SHA256` default in
the script; an unpinned `latest` URL would silently change the bytes and
invalidate the hash.

`build-ios-app.sh` depends on the earlier steps having populated `build/`; it
fails fast with a message naming the script to run when something is missing.

## Verification

```bash
python3 tests/run_tests.py          # Python engine + vendored-shim tests
scripts/check-bridge-contract.sh    # Swift models decode real bridge JSON
scripts/validate-ios-app.sh         # the built .app is a genuine iOS bundle
```

All three must pass before the app is considered good. They are cheap (a few
seconds each except the Python suite) and each catches a different class of
breakage:

* `run_tests.py` — chemistry correctness and the vendored SciPy/h5py shims.
* `check-bridge-contract.sh` — a field renamed in Python silently breaks the UI
  at runtime; this turns that into a test failure.
* `validate-ios-app.sh` — architecture, min-OS, dependency closure, and
  accidental host-path leakage in the shipped bundle.

## Non-obvious constraints

These all cost real debugging time; do not "clean them up".

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

## Testing notes

`test_shims.py` rewrites `sys.path` to put the vendored shims ahead of the real
SciPy/h5py, and that global state leaks into `test_engine.py`. `run_tests.py`
therefore runs each module in its own interpreter. Do not merge them into one
process.
