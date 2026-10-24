/*
 * _pyscf_mobile_accel - C helpers for the interactive parts of the app.
 *
 * The SwiftUI layer needs geometry feedback while the user drags an atom or
 * taps to place one: pairwise distances, bond perception and a crude
 * point-charge energy.  Doing that in Python/NumPy costs several milliseconds
 * per frame on a phone, so the hot loops live here instead.
 *
 * Build: scripts/build-native-ext.sh
 */

#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <math.h>
#include <stdlib.h>

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

/* Copy a sequence of xyz triples into a flat double array.  Returns NULL and
 * sets a Python exception on failure. */
static double *
copy_coords(PyObject *coords_obj, Py_ssize_t *n_out)
{
    PyObject *seq = PySequence_Fast(coords_obj, "coords must be a sequence of xyz triples");
    if (seq == NULL) {
        return NULL;
    }
    Py_ssize_t n = PySequence_Fast_GET_SIZE(seq);
    double *xyz = (double *)PyMem_Malloc((size_t)(n > 0 ? n : 1) * 3 * sizeof(double));
    if (xyz == NULL) {
        Py_DECREF(seq);
        PyErr_NoMemory();
        return NULL;
    }
    for (Py_ssize_t i = 0; i < n; ++i) {
        PyObject *row = PySequence_Fast(PySequence_Fast_GET_ITEM(seq, i),
                                        "each coordinate must be a triple");
        if (row == NULL) {
            PyMem_Free(xyz);
            Py_DECREF(seq);
            return NULL;
        }
        if (PySequence_Fast_GET_SIZE(row) != 3) {
            Py_DECREF(row);
            PyMem_Free(xyz);
            Py_DECREF(seq);
            PyErr_SetString(PyExc_ValueError, "each coordinate must have exactly 3 components");
            return NULL;
        }
        for (int k = 0; k < 3; ++k) {
            double value = PyFloat_AsDouble(PySequence_Fast_GET_ITEM(row, k));
            if (value == -1.0 && PyErr_Occurred()) {
                Py_DECREF(row);
                PyMem_Free(xyz);
                Py_DECREF(seq);
                return NULL;
            }
            xyz[i * 3 + k] = value;
        }
        Py_DECREF(row);
    }
    Py_DECREF(seq);
    *n_out = n;
    return xyz;
}

static double *
copy_floats(PyObject *obj, Py_ssize_t expected, const char *what)
{
    PyObject *seq = PySequence_Fast(obj, what);
    if (seq == NULL) {
        return NULL;
    }
    if (PySequence_Fast_GET_SIZE(seq) != expected) {
        Py_DECREF(seq);
        PyErr_Format(PyExc_ValueError, "%s must have %zd entries", what, expected);
        return NULL;
    }
    double *values = (double *)PyMem_Malloc((size_t)(expected > 0 ? expected : 1) * sizeof(double));
    if (values == NULL) {
        Py_DECREF(seq);
        PyErr_NoMemory();
        return NULL;
    }
    for (Py_ssize_t i = 0; i < expected; ++i) {
        values[i] = PyFloat_AsDouble(PySequence_Fast_GET_ITEM(seq, i));
        if (PyErr_Occurred()) {
            PyMem_Free(values);
            Py_DECREF(seq);
            return NULL;
        }
    }
    Py_DECREF(seq);
    return values;
}

/* ------------------------------------------------------------------ */
/* Distance matrix                                                     */
/* ------------------------------------------------------------------ */

static PyObject *
accel_distance_matrix(PyObject *self, PyObject *args)
{
    PyObject *coords_obj;
    if (!PyArg_ParseTuple(args, "O", &coords_obj)) {
        return NULL;
    }
    Py_ssize_t n = 0;
    double *xyz = copy_coords(coords_obj, &n);
    if (xyz == NULL) {
        return NULL;
    }

    Py_ssize_t count = n * (n - 1) / 2;
    PyObject *list = PyList_New(count);
    if (list == NULL) {
        PyMem_Free(xyz);
        return NULL;
    }

    Py_ssize_t pos = 0;
    for (Py_ssize_t i = 0; i < n; ++i) {
        for (Py_ssize_t j = i + 1; j < n; ++j) {
            double dx = xyz[i * 3] - xyz[j * 3];
            double dy = xyz[i * 3 + 1] - xyz[j * 3 + 1];
            double dz = xyz[i * 3 + 2] - xyz[j * 3 + 2];
            PyObject *value = PyFloat_FromDouble(sqrt(dx * dx + dy * dy + dz * dz));
            if (value == NULL) {
                Py_DECREF(list);
                PyMem_Free(xyz);
                return NULL;
            }
            PyList_SET_ITEM(list, pos++, value);
        }
    }
    PyMem_Free(xyz);
    return list;
}

/* ------------------------------------------------------------------ */
/* Bond perception                                                     */
/* ------------------------------------------------------------------ */

static PyObject *
accel_perceive_bonds(PyObject *self, PyObject *args, PyObject *kwargs)
{
    static char *keywords[] = {"coords", "radii", "tolerance", "min_distance", NULL};
    PyObject *coords_obj, *radii_obj;
    double tolerance = 1.3;
    double min_distance = 0.4;

    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "OO|dd", keywords,
                                     &coords_obj, &radii_obj, &tolerance, &min_distance)) {
        return NULL;
    }

    Py_ssize_t n = 0;
    double *xyz = copy_coords(coords_obj, &n);
    if (xyz == NULL) {
        return NULL;
    }
    double *rad = copy_floats(radii_obj, n, "radii");
    if (rad == NULL) {
        PyMem_Free(xyz);
        return NULL;
    }

    PyObject *bonds = PyList_New(0);
    if (bonds == NULL) {
        PyMem_Free(xyz);
        PyMem_Free(rad);
        return NULL;
    }

    for (Py_ssize_t i = 0; i < n; ++i) {
        for (Py_ssize_t j = i + 1; j < n; ++j) {
            double dx = xyz[i * 3] - xyz[j * 3];
            double dy = xyz[i * 3 + 1] - xyz[j * 3 + 1];
            double dz = xyz[i * 3 + 2] - xyz[j * 3 + 2];
            double dist = sqrt(dx * dx + dy * dy + dz * dz);
            if (dist < min_distance || dist > tolerance * (rad[i] + rad[j])) {
                continue;
            }
            PyObject *triple = Py_BuildValue("(nnd)", i, j, dist);
            if (triple == NULL || PyList_Append(bonds, triple) < 0) {
                Py_XDECREF(triple);
                Py_DECREF(bonds);
                PyMem_Free(xyz);
                PyMem_Free(rad);
                return NULL;
            }
            Py_DECREF(triple);
        }
    }

    PyMem_Free(xyz);
    PyMem_Free(rad);
    return bonds;
}

/* ------------------------------------------------------------------ */
/* Point-charge (Coulomb) energy                                       */
/* ------------------------------------------------------------------ */

static PyObject *
accel_coulomb_energy(PyObject *self, PyObject *args)
{
    PyObject *coords_obj, *charges_obj;
    if (!PyArg_ParseTuple(args, "OO", &coords_obj, &charges_obj)) {
        return NULL;
    }
    Py_ssize_t n = 0;
    double *xyz = copy_coords(coords_obj, &n);
    if (xyz == NULL) {
        return NULL;
    }
    double *q = copy_floats(charges_obj, n, "charges");
    if (q == NULL) {
        PyMem_Free(xyz);
        return NULL;
    }

    /* 332.06371 converts e^2/Angstrom to kcal/mol. */
    const double KE = 332.0637133;
    double energy = 0.0;
    for (Py_ssize_t i = 0; i < n; ++i) {
        for (Py_ssize_t j = i + 1; j < n; ++j) {
            double dx = xyz[i * 3] - xyz[j * 3];
            double dy = xyz[i * 3 + 1] - xyz[j * 3 + 1];
            double dz = xyz[i * 3 + 2] - xyz[j * 3 + 2];
            double dist = sqrt(dx * dx + dy * dy + dz * dz);
            if (dist < 1e-6) {
                continue;
            }
            energy += KE * q[i] * q[j] / dist;
        }
    }

    PyMem_Free(xyz);
    PyMem_Free(q);
    return PyFloat_FromDouble(energy);
}

/* ------------------------------------------------------------------ */
/* Module boilerplate                                                  */
/* ------------------------------------------------------------------ */

static PyMethodDef accel_methods[] = {
    {"distance_matrix", accel_distance_matrix, METH_VARARGS,
     "Flattened upper-triangle pairwise distance matrix (Angstrom)."},
    {"perceive_bonds", (PyCFunction)accel_perceive_bonds, METH_VARARGS | METH_KEYWORDS,
     "perceive_bonds(coords, radii, tolerance=1.3, min_distance=0.4)"},
    {"coulomb_energy", accel_coulomb_energy, METH_VARARGS,
     "Point-charge Coulomb energy in kcal/mol."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef accel_module = {
    PyModuleDef_HEAD_INIT,
    "_pyscf_mobile_accel",
    "Native acceleration helpers for pyscf-mobile.",
    -1,
    accel_methods,
    NULL, NULL, NULL, NULL
};

PyMODINIT_FUNC
PyInit__pyscf_mobile_accel(void)
{
    PyObject *module = PyModule_Create(&accel_module);
    if (module == NULL) {
        return NULL;
    }
    PyModule_AddStringConstant(module, "__version__", "0.1.0");
    PyModule_AddIntConstant(module, "is_native", 1);
    return module;
}
