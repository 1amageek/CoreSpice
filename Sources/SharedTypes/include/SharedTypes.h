#ifndef SharedTypes_h
#define SharedTypes_h

#ifdef __METAL_VERSION__
#include <metal_stdlib>
using namespace metal;
#else
#include <stdint.h>
#endif

// ---------------------------------------------------------------------------
// SpiceComplex
//
// Double-precision complex number used by the SPICE simulation engine.
// CPU only — Metal does not support double-precision floats.
// GPU acceleration targets batch-level parallelism (Monte Carlo, sweeps),
// not the inner MNA solver which requires double precision for convergence.
// ---------------------------------------------------------------------------

#ifndef __METAL_VERSION__
typedef struct __attribute__((packed)) {
    double real;
    double imag;
} SpiceComplex;
#endif

// ---------------------------------------------------------------------------
// MZICoefficients
//
// 2x2 transfer-matrix coefficients for a Mach-Zehnder Interferometer.
//
//   | m00  m01 |
//   | m10  m11 |
//
// Each element is a complex value stored as a float pair (real, imag).
// Using single-precision floats keeps the struct GPU-friendly (32 bytes)
// while retaining sufficient accuracy for photonic mesh computations.
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    float m00_real;
    float m00_imag;
    float m01_real;
    float m01_imag;
    float m10_real;
    float m10_imag;
    float m11_real;
    float m11_imag;
} MZICoefficients;

// ---------------------------------------------------------------------------
// LayerDescriptor
//
// Describes a single layer within a photonic mesh (e.g. Clements / Reck).
//
//   offset  - index of the first MZI unit in this layer
//   count   - number of MZI units in this layer
//   pattern - 0 = even-column layer, 1 = odd-column layer
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    uint32_t offset;
    uint32_t count;
    uint32_t pattern;
} LayerDescriptor;

#endif /* SharedTypes_h */
