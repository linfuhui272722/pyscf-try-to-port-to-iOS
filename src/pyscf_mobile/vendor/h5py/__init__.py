"""A small HDF5-like store replacing :mod:`h5py` on iOS.

PySCF imports ``h5py`` unconditionally (``pyscf/lib/misc.py``, ``pyscf/gto/mole.py``,
``pyscf/scf/chkfile.py``) and derives ``H5FileWrap`` from ``h5py.File``, so the
package cannot be dropped.  The real h5py needs libhdf5, which is not part of the
iOS SDK and is awkward to cross-compile, so this module provides the same surface
on top of a self-describing file format built from JSON metadata plus raw NumPy
buffers.

What is and is not real
-----------------------
The store is genuinely persistent: data written in one process is readable by
the next, ``is_hdf5`` inspects the file magic rather than guessing, and the group
/ dataset tree behaves like h5py's for the operations PySCF performs (path
indexing, ``create_group``, assignment, ``del``, iteration, ``[()]`` reads).

The format is *not* HDF5, so files written here are not readable by the real
h5py and vice versa.  That is deliberate -- ``is_hdf5`` returns False for genuine
HDF5 files, and PySCF then falls back to creating a fresh file, which is the
behaviour the app needs.
"""

from __future__ import annotations

import json
import os

import numpy as np

__version__ = "3.11.0"

_MAGIC = b"PYSCFH5\x00"

__all__ = ["Dataset", "File", "Group", "is_hdf5", "version", "__version__"]


class _Version:
    version = __version__
    hdf5_version = "1.14.0"
    api_version = "1.14"


version = _Version()


class _FileID:
    """Stand-in for ``h5py.File.id``; ``valid`` tracks whether the file is open."""

    def __init__(self, fileobj):
        self._fileobj = fileobj
        self.valid = True

    def __bool__(self):
        return True


def _encode_array(value):
    """Coerce a Python value into a NumPy array suitable for storage."""
    if isinstance(value, np.ndarray):
        arr = value
    elif isinstance(value, (str, bytes)):
        # Variable-length strings are stored as a 0-d unicode/bytes array.
        arr = np.array(value)
    elif isinstance(value, (tuple, list)):
        arr = np.asarray(value)
    elif isinstance(value, (int, float, complex, bool, np.generic)):
        arr = np.asarray(value)
    else:
        arr = np.asarray(value)

    # HDF5 has no unicode dtype; store as fixed-width bytes like h5py's
    # vlen-str handling does for our purposes.
    if arr.dtype.kind == "U":
        arr = arr.astype("S")
    elif arr.dtype.kind == "O":
        # Object arrays are stored as their string representation, matching the
        # fallback PySCF's own dump() path expects.
        arr = np.asarray([str(v) for v in arr.ravel()], dtype="S").reshape(arr.shape)
    return arr


def _is_shape(value):
    """Report whether ``value`` looks like an h5py shape argument."""
    if isinstance(value, (int, np.integer)):
        return True
    if isinstance(value, (tuple, list)):
        return all(isinstance(v, (int, np.integer)) for v in value)
    return False


def _resolve_dtype(dtype):
    """Translate an h5py dtype argument into a NumPy dtype."""
    if dtype is None:
        return np.dtype("f8")
    if isinstance(dtype, str):
        # h5py accepts NumPy type strings such as 'f8', 'i4', 'S10'.
        return np.dtype(dtype)
    return np.dtype(dtype)


class Dataset:
    """A leaf node holding one NumPy array.

    Supports h5py's indexing conventions: ``ds[()]`` returns the whole array,
    ``ds[key]`` returns a NumPy view (so ``ds[a:b] += x`` writes through), and
    ``ds[key] = value`` assigns into the stored array.
    """

    def __init__(self, name, data):
        self.name = name
        self._data = np.asarray(data)
        # h5py exposes attribute-style metadata on a dataset.  PySCF writes
        # things like ``dset.attrs['mol']`` on checkpoint files, so an empty
        # mapping that accepts assignment is enough to keep those paths working.
        self.attrs = {}

    @property
    def shape(self):
        return self._data.shape

    @property
    def ndim(self):
        # PySCF's ``ao2mo/outcore._load_from_h5g`` branches on ``dat.ndim`` to
        # tell a two-index from a multi-component integral store, so this has to
        # exist: without it the ER localisation and every out-of-core AO-to-MO
        # transform raise AttributeError on iOS only.
        return self._data.ndim

    @property
    def size(self):
        return self._data.size

    @property
    def dtype(self):
        return self._data.dtype

    @property
    def value(self):
        return self._data

    @property
    def chunks(self):
        return None

    @property
    def maxshape(self):
        return self._data.shape

    @property
    def fillvalue(self):
        return None

    def read_direct(self, dest, source_sel=None, dest_sel=None):
        """Copy into ``dest``, the h5py way of reading without a temporary.

        PySCF's out-of-core integral loader reads each block with
        ``read_direct`` and a pair of slices rather than ``ds[...]``, so a shim
        without it fails the same ER path that needs ``ndim``.  Both selections
        default to the whole array, matching h5py.
        """
        source = self._data if source_sel is None else self._data[source_sel]
        if dest_sel is None:
            dest[...] = source
        else:
            dest[dest_sel] = source
        return dest

    def astype(self, dtype):
        return self._data.astype(dtype)

    def __getitem__(self, key):
        if key is Ellipsis:
            return self._data
        return self._data[key]

    def __setitem__(self, key, value):
        if key is Ellipsis or (isinstance(key, tuple) and len(key) == 0):
            self._data[...] = value
        else:
            self._data[key] = value

    def __len__(self):
        return len(self._data)

    def __array__(self, dtype=None):
        return np.asarray(self._data, dtype=dtype)

    def __repr__(self):
        return (f"<Dataset \"{self.name}\": shape {self._data.shape}, "
                f"type \"{self._data.dtype}\">")


class Group:
    """A container node holding named children."""

    def __init__(self, name, parent=None):
        self.name = name
        self._children = {}
        self._parent = parent

    # -- child management ---------------------------------------------------
    def _split_path(self, key):
        return [p for p in str(key).split("/") if p]

    def _resolve(self, key, create=False):
        parts = self._split_path(key)
        node = self
        for part in parts:
            if part not in node._children:
                if not create:
                    raise KeyError(key)
                node._children[part] = Group(part, parent=node)
            node = node._children[part]
            if isinstance(node, Dataset) and part != parts[-1]:
                raise KeyError(f"{key}: {part} is a dataset, not a group")
        return node

    def create_group(self, key):
        parts = self._split_path(key)
        node = self
        for part in parts:
            child = node._children.get(part)
            if child is None:
                child = Group(part, parent=node)
                node._children[part] = child
            elif isinstance(child, Dataset):
                raise TypeError(f"{key}: {part} already exists as a dataset")
            node = child
        return node

    def create_dataset(self, key, shape=None, dtype=None, data=None, **kwargs):
        """Create a dataset.

        Both h5py call styles are supported:

        * ``create_dataset(name, data=array)`` -- the high-level form, and
          equivalently ``create_dataset(name, array)``,
        * ``create_dataset(name, shape, dtype)`` -- the low-level form PySCF's
          CCSD uses, which allocates a zero-filled array of the given shape that
          is then filled by slice assignment.
        """
        if data is not None:
            arr = _encode_array(data)
        elif isinstance(shape, np.ndarray) or (
                shape is not None and dtype is None and not _is_shape(shape)):
            # Called as create_dataset(name, array).
            arr = _encode_array(shape)
        elif shape is None:
            arr = _encode_array(np.array([]))
        else:
            # Low-level form: allocate zeros of the requested shape and dtype.
            np_dtype = _resolve_dtype(dtype)
            arr = np.zeros(tuple(shape), dtype=np_dtype)

        ds = Dataset(key, arr)
        parts = self._split_path(key)
        node = self
        for part in parts[:-1]:
            child = node._children.get(part)
            if child is None or isinstance(child, Dataset):
                child = Group(part, parent=node)
                node._children[part] = child
            node = child
        node._children[parts[-1]] = ds
        return ds

    def __setitem__(self, key, value):
        parts = self._split_path(key)
        node = self
        for part in parts[:-1]:
            child = node._children.get(part)
            if child is None or isinstance(child, Dataset):
                child = Group(part, parent=node)
                node._children[part] = child
            node = child
        node._children[parts[-1]] = Dataset(key, _encode_array(value))

    def __getitem__(self, key):
        node = self._resolve(key, create=False)
        return node

    def __contains__(self, key):
        try:
            self._resolve(key, create=False)
            return True
        except KeyError:
            return False

    def __delitem__(self, key):
        parts = self._split_path(key)
        node = self
        for part in parts[:-1]:
            node = node._children[part]
        del node._children[parts[-1]]

    def __iter__(self):
        return iter(self._children)

    def __len__(self):
        return len(self._children)

    def keys(self):
        return list(self._children.keys())

    def values(self):
        return list(self._children.values())

    def items(self):
        return list(self._children.items())

    def __repr__(self):
        return f"<Group \"{self.name}\": {len(self._children)} members>"


class File(Group):
    """A persistent store, opened as a context manager like ``h5py.File``.

    Supported modes are ``r``, ``w``, ``a`` and ``r+``.  The whole tree is held
    in memory while open and serialised back to disk on flush/close.
    """

    def __init__(self, filename, mode="r", *args, **kwargs):
        if isinstance(filename, os.PathLike):
            filename = os.fspath(filename)
        self.filename = filename
        self.mode = mode
        self.driver = kwargs.get("driver", "core" if mode != "r" else None)
        self._closed = False
        self._id = _FileID(self)
        self.name = "/"

        super().__init__("/", parent=None)

        if mode == "w" or (mode == "a" and not is_hdf5(filename)):
            # Create (or truncate) the store.
            self._dirty = True
        elif mode in ("r", "r+", "a"):
            if os.path.exists(filename) and os.path.getsize(filename) > 0:
                if not is_hdf5(filename):
                    if mode == "r":
                        raise OSError(
                            f"{filename} is not a file this build can read; it is "
                            "neither a PySCF mobile store nor HDF5 (h5py is not "
                            "available on iOS)"
                        )
                    self._dirty = True
                else:
                    self._load()
                    self._dirty = False
            elif mode == "r":
                raise FileNotFoundError(filename)
            else:
                self._dirty = True
        else:
            raise ValueError(f"invalid mode {mode!r}")

    # -- persistence --------------------------------------------------------
    @property
    def id(self):
        return self._id if not self._closed else None

    def _load(self):
        with open(self.filename, "rb") as fh:
            if fh.read(len(_MAGIC)) != _MAGIC:
                raise OSError(f"{self.filename}: bad magic")
            (index_len,) = np.frombuffer(fh.read(8), dtype=">u8")
            index = json.loads(fh.read(int(index_len)).decode("utf-8"))
            payload = fh.read()

        def build(node, spec):
            for name, entry in spec.items():
                if entry["kind"] == "group":
                    child = Group(name, parent=node)
                    node._children[name] = child
                    build(child, entry["children"])
                else:
                    raw = payload[entry["offset"]:entry["offset"] + entry["length"]]
                    arr = np.frombuffer(raw, dtype=np.dtype(entry["dtype"]))
                    arr = arr.reshape(entry["shape"]).copy()
                    node._children[name] = Dataset(name, arr)

        build(self, index.get("children", {}))

    def _dump_tree(self, node):
        spec = {}
        for name, child in node._children.items():
            if isinstance(child, Group):
                spec[name] = {"kind": "group", "children": self._dump_tree(child)}
            else:
                spec[name] = {
                    "kind": "dataset",
                    "dtype": str(child._data.dtype),
                    "shape": list(child._data.shape),
                }
        return spec

    def flush(self):
        if self._closed or self.mode == "r":
            return
        spec = {"children": self._dump_tree(self)}
        blobs = []

        def collect(node, spec_node):
            for name, entry in spec_node["children"].items():
                child = node._children[name]
                if entry["kind"] == "group":
                    collect(child, entry)
                else:
                    raw = np.ascontiguousarray(child._data).tobytes()
                    entry["offset"] = sum(len(b) for b in blobs)
                    entry["length"] = len(raw)
                    blobs.append(raw)

        collect(self, spec)
        index_bytes = json.dumps(spec).encode("utf-8")

        with open(self.filename, "wb") as fh:
            fh.write(_MAGIC)
            fh.write(np.array([len(index_bytes)], dtype=">u8").tobytes())
            fh.write(index_bytes)
            for blob in blobs:
                fh.write(blob)
        self._dirty = False

    def close(self):
        if self._closed:
            return
        self.flush()
        self._closed = True
        self._id.valid = False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def __del__(self):
        try:
            self.close()
        except Exception:  # pragma: no cover - interpreter shutdown
            pass

    def __repr__(self):
        return f"<File \"{self.filename}\" (mode {self.mode})>"


def is_hdf5(fname):
    """Report whether ``fname`` is a store this build can read.

    Accepts a path or an already-open :class:`File`.  Genuine HDF5 files return
    False, which makes PySCF create a fresh store instead of failing.
    """
    if isinstance(fname, File):
        return True
    if isinstance(fname, os.PathLike):
        fname = os.fspath(fname)
    if not isinstance(fname, str) or not os.path.exists(fname):
        return False
    try:
        with open(fname, "rb") as fh:
            return fh.read(len(_MAGIC)) == _MAGIC
    except OSError:
        return False


class _PropFAID:
    @staticmethod
    def get_alignment(plist=None):
        return 1


class _H5P:
    PropFAID = _PropFAID


h5p = _H5P()
