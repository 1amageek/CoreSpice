#ifndef CORE_SPICE_LAPACK_H
#define CORE_SPICE_LAPACK_H

#include <stdint.h>

typedef int32_t CoreSpiceLAPACKInteger;

CoreSpiceLAPACKInteger coreSpiceLAPACKFactorize(
    CoreSpiceLAPACKInteger rowCount,
    CoreSpiceLAPACKInteger columnCount,
    double *matrix,
    CoreSpiceLAPACKInteger leadingDimension,
    CoreSpiceLAPACKInteger *pivotIndices
);

CoreSpiceLAPACKInteger coreSpiceLAPACKSolveFactorized(
    char transpose,
    CoreSpiceLAPACKInteger dimension,
    CoreSpiceLAPACKInteger rightHandSideCount,
    double *factorizedMatrix,
    CoreSpiceLAPACKInteger leadingDimension,
    CoreSpiceLAPACKInteger *pivotIndices,
    double *rightHandSides,
    CoreSpiceLAPACKInteger rightHandSideLeadingDimension
);

CoreSpiceLAPACKInteger coreSpiceLAPACKSolve(
    CoreSpiceLAPACKInteger dimension,
    CoreSpiceLAPACKInteger rightHandSideCount,
    double *matrix,
    CoreSpiceLAPACKInteger leadingDimension,
    CoreSpiceLAPACKInteger *pivotIndices,
    double *rightHandSides,
    CoreSpiceLAPACKInteger rightHandSideLeadingDimension
);

CoreSpiceLAPACKInteger coreSpiceLAPACKGeneralizedEigenvalues(
    char computeLeftEigenvectors,
    char computeRightEigenvectors,
    CoreSpiceLAPACKInteger dimension,
    double *matrixA,
    CoreSpiceLAPACKInteger leadingDimensionA,
    double *matrixB,
    CoreSpiceLAPACKInteger leadingDimensionB,
    double *realNumerators,
    double *imaginaryNumerators,
    double *denominators,
    double *leftEigenvectors,
    CoreSpiceLAPACKInteger leftEigenvectorLeadingDimension,
    double *rightEigenvectors,
    CoreSpiceLAPACKInteger rightEigenvectorLeadingDimension,
    double *workspace,
    CoreSpiceLAPACKInteger workspaceCount
);

#endif
