"""Exercise the OpenMP runtime and report what actually happened.

The thread count in the UI comes from ``pyscf.lib.num_threads()``, which reads
``get_omp_threads()`` out of ``libnp_helper``.  That proves libomp *loaded*, but
it does not prove a worker thread can be *created*: the number is derived from
the CPU count and is returned whether or not a parallel region ever runs.

So it cannot distinguish these two cases, and they need opposite fixes:

* the runtime is genuinely running work in parallel, and
* the runtime loaded but the first real parallel region crashes the process.

The second is what a device crash with an empty log looks like.  This module
settles it by calling into ``NPomp_dcopy``, the smallest entry point that opens
an actual parallel region (it compiles to an ``.omp_outlined.`` function), with
no molecule or SCF object involved.  The result is written to the log before and
after, so a crash inside the region is identifiable from the last line.

``probe_openmp`` may therefore not return.  Callers that can afford a fork run
it in a child process; ``openmp_report`` does that when possible.
"""

from __future__ import annotations

import ctypes
import os
import time

from .diaglog import get_logger

__all__ = ["probe_openmp", "openmp_report"]

# A copy large enough that libomp actually splits it across threads rather than
# deciding the loop is too short to be worth it.
_COPY_ELEMENTS = 1 << 18


def _libomp_handle():
    """Load ``libomp.so`` directly.

    It is not reachable through ``libnp_helper``: that extension imports
    ``omp_get_max_threads`` and friends as undefined symbols, so ctypes cannot
    resolve them from its handle.  Loading the runtime itself is the only way to
    read the pool's own state.
    """
    import pyscf

    search = [os.path.join(os.path.dirname(__file__), "..", "..")]
    for path in getattr(pyscf, "__path__", []):
        search.append(os.path.join(path, "lib"))
    for directory in search:
        candidate = os.path.join(os.path.abspath(directory), "libomp.so")
        if os.path.exists(candidate):
            return ctypes.CDLL(candidate)
    raise FileNotFoundError("libomp.so not found next to the PySCF extensions")


def _omp_state() -> dict:
    """Read the runtime's own pool state, tolerating a missing symbol."""
    state: dict = {}
    try:
        lib = _libomp_handle()
    except Exception as exc:
        state["error"] = f"{type(exc).__name__}: {exc}"
        return state

    for name in ("omp_get_max_threads", "omp_get_num_procs", "omp_in_parallel", "omp_get_dynamic"):
        try:
            fn = getattr(lib, name)
            fn.restype = ctypes.c_int
            fn.argtypes = []
            state[name] = int(fn())
        except Exception as exc:
            state[name] = f"{type(exc).__name__}: {exc}"
    return state


def _parallel_copy() -> tuple[bool, str]:
    """Run one real parallel region inside ``libnp_helper``.

    ``NPomp_dcopy`` is a parallel matrix copy and the smallest entry point that
    opens a parallel region.  It needs no molecule, no SCF object and no prior
    calculation, so it can run at startup — which is what makes it useful as a
    canary rather than a test that only fails after twenty minutes of work.

    The signature has six parameters, not three::

        void NPomp_dcopy(const size_t m, const size_t n,
                         const double *in,  const size_t in_stride,
                         double *out,       const size_t out_stride);

    Passing the shorter argument list leaves ``n`` holding a pointer and ``out``
    holding whatever was in the register, and the function writes through the
    second.  That is an immediate crash, and it looks exactly like the OpenMP
    runtime being broken, so the arity is spelled out here and in ``argtypes``.
    """
    import numpy as np
    from pyscf.lib import numpy_helper

    helper = numpy_helper._np_helper
    if helper is None:
        return False, "libnp_helper is not loaded"

    # One row of _COPY_ELEMENTS doubles: m = elements, n = 1, unit strides.
    m = _COPY_ELEMENTS
    source = np.arange(m, dtype=np.float64)
    target = np.zeros(m, dtype=np.float64)

    fn = helper.NPomp_dcopy
    fn.restype = None
    fn.argtypes = [
        ctypes.c_size_t,  # m
        ctypes.c_size_t,  # n
        ctypes.c_void_p,  # in
        ctypes.c_size_t,  # in_stride
        ctypes.c_void_p,  # out
        ctypes.c_size_t,  # out_stride
    ]
    fn(ctypes.c_size_t(m),
       ctypes.c_size_t(1),
       source.ctypes.data_as(ctypes.c_void_p),
       ctypes.c_size_t(1),
       target.ctypes.data_as(ctypes.c_void_p),
       ctypes.c_size_t(1))

    if not np.array_equal(source, target):
        return False, "parallel copy produced the wrong result"
    return True, f"parallel copy of {m} doubles OK"


def _thread_utilisation() -> dict:
    """Time the parallel copy against a serial one of the same size.

    A thread count read from the runtime only says what the pool is *allowed* to
    use.  Whether workers are actually created is a separate question, and on
    iOS it is the one that matters: a sandboxed process can be told there are
    eight cores while ``sysconf(_SC_NPROCESSORS_ONLN)`` returns one, in which
    case libomp sizes its pool from that and every region runs on a single
    thread.  The configuration then reads 8 and nothing is parallel.

    The test is a repeated copy, large enough that a thread pool would show up.
    It is a timing comparison and therefore noisy, so it is reported as a ratio
    for interpretation rather than asserted on.
    """
    import time

    import numpy as np
    from pyscf.lib import numpy_helper

    helper = numpy_helper._np_helper
    if helper is None:
        return {"error": "libnp_helper is not loaded"}

    m = _COPY_ELEMENTS
    source = np.arange(m, dtype=np.float64)
    target = np.zeros(m, dtype=np.float64)
    rounds = 40

    fn = helper.NPomp_dcopy
    fn.restype = None
    fn.argtypes = [
        ctypes.c_size_t,
        ctypes.c_size_t,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    args = (ctypes.c_size_t(m), ctypes.c_size_t(1),
            source.ctypes.data_as(ctypes.c_void_p), ctypes.c_size_t(1),
            target.ctypes.data_as(ctypes.c_void_p), ctypes.c_size_t(1))

    # Warm the pool first: the first region pays for thread creation, and
    # including that cost would make the parallel figure look worse than it is.
    fn(*args)

    start = time.perf_counter()
    for _ in range(rounds):
        fn(*args)
    parallel_ms = (time.perf_counter() - start) * 1000.0

    start = time.perf_counter()
    for _ in range(rounds):
        np.copyto(target, source)
    serial_ms = (time.perf_counter() - start) * 1000.0

    return {
        "parallelMs": round(parallel_ms, 3),
        "serialMs": round(serial_ms, 3),
        "ratio": round(parallel_ms / serial_ms, 3) if serial_ms else None,
        "rounds": rounds,
    }


def probe_openmp() -> dict:
    """Run the parallel canary, logging before and after.

    May not return if the runtime crashes inside the parallel region; the log
    then ends immediately after the "entering parallel region" line, which is
    itself the finding.
    """
    logger = get_logger()
    report: dict = {"ok": True}

    try:
        from pyscf import lib as _lib

        report["reportedThreads"] = int(_lib.num_threads())
    except Exception as exc:
        report["reportedThreads"] = None
        report["threadsError"] = f"{type(exc).__name__}: {exc}"

    state = _omp_state()
    report["runtime"] = state
    report["maxThreads"] = state.get("omp_get_max_threads")
    report["numProcs"] = state.get("omp_get_num_procs")

    # What the OS reports as usable CPUs, next to what the runtime will use. The
    # two disagreeing is the signature of a sandbox that hides the core count:
    # the runtime reads 1 and runs everything on one thread no matter what
    # OMP_NUM_THREADS says, so the setting looks correct and the work is serial.
    try:
        report["osCpuCount"] = os.cpu_count()
        report["sysconfCpus"] = os.sysconf("SC_NPROCESSORS_ONLN")
    except Exception as exc:
        report["osCpuCount"] = f"{type(exc).__name__}: {exc}"
        report["sysconfCpus"] = None

    from .diaglog import crash_probe

    logger.write(f"openmp probe: entering parallel region; {crash_probe()}", tag="omp")
    logger.write(f"openmp probe: runtime state {state}", tag="omp")

    started = time.perf_counter()
    try:
        ok, detail = _parallel_copy()
        report["parallelRegion"] = ok
        report["parallelDetail"] = detail
    except Exception as exc:
        report["parallelRegion"] = False
        report["parallelDetail"] = f"{type(exc).__name__}: {exc}"
    report["elapsedMs"] = round((time.perf_counter() - started) * 1000.0, 3)

    # Whether the pool actually parallelises, which the thread count alone does
    # not establish. A failure here is reported, not raised.
    try:
        report["utilisation"] = _thread_utilisation()
    except Exception as exc:
        report["utilisation"] = {"error": f"{type(exc).__name__}: {exc}"}

    report["runtimeAfter"] = _omp_state()
    logger.write(
        f"openmp probe: survived the parallel region in {report['elapsedMs']}ms; {crash_probe()}",
        tag="omp",
    )
    logger.write(f"openmp probe: utilisation {report.get('utilisation')}", tag="omp")
    return report


def openmp_report() -> dict:
    """Probe and summarise, for the diagnostics screen and the status footer.

    The probe is run in a forked child when the platform supports it, so that a
    crash inside the parallel region is reported as a failed probe instead of
    killing the app.  iOS does not provide ``fork``, so there the probe runs
    in-process and a crash is caught by ``faulthandler`` writing into the log.
    """
    import sys

    logger = get_logger()
    can_fork = hasattr(os, "fork") and sys.platform not in ("ios", "darwin")

    if can_fork:
        try:
            read_fd, write_fd = os.pipe()
            pid = os.fork()
            if pid == 0:  # child
                os.close(read_fd)
                try:
                    payload = repr(probe_openmp()).encode()
                except BaseException as exc:  # noqa: BLE001 - report anything
                    payload = repr({"ok": False, "crash": f"{type(exc).__name__}: {exc}"}).encode()
                try:
                    os.write(write_fd, payload)
                finally:
                    os._exit(0)
            os.close(write_fd)
            chunks = []
            while True:
                chunk = os.read(read_fd, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
            os.close(read_fd)
            _, status = os.waitpid(pid, 0)
            text = b"".join(chunks).decode(errors="replace")
            if status != 0 or not text:
                signal = status & 0x7F
                report = {
                    "ok": False,
                    "crashed": True,
                    "detail": (
                        f"the parallel region killed the child process "
                        f"(signal {signal})" if signal else f"child exited with status {status}"
                    ),
                }
                logger.write(f"openmp probe: {report['detail']}", tag="omp")
                return report
            import ast

            report = ast.literal_eval(text)
            report["ok"] = bool(report.get("parallelRegion"))
            report["summary"] = _summarise(report)
            return report
        except Exception as exc:
            logger.write(f"openmp probe: fork path failed ({exc!r}); probing in-process", tag="omp")

    report = probe_openmp()
    report["ok"] = bool(report.get("parallelRegion"))
    report["summary"] = _summarise(report)
    return report


def _summarise(report: dict) -> str:
    util = report.get("utilisation") or {}
    ratio = util.get("ratio")
    # ratio is parallel/serial; below 1 means the parallel path won.
    speedup = f"{1 / ratio:.1f}x" if ratio else "n/a"
    return (
        f"threads={report.get('reportedThreads')} "
        f"max={report.get('maxThreads')} "
        f"procs={report.get('numProcs')} "
        f"osCpus={report.get('osCpuCount')} "
        f"parallel={report.get('parallelRegion')} "
        f"speedup={speedup}"
    )
