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
import sys
import traceback

from . import __version__, engine

PROTOCOL_VERSION = 1


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
        ],
        "basisSets": list(engine.BASIS_SETS),
        "functionals": list(engine.FUNCTIONALS),
        "methodsAvailable": list(engine.METHODS),
    }


def handle_json(request_json: str) -> str:
    """Execute one JSON request and return the JSON response.

    This is the single entry point used by the embedded interpreter, so it must
    never raise: any failure is reported as a JSON-RPC error object instead.
    """
    try:
        request = json.loads(request_json)
    except json.JSONDecodeError as exc:
        return json.dumps(
            {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": f"parse error: {exc}"}}
        )

    if not isinstance(request, dict):
        return json.dumps(
            {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "request must be an object"}}
        )

    if request.get("method") == "capabilities":
        return json.dumps({"jsonrpc": "2.0", "id": request.get("id"), "result": capabilities()})

    try:
        return json.dumps(engine.handle(request))
    except Exception as exc:  # pragma: no cover - defensive, engine.handle is guarded
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
