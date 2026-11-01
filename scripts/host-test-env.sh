#!/usr/bin/env bash
# Environment for running the Python test suite on the Linux build host.
#
# The host image is reset between sessions: packages installed into ~/.local and
# into /usr/lib are both lost, while anything inside the repository survives.  So
# the interpreter, NumPy, SciPy and the BLAS they bundle all live in .venv/.
#
# PySCF's own shared libraries (pyscf/lib/*.so) are built in the repository and
# survive, but they are linked against a system libopenblas that does not.  The
# copies here are taken from SciPy's bundled build, renamed to the soname PySCF
# asks for, so no system package is needed.
#
# Usage:  source scripts/host-test-env.sh   (or: scripts/host-test-env.sh <cmd>)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "$ROOT/.venv/bin/python" ]; then
  echo "!! no interpreter at $ROOT/.venv/bin/python" >&2
  echo "   run: python3 -m venv .venv && .venv/bin/pip install numpy scipy h5py" >&2
  exit 1
fi

export PYTHONPATH="$ROOT/src:$ROOT${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$ROOT/.venv/lib/blas${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ "$#" -gt 0 ]; then
  exec "$ROOT/.venv/bin/python" "$@"
fi
echo "host test environment ready"
echo "  PYTHONPATH=$PYTHONPATH"
echo "  LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
