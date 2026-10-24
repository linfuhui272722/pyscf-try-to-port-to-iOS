#!/usr/bin/env bash
# Inspect a built PySCF.app and assert it is a genuine, self-contained iOS app.
#
# Checks performed:
#   * the executable is an arm64 Mach-O for iOS >= 15.6
#   * it links SwiftUI/UIKit and finds Python.framework through @executable_path
#   * the CPython runtime, the engine package and NumPy are all present
#   * every shared library is arm64 (no host binaries smuggled in)
#   * symlinked libraries resolve
#   * no absolute build-host paths leaked into the bundle
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/products/ios-arm64/PySCF.app}"

if [ ! -d "$APP" ]; then
  echo "!! no app bundle at $APP" >&2
  echo "   run scripts/build-ios-app.sh first" >&2
  exit 1
fi

python3 - "$APP" <<'PY'
import os, plistlib, struct, sys

app = sys.argv[1]
failures = []
checks = 0

def check(ok, label, detail=""):
    global checks
    checks += 1
    suffix = f" ({detail})" if detail else ""
    print(("  ok   " if ok else "  FAIL ") + label + suffix)
    if not ok:
        failures.append(label)

# ---------------------------------------------------------------------------
# Mach-O parsing
# ---------------------------------------------------------------------------
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
ARM64 = 0x100000C
LC_SEGMENT_64, LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LOAD_WEAK_DYLIB = 0x19, 0xC, 0xD, 0x18
LC_RPATH, LC_BUILD_VERSION = 0x8000001C, 0x32
MH_EXECUTE, MH_DYLIB = 0x2, 0x6
PLATFORM_IOS = 2

def slices(data):
    """Returns [(cputype, offset)] for fat or thin Mach-O images."""
    magic, = struct.unpack(">I", data[:4])
    if magic == FAT_MAGIC:
        count, = struct.unpack(">I", data[4:8])
        out = []
        for index in range(count):
            base = 8 + index * 20
            cputype, _, offset, _, _ = struct.unpack(">iiIII", data[base:base + 20])
            out.append((cputype, offset))
        return out
    magic, = struct.unpack("<I", data[:4])
    if magic == MH_MAGIC_64:
        cputype, = struct.unpack("<i", data[4:8])
        return [(cputype, 0)]
    return []

def inspect(path):
    """Returns (cputypes, filetype, min_os, platform, deps, rpaths, identifier).

    ``deps`` holds only real dependencies (LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB);
    the library's own install name (LC_ID_DYLIB) is returned separately as
    ``identifier`` so dependency-closure checks do not mistake it for one.
    """
    with open(path, "rb") as handle:
        data = handle.read()
    found = slices(data)
    if not found:
        return None
    cputypes = [cputype for cputype, _ in found]
    cputype, base = found[0]
    filetype, = struct.unpack("<I", data[base + 12:base + 16])
    ncmds, = struct.unpack("<I", data[base + 16:base + 20])
    min_os = platform = None
    deps, rpaths, identifier = [], [], None
    cursor = base + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[cursor:cursor + 8])
        if cmd == LC_BUILD_VERSION:
            platform, min_os, _, _ = struct.unpack("<IIII", data[cursor + 8:cursor + 24])
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_ID_DYLIB):
            offset, = struct.unpack("<I", data[cursor + 8:cursor + 12])
            end = data.index(b"\0", cursor + offset)
            value = data[cursor + offset:end].decode()
            if cmd == LC_ID_DYLIB:
                identifier = value
            else:
                deps.append(value)
        elif cmd == LC_RPATH:
            offset, = struct.unpack("<I", data[cursor + 8:cursor + 12])
            end = data.index(b"\0", cursor + offset)
            rpaths.append(data[cursor + offset:end].decode())
        cursor += size
    return cputypes, filetype, min_os, platform, deps, rpaths, identifier

def version(value):
    return f"{value >> 16}.{(value >> 8) & 0xFF}"

# ---------------------------------------------------------------------------
# 1. Executable
# ---------------------------------------------------------------------------
print("executable")
executable = os.path.join(app, "PySCF")
check(os.path.isfile(executable), "PySCF executable present")

info = inspect(executable)
check(info is not None, "executable is a Mach-O image")
if info:
    cputypes, filetype, min_os, platform, dylibs, rpaths, _ = info
    check(cputypes == [ARM64], "architecture is arm64", hex(cputypes[0]))
    check(filetype == MH_EXECUTE, "file type is executable")
    check(platform == PLATFORM_IOS, "platform is iOS")
    check(min_os is not None and version(min_os) == "15.6", "minimum OS is 15.6",
          version(min_os) if min_os else "unknown")
    check(any("SwiftUI" in d for d in dylibs), "links SwiftUI")
    check(any("UIKit" in d for d in dylibs), "links UIKit")
    check(any("Python.framework" in d for d in dylibs), "links Python.framework")
    check(any("libswiftCore" in d for d in dylibs), "links libswiftCore")
    check(any(r == "@executable_path/Frameworks" for r in rpaths),
          "rpath points at @executable_path/Frameworks", ", ".join(rpaths))

# ---------------------------------------------------------------------------
# 2. Python runtime payload
# ---------------------------------------------------------------------------
print("python runtime")
libdir = os.path.join(app, "python/lib/python3.13")
site = os.path.join(libdir, "site-packages")

for relative in ["os.py", "inspect.py", "importlib/__init__.py",
                 "encodings/__init__.py", "json/__init__.py",
                 "lib-dynload/_opcode.cpython-313-iphoneos.so",
                 "lib-dynload/math.cpython-313-iphoneos.so",
                 "lib-dynload/_json.cpython-313-iphoneos.so",
                 "site-packages/pyscf_mobile/bridge.py",
                 "site-packages/pyscf_mobile/engine.py",
                 "site-packages/pyscf/__init__.py",
                 "site-packages/numpy/__init__.py"]:
    check(os.path.exists(os.path.join(libdir, relative)), f"payload has {relative}")

framework = os.path.join(app, "Frameworks/Python.framework/Python")
check(os.path.isfile(framework), "Python.framework binary bundled")

if os.path.isfile(framework):
    fw = inspect(framework)
    check(fw is not None and fw[0] == [ARM64], "framework binary is arm64")
    check(fw is not None and fw[1] == MH_DYLIB, "framework binary is a dylib")

# ---------------------------------------------------------------------------
# 3. Every native image must be arm64, and symlinks must resolve
# ---------------------------------------------------------------------------
print("native payload")
arm64 = foreign = broken = 0
for directory, _, files in os.walk(app):
    for name in files:
        path = os.path.join(directory, name)
        if os.path.islink(path):
            if not os.path.exists(path):
                broken += 1
                print(f"  FAIL broken symlink {os.path.relpath(path, app)}")
            continue
        if not name.endswith((".so", ".dylib")) and name != "Python":
            continue
        try:
            with open(path, "rb") as handle:
                head = handle.read(8)
        except OSError:
            continue
        if len(head) < 8:
            continue
        magic_be, = struct.unpack(">I", head[:4])
        magic_le, = struct.unpack("<I", head[:4])
        if magic_be != FAT_MAGIC and magic_le != MH_MAGIC_64:
            continue
        result = inspect(path)
        if result and result[0] == [ARM64]:
            arm64 += 1
        else:
            foreign += 1
            print(f"  FAIL non-arm64 image {os.path.relpath(path, app)}")

check(foreign == 0, "all native images are arm64", f"{arm64} checked")
check(broken == 0, "all symlinked libraries resolve")

# ---------------------------------------------------------------------------
# 4. Dynamic dependency closure
#
# Every @rpath/@loader_path reference must resolve inside the bundle, and every
# absolute reference must be a system library that exists on iOS.  A missing
# entry here is a crash at import time, not a build error, so it is worth
# asserting explicitly.
# ---------------------------------------------------------------------------
print("dependency closure")
RESOLVABLE_PREFIXES = ("/System/Library/", "/usr/lib/")

def rpaths_of(path):
    result = inspect(path)
    return result[5] if result else []

def resolve(reference, loader_dir, loader_rpaths):
    """Mirrors dyld's search for one dependency reference."""
    if reference.startswith("@loader_path/"):
        return os.path.join(loader_dir, reference[len("@loader_path/"):])
    if reference.startswith("@executable_path/"):
        return os.path.join(os.path.dirname(executable), reference[len("@executable_path/"):])
    if reference.startswith("@rpath/"):
        suffix = reference[len("@rpath/"):]
        for rpath in loader_rpaths:
            base = rpath
            if base.startswith("@loader_path"):
                base = os.path.join(loader_dir, base[len("@loader_path"):].lstrip("/"))
            elif base.startswith("@executable_path"):
                base = os.path.join(os.path.dirname(executable),
                                    base[len("@executable_path"):].lstrip("/"))
            candidate = os.path.join(base, suffix)
            if os.path.exists(candidate):
                return candidate
        return None
    return reference

unresolved = []
images = []
for directory, _, files in os.walk(app):
    for name in files:
        path = os.path.join(directory, name)
        if os.path.islink(path):
            continue
        if not name.endswith((".so", ".dylib")) and name != "Python":
            continue
        try:
            with open(path, "rb") as handle:
                if len(handle.read(4)) < 4:
                    continue
        except OSError:
            continue
        if inspect(path):
            images.append(path)

# The main executable participates in the search, so seed its rpaths too.
exec_rpaths = inspect(executable)[5] if inspect(executable) else []
for path in images:
    loader_dir = os.path.dirname(path)
    loader_rpaths = rpaths_of(path) + exec_rpaths
    result = inspect(path)
    for reference in result[4]:
        if reference.startswith(("/System/Library/", "/usr/lib/")):
            continue
        if not reference.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
            unresolved.append((path, reference))
            continue
        if resolve(reference, loader_dir, loader_rpaths) is None:
            unresolved.append((path, reference))

for path, reference in unresolved[:10]:
    print(f"  FAIL {os.path.relpath(path, app)} -> {reference}")
check(not unresolved, "every bundled dependency resolves",
      f"{len(images)} images checked")

# ---------------------------------------------------------------------------
# 5. No build-host paths baked into text files or binaries
# ---------------------------------------------------------------------------
print("portability")
leaked = []
for directory, _, files in os.walk(app):
    for name in files:
        path = os.path.join(directory, name)
        if os.path.islink(path):
            continue
        if not name.endswith((".py", ".plist", ".cfg", ".pth")):
            continue
        try:
            with open(path, "r", errors="ignore") as handle:
                text = handle.read()
        except OSError:
            continue
        if "/workspace/project" in text:
            leaked.append(os.path.relpath(path, app))

check(not leaked, "no /workspace/project paths in text payload",
      f"{len(leaked)} file(s)" if leaked else "")

# ---------------------------------------------------------------------------
# 6. LaunchServices registration prerequisites
#
# TrollStore registers the bundle with LaunchServices after signing it. When
# that call is refused the install fails with exit 181 ("Failed to add app to
# icon cache"), which reads like a signing problem but is not: the signature is
# already valid at that point. These are the keys and files LaunchServices
# needs, so assert them here rather than discovering the failure on a device.
# ---------------------------------------------------------------------------
print("launch services registration")

bundle_plist = os.path.join(app, "Info.plist")
try:
    with open(bundle_plist, "rb") as handle:
        bundle_info = plistlib.load(handle)
except Exception as exc:  # noqa: BLE001 - surfaced via the check below
    bundle_info = None
    print(f"  could not read Info.plist: {exc}")

check(isinstance(bundle_info, dict), "bundle Info.plist is readable")

# Apple's toolchain always emits Info.plist as a binary plist, and
# MobileInstallation reports the first bytes of the file when it refuses a
# bundle. An XML plist there is the deviation that fails inspection, so require
# the binary magic on every plist in the bundle.
xml_plists = []
for directory, _, files in os.walk(app):
    for name in files:
        if name != "Info.plist":
            continue
        path = os.path.join(directory, name)
        with open(path, "rb") as handle:
            if handle.read(8) != b"bplist00":
                xml_plists.append(os.path.relpath(path, app))
check(not xml_plists, "every Info.plist is binary",
      ", ".join(sorted(xml_plists)))

# Apple ships thin Mach-O executables: Xcode runs lipo -thin during a build.
# A fat binary in the payload is a build artifact that no released app has, and
# MobileInstallation refuses a bundle containing one.
import struct as _struct
FAT_MAGICS = {0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA}
fat_binaries = []
for directory, _, files in os.walk(app):
    for name in files:
        path = os.path.join(directory, name)
        if os.path.islink(path):
            continue
        with open(path, "rb") as handle:
            head = handle.read(4)
        if len(head) == 4 and _struct.unpack(">I", head)[0] in FAT_MAGICS:
            fat_binaries.append(os.path.relpath(path, app))
check(not fat_binaries, "no fat binaries in payload",
      ", ".join(sorted(fat_binaries)))

# Every Mach-O image must carry an LC_CODE_SIGNATURE load command. On arm64 iOS
# the kernel refuses to map an unsigned image, so an unsigned extension module
# fails at dlopen and surfaces as ImportError for the module inside it - the
# engine then reports itself unavailable while pure Python still works, which
# makes the failure look like a missing library rather than a signing problem.
MACHO_MAGICS = {
    0xFEEDFACF,  # 64-bit little endian, as built for arm64
    0xFEEDFACE,  # 32-bit little endian
    0xCEFAEDFE,  # 64-bit big endian (byte-swapped on disk)
    0xCFFAEDFE,
    0xCAFEBABE,
    0xBEBAFECA,
    0xCAFEBABF,
    0xBFBAFECA,
}
LC_CODE_SIGNATURE = 0x1D


def code_signature_offset(path):
    """Returns the file offset of LC_CODE_SIGNATURE, or None if absent."""
    with open(path, "rb") as handle:
        data = handle.read(1 << 20)
    if len(data) < 32:
        return None
    magic, = _struct.unpack("<I", data[:4])
    if magic != 0xFEEDFACF:
        return None
    ncmds, = _struct.unpack("<I", data[16:20])
    offset = 32
    for _ in range(ncmds):
        if offset + 8 > len(data):
            return None
        cmd, cmdsize = _struct.unpack("<II", data[offset:offset + 8])
        if cmd == LC_CODE_SIGNATURE:
            return offset
        if cmdsize == 0:
            return None
        offset += cmdsize
    return None


unsigned_images = []
signed_count = 0
for directory, _, files in os.walk(app):
    for name in files:
        path = os.path.join(directory, name)
        if os.path.islink(path):
            continue
        with open(path, "rb") as handle:
            head = handle.read(4)
        if len(head) != 4:
            continue
        magic_le, = _struct.unpack("<I", head)
        magic_be, = _struct.unpack(">I", head)
        if magic_le not in MACHO_MAGICS and magic_be not in MACHO_MAGICS:
            continue
        if magic_le in FAT_MAGICS or magic_be in FAT_MAGICS:
            continue  # reported above
        if code_signature_offset(path) is None:
            unsigned_images.append(os.path.relpath(path, app))
        else:
            signed_count += 1

check(signed_count > 0, "bundle carries signed Mach-O images", f"{signed_count} signed")
check(not unsigned_images, "every Mach-O image is signed",
      ", ".join(sorted(unsigned_images)[:5]))

# A top-level Resources directory is a macOS bundle convention. MobileInstallation
# rejects a bundle that contains one during package inspection, which TrollStore
# surfaces as exit 181 after signing has already succeeded. Resources must sit at
# the top level of the .app instead.
check(not os.path.isdir(os.path.join(app, "Resources")),
      "no top-level Resources directory")
check(os.path.isdir(os.path.join(app, "python", "lib", "python3.13")),
      "python runtime staged at the top level")

required = {
    "CFBundleIdentifier": str,
    "CFBundleExecutable": str,
    "CFBundleSupportedPlatforms": list,
    "UIDeviceFamily": list,
    "CFBundleIcons": dict,
    "CFBundleVersion": (str, int),
    "MinimumOSVersion": str,
}
missing = []
for key, kind in required.items():
    if not isinstance((bundle_info or {}).get(key), kind):
        missing.append(key)
check(not missing, "Info.plist carries LaunchServices keys",
      ", ".join(missing))

platforms = (bundle_info or {}).get("CFBundleSupportedPlatforms") or []
check(platforms == ["iPhoneOS"], "declares the iPhoneOS platform",
      repr(platforms))

families = (bundle_info or {}).get("UIDeviceFamily") or []
check(1 in families, "declares iPhone device family", repr(families))

# Every icon the plist advertises must exist at the size the device expects.
icon_dir = app
declared = set()
for section in ("CFBundleIcons", "CFBundleIcons~ipad"):
    for key in ((bundle_info or {}).get(section) or {}).get("CFBundlePrimaryIcon", {}).get(
        "CFBundleIconFiles", []
    ):
        declared.add(key)

absent = sorted(
    name
    for name in declared
    if not any(os.path.isfile(os.path.join(icon_dir, f"{name}{sfx}.png"))
               for sfx in ("", "@2x", "@3x"))
)
check(bool(declared) and not absent, "declared icon files are present",
      f"{len(declared)} declared" if not absent else "missing " + ", ".join(absent))

# A 1024px marketing icon is not needed, but the primary @3x home screen icon is
# what SpringBoard actually renders; make sure it exists and is non-trivial.
home = os.path.join(icon_dir, "AppIcon60x60@3x.png")
check(os.path.isfile(home) and os.path.getsize(home) > 500,
      "home screen icon has real content",
      f"{os.path.getsize(home)}B" if os.path.isfile(home) else "absent")

check(os.path.isfile(os.path.join(app, "PkgInfo")), "PkgInfo present")

# CFBundleIconName is a promise that the icons live in an Assets.car produced by
# Apple's actool. A hand-built bundle has no catalog, and iOS then resolves no
# icon at all and refuses to register the app. Loose CFBundleIconFiles are the
# correct form here, so fail if the name key reappears without a catalog.
icon_name = ((bundle_info or {}).get("CFBundleIcons") or {}).get(
    "CFBundlePrimaryIcon", {}
).get("CFBundleIconName")
has_car = os.path.isfile(os.path.join(app, "Assets.car"))
check(icon_name is None or has_car,
      "no CFBundleIconName without Assets.car",
      f"icon name {icon_name!r} but no catalog" if icon_name and not has_car else "")


print("")
if failures:
    print(f"{len(failures)} of {checks} checks FAILED")
    sys.exit(1)
print(f"{checks}/{checks} checks passed")
PY
