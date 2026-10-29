"""Bridge between the Swift UI and the PySCF engine.

Two transport styles are supported:

``handle_json``
    In-process.  The iOS app embeds CPython and calls this function through the
    Python C API (see ``ios/PySCF/Engine/PythonBridge.swift``).  This is the
    transport used on device, because iOS forbids spawning helper processes.

``main``
    Line-delimited JSON over stdin/stdout.  Handy on macOS/Linux for debugging
    the exact payloads the app sends, and used by the test-suite.
"""

from __future__ import annotations

import json
import os
import sys
import time
import traceback

from . import __version__, engine
from .diaglog import crash_probe, get_logger, install_exit_marker, install_faulthandler

PROTOCOL_VERSION = 1

_BOOT_LOGGED = False


def _log_boot() -> None:
    """Install the crash record once, on the first request.

    Done here rather than at import time so that a failure to write the log
    cannot stop the module from being imported — the bridge has to keep working
    even if diagnostics do not.
    """
    global _BOOT_LOGGED
    if _BOOT_LOGGED:
        return
    _BOOT_LOGGED = True
    try:
        logger = get_logger()
        logger.section(f"bridge ready, package {__version__}")
        logger.write(f"log file: {logger.path}", tag="boot")
        logger.write(f"platform={sys.platform} executable={sys.executable}", tag="boot")
        logger.write(f"prefix={sys.prefix} home={os.environ.get('PYTHONHOME')}", tag="boot")
        logger.write(f"state: {crash_probe()}", tag="boot")
        install_faulthandler()
        install_exit_marker()
    except Exception:
        pass


def capabilities() -> dict:
    """Static description of the API the Swift layer may call."""
    status = engine.engine_status()
    return {
        "ok": True,
        "protocolVersion": PROTOCOL_VERSION,
        "packageVersion": __version__,
        "engine": status,
        "methods": [
            "status",
            "diagnostics",
            "elements",
            "presets",
            "geometry",
            "scf",
            "dft",
            "mp2",
            "ccsd",
            "bond_scan",
            "nbo",
            "wiberg",
            "lpo",
            "clpo",
            "pm",
            "boys",
            "er",
            "optimise",
            "orbital_surface",
            "openmp",
            "threads",
        ],
        "basisSets": list(engine.BASIS_SETS),
        "functionals": list(engine.FUNCTIONALS),
        "methodsAvailable": list(engine.METHODS),
    }


def handle_json(request_json: str) -> str:
    """Execute one JSON request and return the JSON response.

    This is the single entry point used by the embedded interpreter, so it must
    never raise: any failure is reported as a JSON-RPC error object instead.

    Every request is bracketed in the diagnostic log.  The line is written
    before dispatch, so if the process is killed mid-calculation the log names
    the request that was running — which is the one thing a crash report on a
    device does not reliably tell you.
    """
    _log_boot()
    logger = get_logger()

    try:
        request = json.loads(request_json)
    except json.JSONDecodeError as exc:
        logger.write(f"request: parse error ({exc})", tag="rpc")
        return json.dumps(
            {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": f"parse error: {exc}"}}
        )

    if not isinstance(request, dict):
        logger.write("request: not an object", tag="rpc")
        return json.dumps(
            {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "request must be an object"}}
        )

    method = request.get("method")
    if method == "capabilities":
        return json.dumps({"jsonrpc": "2.0", "id": request.get("id"), "result": capabilities()})

    params = request.get("params") or {}
    # Keys only: the atom list can be long and the log is read on a phone.
    detail = ", ".join(sorted(params)) if isinstance(params, dict) else type(params).__name__
    logger.write(f"request #{request.get('id')}: {method} ({detail})", tag="rpc")
    started = time.perf_counter()

    try:
        payload = engine.handle(request)
    except Exception as exc:  # pragma: no cover - defensive, engine.handle is guarded
        logger.write(f"request #{request.get('id')}: {method} raised {type(exc).__name__}: {exc}", tag="rpc")
        return json.dumps(
            {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "error": {
                    "code": -32603,
                    "message": f"{type(exc).__name__}: {exc}",
                    "data": {"traceback": traceback.format_exc()[-2000:]},
                },
            }
        )

    elapsed = (time.perf_counter() - started) * 1000.0
    if "error" in payload:
        logger.write(
            f"request #{request.get('id')}: {method} failed in {elapsed:.0f}ms — "
            f"{payload['error'].get('message')}",
            tag="rpc",
        )
    else:
        logger.write(f"request #{request.get('id')}: {method} ok in {elapsed:.0f}ms", tag="rpc")
    return json.dumps(payload)


def main(argv: list[str] | None = None) -> int:
    """Read one request per line from stdin, write one response per line."""
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--capabilities" in argv:
        sys.stdout.write(json.dumps(capabilities()) + "\n")
        sys.stdout.flush()
        return 0

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        if line in ("quit", "exit"):
            break
        sys.stdout.write(handle_json(line) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
