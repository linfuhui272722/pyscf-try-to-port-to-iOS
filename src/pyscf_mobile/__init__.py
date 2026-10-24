"""pyscf_mobile - a phone-sized front end for PySCF.

The package is deliberately split so that the parts that need PySCF and the
parts that do not can be shipped separately:

``elements``  periodic-table data (pure Python)
``geometry``  parsing, bond perception, shape analysis (NumPy only)
``engine``    PySCF jobs plus the JSON-RPC dispatcher used by the Swift bridge
``bridge``    in-process bridge that the iOS app calls into
``vendor``    NumPy-backed stand-ins for scipy/h5py, which iOS cannot build

Importing this package installs the vendored modules on iOS, so ``engine`` picks
them up no matter which entry point the app uses.
"""

from . import vendor

# Must run before anything imports PySCF: pyscf.lib.misc imports scipy and h5py
# at module scope.
vendor.install()

__version__ = "0.1.0"

__all__ = ["elements", "geometry", "engine", "bridge", "vendor", "__version__"]
