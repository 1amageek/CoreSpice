#include <metal_stdlib>
#include "SharedTypes.h"
using namespace metal;

// ---------------------------------------------------------------------------
// MZI mesh layer kernels for PluginsPhotonic.
//
// Each kernel applies one layer of 2x2 MZI transfer matrices to
// a batch of 512-element complex state vectors. The state buffer
// stores complex amplitudes as float2 (real, imag) pairs.
// ---------------------------------------------------------------------------

// Apply one layer with even pairing: pairs at (0,1), (2,3), (4,5), ...
kernel void applyLayer512_even(
    device float2* state [[buffer(0)]],
    const device MZICoefficients* coeffs [[buffer(1)]],
    constant LayerDescriptor& desc [[buffer(2)]],
    uint2 tid [[thread_position_in_grid]]
) {
    uint pair = tid.x;
    uint batch = tid.y;
    if (pair >= desc.count) return;

    uint idx0 = batch * 512 + (desc.offset + pair * 2);
    uint idx1 = idx0 + 1;

    float2 a = state[idx0];
    float2 b = state[idx1];

    MZICoefficients m = coeffs[pair];

    float2 m00 = float2(m.m00_real, m.m00_imag);
    float2 m01 = float2(m.m01_real, m.m01_imag);
    float2 m10 = float2(m.m10_real, m.m10_imag);
    float2 m11 = float2(m.m11_real, m.m11_imag);

    // Complex matrix-vector multiply: [out0, out1] = M * [a, b]
    float2 out0 = float2(
        m00.x * a.x - m00.y * a.y + m01.x * b.x - m01.y * b.y,
        m00.x * a.y + m00.y * a.x + m01.x * b.y + m01.y * b.x
    );
    float2 out1 = float2(
        m10.x * a.x - m10.y * a.y + m11.x * b.x - m11.y * b.y,
        m10.x * a.y + m10.y * a.x + m11.x * b.y + m11.y * b.x
    );

    state[idx0] = out0;
    state[idx1] = out1;
}

// Apply one layer with odd pairing: pairs at (1,2), (3,4), (5,6), ...
kernel void applyLayer512_odd(
    device float2* state [[buffer(0)]],
    const device MZICoefficients* coeffs [[buffer(1)]],
    constant LayerDescriptor& desc [[buffer(2)]],
    uint2 tid [[thread_position_in_grid]]
) {
    uint pair = tid.x;
    uint batch = tid.y;
    if (pair >= desc.count) return;

    uint idx0 = batch * 512 + (desc.offset + pair * 2 + 1);
    uint idx1 = idx0 + 1;

    // Guard against out-of-bounds access at the port boundary
    if ((idx1 % 512) == 0) return;

    float2 a = state[idx0];
    float2 b = state[idx1];

    MZICoefficients m = coeffs[pair];

    float2 m00 = float2(m.m00_real, m.m00_imag);
    float2 m01 = float2(m.m01_real, m.m01_imag);
    float2 m10 = float2(m.m10_real, m.m10_imag);
    float2 m11 = float2(m.m11_real, m.m11_imag);

    float2 out0 = float2(
        m00.x * a.x - m00.y * a.y + m01.x * b.x - m01.y * b.y,
        m00.x * a.y + m00.y * a.x + m01.x * b.y + m01.y * b.x
    );
    float2 out1 = float2(
        m10.x * a.x - m10.y * a.y + m11.x * b.x - m11.y * b.y,
        m10.x * a.y + m10.y * a.x + m11.x * b.y + m11.y * b.x
    );

    state[idx0] = out0;
    state[idx1] = out1;
}
