#include "CoreSpiceLAPACK.h"

#include <Accelerate/Accelerate.h>

_Static_assert(
    sizeof(CoreSpiceLAPACKInteger) == sizeof(__LAPACK_int),
    "CoreSpiceLAPACKInteger must match Accelerate's LP64 LAPACK integer"
);

CoreSpiceLAPACKInteger coreSpiceLAPACKFactorize(
    CoreSpiceLAPACKInteger rowCount,
    CoreSpiceLAPACKInteger columnCount,
    double *matrix,
    CoreSpiceLAPACKInteger leadingDimension,
    CoreSpiceLAPACKInteger *pivotIndices
) {
    __LAPACK_int info = 0;
    dgetrf_(
        (const __LAPACK_int *)&rowCount,
        (const __LAPACK_int *)&columnCount,
        matrix,
        (const __LAPACK_int *)&leadingDimension,
        (__LAPACK_int *)pivotIndices,
        &info
    );
    return (CoreSpiceLAPACKInteger)info;
}

CoreSpiceLAPACKInteger coreSpiceLAPACKSolveFactorized(
    char transpose,
    CoreSpiceLAPACKInteger dimension,
    CoreSpiceLAPACKInteger rightHandSideCount,
    double *factorizedMatrix,
    CoreSpiceLAPACKInteger leadingDimension,
    CoreSpiceLAPACKInteger *pivotIndices,
    double *rightHandSides,
    CoreSpiceLAPACKInteger rightHandSideLeadingDimension
) {
    __LAPACK_int info = 0;
    dgetrs_(
        &transpose,
        (const __LAPACK_int *)&dimension,
        (const __LAPACK_int *)&rightHandSideCount,
        factorizedMatrix,
        (const __LAPACK_int *)&leadingDimension,
        (__LAPACK_int *)pivotIndices,
        rightHandSides,
        (const __LAPACK_int *)&rightHandSideLeadingDimension,
        &info
    );
    return (CoreSpiceLAPACKInteger)info;
}

CoreSpiceLAPACKInteger coreSpiceLAPACKSolve(
    CoreSpiceLAPACKInteger dimension,
    CoreSpiceLAPACKInteger rightHandSideCount,
    double *matrix,
    CoreSpiceLAPACKInteger leadingDimension,
    CoreSpiceLAPACKInteger *pivotIndices,
    double *rightHandSides,
    CoreSpiceLAPACKInteger rightHandSideLeadingDimension
) {
    __LAPACK_int info = 0;
    dgesv_(
        (const __LAPACK_int *)&dimension,
        (const __LAPACK_int *)&rightHandSideCount,
        matrix,
        (const __LAPACK_int *)&leadingDimension,
        (__LAPACK_int *)pivotIndices,
        rightHandSides,
        (const __LAPACK_int *)&rightHandSideLeadingDimension,
        &info
    );
    return (CoreSpiceLAPACKInteger)info;
}

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
) {
    __LAPACK_int info = 0;
    dggev_(
        &computeLeftEigenvectors,
        &computeRightEigenvectors,
        (const __LAPACK_int *)&dimension,
        matrixA,
        (const __LAPACK_int *)&leadingDimensionA,
        matrixB,
        (const __LAPACK_int *)&leadingDimensionB,
        realNumerators,
        imaginaryNumerators,
        denominators,
        leftEigenvectors,
        (const __LAPACK_int *)&leftEigenvectorLeadingDimension,
        rightEigenvectors,
        (const __LAPACK_int *)&rightEigenvectorLeadingDimension,
        workspace,
        (const __LAPACK_int *)&workspaceCount,
        &info
    );
    return (CoreSpiceLAPACKInteger)info;
}
