"""Crash-resistant diagnostic log for the on-device engine.

A device crash can leave nothing in Settings › Privacy › Analytics › Analytics
Data, so the only way to find out how far a calculation got is to write it down
as it goes.  This module is that record.

Three properties matter, and each is why this is not just a ``print``:

* **It must survive the process dying.**  Every line is flushed *and* fsync'd.
  The interesting failure is the one where the next statement never runs, and a
  buffered log loses exactly the last line before the crash — the one line that
  says which step was running.
* **It must be readable after a signal.**  ``faulthandler`` is pointed at the
  same file, so SIGSEGV/SIGBUS/SIGABRT append a Python stack trace of every
  thread.  That turns "it crashed" into a file name and a line number.
* **It must be able to say the process died rather than exited.**  An
  ``atexit`` marker is written on clean shutdown, so a log that simply stops has
  no marker and the reader knows the process was killed.

Everything is best-effort.  Logging must never be the reason a calculation
fails, so every filesystem call is guarded and a missing destination degrades to
stderr rather than raising.
"""

from __future__ import annotations

import os
import sys
import threading
import time

__all__ = [
    "Logger",
    "get_logger",
    "log_path",
    "install_faulthandler",
    "install_exit_marker",
    "crash_probe",
]

_ENV_OVERRIDE = "PYSCF_MOBILE_LOG"


def _writable_destinations() -> list[str]:
    """Log paths to try, most preferred first.

    On iOS ``$HOME`` is the app container and ``$HOME/Documents`` is the
    directory exposed in the Files app, so it is the destination that works for
    an ordinary sandboxed install.  ``/var/mobile/Documents`` is outside the
    container and only writable for a TrollStore-style install.

    Deliberately *not* used: a path derived from ``__file__``.  That resolves
    inside the signed bundle, which is read-only once installed, so writes there
    fail silently and the log looks empty.
    """
    candidates: list[str] = []
    override = os.environ.get(_ENV_OVERRIDE)
    if override:
        candidates.append(override)

    home = os.environ.get("HOME") or os.path.expanduser("~")
    if home and home != "~":
        candidates.append(os.path.join(home, "Documents", "PySCF.log"))
        candidates.append(os.path.join(home, "Library", "PySCF.log"))
        candidates.append(os.path.join(home, "tmp", "PySCF.log"))
    candidates.append("/var/mobile/Documents/PySCF.log")
    candidates.append("/var/mobile/PySCF.log")
    return candidates


def log_path() -> str | None:
    """First destination whose directory exists and accepts writes."""
    for path in _writable_destinations():
        try:
            directory = os.path.dirname(path) or "."
            if not os.path.isdir(directory):
                continue
            if not os.access(directory, os.W_OK):
                continue
            return path
        except Exception:
            continue
    return None


class Logger:
    """Append-only text log, safe to call from any thread.

    The handle is opened once and kept: reopening per line would cost a syscall
    per write and, worse, could fail precisely when the process is already in
    trouble.
    """

    def __init__(self, path: str | None = None) -> None:
        self.path = path
        self._handle = None
        self._lock = threading.Lock()
        self._start = time.monotonic()
        self._seq = 0
        if path:
            try:
                self._handle = open(path, "a", buffering=1, encoding="utf-8")
            except Exception:
                self._handle = None

    def _stamp(self) -> str:
        now = time.time()
        wall = time.strftime("%H:%M:%S", time.localtime(now))
        self._seq += 1
        return f"{wall}.{int((now % 1) * 1000):03d} +{time.monotonic() - self._start:8.3f}s #{self._seq}"

    def write(self, message: str, tag: str = "engine") -> None:
        """Record one line immediately.  Never raises."""
        try:
            line = f"[{self._stamp()}] [{tag}] {message}\n"
        except Exception:
            return
        with self._lock:
            handle = self._handle
            if handle is not None:
                try:
                    handle.write(line)
                    handle.flush()
                    os.fsync(handle.fileno())
                except Exception:
                    # Drop the sink rather than retrying a broken handle on
                    # every subsequent line.
                    self._handle = None
            try:
                sys.stderr.write(line)
                sys.stderr.flush()
            except Exception:
                pass

    def section(self, title: str) -> None:
        self.write("=" * 8 + f" {title} " + "=" * 8)

    def close(self) -> None:
        with self._lock:
            if self._handle is not None:
                try:
                    self._handle.close()
                except Exception:
                    pass
                self._handle = None


_LOGGER: Logger | None = None
_EXIT_HOOKED = False


def get_logger() -> Logger:
    """Process-wide logger, created on first use."""
    global _LOGGER
    if _LOGGER is None:
        _LOGGER = Logger(log_path())
    return _LOGGER


def install_faulthandler() -> bool:
    """Route fatal signals into the log.

    Without this a crash inside a C extension is silent on a device: the app's
    log stops at the last line it wrote and there is no traceback anywhere.
    With it, SIGSEGV/SIGBUS/SIGABRT/SIGFPE/SIGILL append the Python stack of
    every thread, naming the failing function.
    """
    try:
        import faulthandler

        logger = get_logger()
        target = logger._handle if logger._handle is not None else None
        if target is not None:
            faulthandler.enable(file=target, all_threads=True)
            logger.write("faulthandler enabled -> log file", tag="crash")
        else:
            faulthandler.enable(all_threads=True)
            logger.write("faulthandler enabled -> stderr only (no log file)", tag="crash")
        return True
    except Exception as exc:
        try:
            get_logger().write(f"faulthandler unavailable: {exc!r}", tag="crash")
        except Exception:
            pass
        return False


def install_exit_marker() -> None:
    """Write a marker on clean shutdown.

    A log that ends without this marker was not a normal exit, which is how a
    memory-limit kill or a hard crash is told apart from the app quitting.
    """
    global _EXIT_HOOKED
    if _EXIT_HOOKED:
        return
    _EXIT_HOOKED = True
    try:
        import atexit

        def _marker() -> None:
            try:
                get_logger().write(f"clean exit - {crash_probe()}", tag="exit")
                get_logger().close()
            except Exception:
                pass

        atexit.register(_marker)
    except Exception:
        pass


def crash_probe() -> str:
    """One-line summary of the state that tends to precede an OS kill.

    Resident memory and thread count are the numbers worth having.  The OpenMP
    runtime allocates a stack and private state per worker thread, so enabling
    it raises both, and a rise that keeps climbing across relaxation steps is
    what a memory-limit kill looks like from inside the process.

    ``ru_maxrss`` is bytes on Darwin and kilobytes elsewhere, which is why the
    platform check is here rather than a plain multiply.
    """
    parts: list[str] = []

    try:
        import resource

        peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        peak_bytes = peak if sys.platform in ("darwin", "ios") else peak * 1024
        parts.append(f"peakRSS={peak_bytes / (1024 * 1024):.1f}MB")
    except Exception as exc:
        parts.append(f"peakRSS=?({exc.__class__.__name__})")

    try:
        parts.append(f"pyThreads={threading.active_count()}")
    except Exception:
        parts.append("pyThreads=?")

    # The runtime's own thread count.  Reading it is cheap and it is the only
    # number that distinguishes "OpenMP loaded" from "OpenMP is serial".
    try:
        from pyscf import lib as _lib

        parts.append(f"ompThreads={_lib.num_threads()}")
    except Exception as exc:
        parts.append(f"ompThreads=?({exc.__class__.__name__})")

    for name in ("OMP_NUM_THREADS", "OMP_THREAD_LIMIT", "KMP_BLOCKTIME", "OMP_NESTED"):
        value = os.environ.get(name)
        if value:
            parts.append(f"{name}={value}")

    return " ".join(parts)
