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
                 # The geometry optimiser and the gradient drivers it calls.
                 # PySCF's own geomopt solvers need the berny/geometric packages,
                 # which cannot be cross-compiled, so the relaxation runs on
                 # these modules instead.
                 "site-packages/pyscf_mobile/geomopt.py",
                 "site-packages/pyscf/grad/rhf.py",
                 "site-packages/pyscf/grad/rks.py",
                 "site-packages/pyscf/grad/__init__.py",
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

# Data files the Python packages open at runtime, rather than import.
# pyscf/gto/mole.py opens bse_meta.json while the module is being imported, so
# a missing copy makes `import pyscf` fail and the engine report itself
# unavailable.  The packaging step filters the package tree, and an allowlist of
# extensions there is how this file went missing in the first place: it is the
# only .json in the tree, and nothing else about it stands out.
site_packages = os.path.join(app, "python", "lib", "python3.13", "site-packages")
runtime_data = [
    "pyscf/gto/basis/bse_meta.json",
    "pyscf/pbc/gto/pseudo/GTH_POTENTIALS",
    "pyscf/pbc/gto/pseudo/POTENTIAL_UZH",
    "pyscf/pbc/gto/basis/BASIS_MOLOPT",
    "pyscf/pbc/gto/basis/HFX_BASIS",
    "pyscf/pbc/gto/basis/GTH_BASIS_SETS",
]
missing_data = [name for name in runtime_data
                if not os.path.exists(os.path.join(site_packages, name))]
check(not missing_data, "runtime data files are packaged",
      ", ".join(missing_data))

# Localisations.  Two failure modes are silent on device, so both are checked
# here: a text .strings file (iOS ignores it and falls back to English, which
# reads as "never translated"), and a key present in one language but not the
# other (that screen reverts to English on a Chinese device).
languages = ["en", "zh-Hans"]
strings_tables = {}
for language in languages:
    path = os.path.join(app, f"{language}.lproj", "Localizable.strings")
    if not os.path.isfile(path):
        strings_tables[language] = None
        continue
    with open(path, "rb") as handle:
        raw = handle.read()
    if raw[:8] != b"bplist00":
        check(False, f"{language}.lproj holds a binary plist",
              "text .strings is ignored at runtime")
        strings_tables[language] = None
        continue
    try:
        strings_tables[language] = plistlib.loads(raw)
    except Exception as error:  # noqa: BLE001 - reported as a check failure
        check(False, f"{language}.lproj parses", str(error))
        strings_tables[language] = None

check(all(strings_tables.values()), "both localisations are present and compiled",
      ", ".join(f"{k}={len(v) if v else 0}" for k, v in strings_tables.items()))

if all(strings_tables.values()):
    english, chinese = strings_tables["en"], strings_tables["zh-Hans"]
    untranslated = sorted(set(english) - set(chinese))
    extra = sorted(set(chinese) - set(english))
    check(not untranslated, "every key has a Chinese translation",
          ", ".join(untranslated[:5]))
    check(not extra, "no Chinese key is missing from English",
          ", ".join(extra[:5]))

    # A format string whose specifiers disagree with the other language crashes
    # or misrenders on one device and not the other.
    import re as _re
    mismatched = []
    for key in sorted(set(english) & set(chinese)):
        if _re.findall(r"%[@dfs]", english[key]) != _re.findall(r"%[@dfs]", chinese[key]):
            mismatched.append(key)
    check(not mismatched, "format specifiers agree across languages",
          ", ".join(mismatched[:5]))

    # Keys the source asks for but neither table defines: NSLocalizedString
    # returns the key itself, so the UI shows "builder.formula" instead of text.
    source_keys = set()
    source_root = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                               "ios", "PySCF")
    for directory, _, files in os.walk(source_root):
        for name in files:
            if not name.endswith(".swift"):
                continue
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                source_keys |= set(_re.findall(r'\bL(?:F)?\("([a-zA-Z0-9._]+)"', handle.read()))
    source_keys |= {f"screen.{name}" for name in
                    ("builder", "results", "history", "orbitals", "density", "table", "diagnostics")}
    undefined = sorted(source_keys - set(english))
    check(not undefined, "every string the UI asks for is defined",
          ", ".join(undefined[:5]))

    # A specifier that disagrees with the type of the argument passed for it
    # crashes on the device and nothing else here notices: `%@` reads its
    # argument as an object pointer, so an Int reaches it as a small integer and
    # is dereferenced as an address.  The release check above only compares the
    # two languages with each other, and both languages had `%@` here.
    #
    # Only the cases that can be told apart from the source are judged, and an
    # argument that cannot be classified is left alone, so this stays a check on
    # the mistake rather than on the author's style.
    def _split_top_level(text):
        parts, depth, quote, current = [], 0, False, []
        for character in text:
            if quote:
                current.append(character)
                if character == '"':
                    quote = False
                continue
            if character == '"':
                quote = True
            elif character in "([":
                depth += 1
            elif character in ")]":
                depth -= 1
            elif character == "," and depth == 0:
                parts.append("".join(current).strip())
                current = []
                continue
            current.append(character)
        if current:
            parts.append("".join(current).strip())
        return [part for part in parts if part]

    def _arguments_after(source, start):
        """The arguments of the call whose argument list starts at ``start``."""
        depth, quote, index = 0, False, start
        while index < len(source):
            character = source[index]
            if quote:
                if character == '"':
                    quote = False
            elif character == '"':
                quote = True
            elif character in "([":
                depth += 1
            elif character in ")]":
                depth -= 1
                if depth == 0:
                    return _split_top_level(source[start + 1:index])
            index += 1
        return []

    def _argument_kind(argument):
        """``"text"``, ``"number"``, or ``None`` when the source does not say."""
        if argument.startswith('"'):
            return "text"
        if "Int(" in argument:
            return "number"
        if _re.fullmatch(r"-?\d+", argument):
            return "number"
        if argument.startswith("String("):
            return "text"
        # Arithmetic outside any nested call, e.g. ``scope.total - scope.valence``,
        # which can only produce a number.
        quote, depth = False, 0
        for character in argument:
            if quote:
                if character == '"':
                    quote = False
            elif character == '"':
                quote = True
            elif character in "([":
                depth += 1
            elif character in ")]":
                depth -= 1
            elif depth == 0 and character in "+-*":
                return "number"
        return None

    # The full specifier is matched so that flags and widths are consumed with
    # it, but only the conversion character decides the argument's type.
    specifier = _re.compile(r"%[-+ #0]*[0-9.]*(l{1,2}d|d|i|u|f|e|g|@|s)")
    mismatched_arguments = []
    for directory, _, files in os.walk(source_root):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
            for match in _re.finditer(r'\bLF\("([a-zA-Z0-9._]+)"', source):
                key = match.group(1)
                if key not in english:
                    continue
                # ``match`` covers ``LF("key"``, so the argument list opens two
                # characters into it.  The key is the first argument and is not
                # one of the values the format string is filled with.
                arguments = _arguments_after(source, match.start() + 2)[1:]
                conversions = [found.group(1) for found in specifier.finditer(english[key])]
                # Fewer arguments than specifiers reads whatever follows on the
                # stack, so it is flagged.  More arguments than specifiers is
                # harmless -- ``String(format:)`` ignores the extras -- and is
                # left alone rather than made into a build failure.
                if len(arguments) < len(conversions):
                    mismatched_arguments.append(
                        f"{name}: {key} has {len(conversions)} specifier(s) for "
                        f"{len(arguments)} argument(s)")
                    continue
                for conversion, argument in zip(conversions, arguments):
                    kind = _argument_kind(argument)
                    if kind is None:
                        continue
                    if conversion == "@" and kind == "number":
                        mismatched_arguments.append(
                            f"{name}: {key} formats a number with %@ ({argument})")
                    elif conversion in ("d", "i", "u", "ld", "lld") and kind == "text":
                        mismatched_arguments.append(
                            f"{name}: {key} formats text with %{conversion} ({argument})")
    check(not mismatched_arguments, "format specifiers match their arguments",
          "; ".join(sorted(set(mismatched_arguments))[:3]))

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

# The diagnostics log falls back to the container's Documents directory. That
# fallback is only useful if the directory is reachable from the Files app, so
# the sharing keys are required rather than optional.
sharing = (bundle_info or {}).get("UIFileSharingEnabled")
check(sharing is True, "exposes Documents in the Files app",
      repr(sharing))

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

# ---------------------------------------------------------------------------
# GIL release after Py_Initialize
# ---------------------------------------------------------------------------
# Py_Initialize leaves the GIL held by the calling thread. The app dispatches
# each request onto the global concurrent queue, so the request that boots the
# interpreter succeeds and every later one blocks forever inside
# PyGILState_Ensure: the UI shows "Loading presets" and never fills in. That
# happens at runtime, so it is invisible to a bundle inspection and has to be
# checked on the binary: a correct build imports PyEval_SaveThread, a broken one
# imports only Py_Initialize and the GIL-state functions.
def imported_symbols(path):
    data = open(path, "rb").read()

    def parse(off):
        magic, = struct.unpack_from("<I", data, off)
        if magic != MH_MAGIC_64:
            return None
        ncmds, = struct.unpack_from("<I", data, off + 16)
        pos, symtab = off + 32, None
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, pos)
            if cmd == 0x2:
                symtab = struct.unpack_from("<IIII", data, pos + 8)
            pos += cmdsize
        if symtab is None:
            return None
        symoff, nsyms, stroff, _ = symtab
        symoff += off
        stroff += off
        names = []
        for index in range(nsyms):
            base = symoff + index * 16
            n_strx, = struct.unpack_from("<I", data, base)
            n_type = data[base + 4]
            if (n_type & 0x0E) != 0:  # keep only N_UNDF (imports)
                continue
            end = data.index(b"\0", stroff + n_strx)
            names.append(data[stroff + n_strx:end].decode())
        return names

    if len(data) >= 4 and struct.unpack_from(">I", data[:4])[0] == FAT_MAGIC:
        count, = struct.unpack(">I", data[4:8])
        for index in range(count):
            base = 8 + index * 20
            cputype, _, offset, _, _ = struct.unpack(">iiIII", data[base:base + 20])
            if cputype == ARM64:
                return parse(offset)
        return None
    return parse(0)


executable = os.path.join(app, "PySCF")
if os.path.isfile(executable):
    imports = imported_symbols(executable) or []
    check("_Py_Initialize" in imports, "app imports Py_Initialize")
    check("_PyEval_SaveThread" in imports,
          "app imports PyEval_SaveThread",
          "GIL is never released after Py_Initialize; the second engine "
          "request would hang and the UI would stay on 'Loading presets'"
          if "_PyEval_SaveThread" not in imports else "")

print("")
if failures:
    print(f"{len(failures)} of {checks} checks FAILED")
    sys.exit(1)
print(f"{checks}/{checks} checks passed")
PY
