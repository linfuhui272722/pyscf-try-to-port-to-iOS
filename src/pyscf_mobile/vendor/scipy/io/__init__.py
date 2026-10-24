"""Minimal replacement for :mod:`scipy.io`.

PySCF imports ``FortranFile`` from here in ``pyscf/pbc/tools/pywannier90.py``,
which the app does not ship.  The reader/writer is implemented for unformatted
sequential records so that the import and basic use work; it is not exercised by
the app's chemistry path.
"""

from __future__ import annotations

import struct

import numpy as np

__all__ = ["FortranFile"]

# Fortran type codes used by scipy.io.FortranFile.
_NATIVE = {"i": "i", "l": "q", "f": "f", "d": "d"}
_SIZES = {"i": 4, "l": 8, "f": 4, "d": 8}


class FortranFile:
    """Read/write Fortran unformatted sequential files.

    Each record is framed by a leading and trailing 4-byte little-endian length.
    """

    def __init__(self, filename, mode="r", header_dtype=">u4", **kwargs):
        if header_dtype != ">u4":
            raise NotImplementedError("only 4-byte record markers are supported")
        self._file = open(filename, mode + "b")
        self._mode = mode

    def _read_record(self):
        marker = self._file.read(4)
        if not marker:
            return None
        (length,) = struct.unpack(">I", marker)
        payload = self._file.read(length)
        self._file.read(4)  # trailing marker
        return payload

    def _write_record(self, payload):
        self._file.write(struct.pack(">I", len(payload)))
        self._file.write(payload)
        self._file.write(struct.pack(">I", len(payload)))

    def read_record(self, *dtypes, **kwargs):
        """Read one record and interpret it as the given Fortran types."""
        payload = self._read_record()
        if payload is None:
            raise EOFError("no more records")

        if not dtypes:
            return np.frombuffer(payload, dtype=np.uint8)

        out = []
        offset = 0
        for dt in dtypes:
            # Accept both the (kind, shape) tuple form and a bare kind.
            if isinstance(dt, tuple):
                kind, shape = dt[0], dt[1]
            else:
                kind, shape = dt, ()
            code = _NATIVE[kind.lower()]
            itemsize = _SIZES[kind.lower()]
            count = int(np.prod(shape)) if shape else 1
            nbytes = count * itemsize
            arr = np.frombuffer(payload, dtype=np.dtype("<" + code), count=count,
                                offset=offset)
            offset += nbytes
            out.append(arr.reshape(shape) if shape else arr[0])
        return out[0] if len(out) == 1 else tuple(out)

    def write_record(self, *items):
        """Write one record from scalars or arrays."""
        chunks = []
        for item in items:
            arr = np.atleast_1d(np.asarray(item))
            chunks.append(arr.tobytes(order="C"))
        self._write_record(b"".join(chunks))

    def close(self):
        self._file.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False
