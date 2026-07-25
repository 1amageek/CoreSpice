import Testing
@testable import CoreSpiceAnalysis

@Suite("Solution Trace Tests")
struct SolutionTraceTests {

    @Test
    func storesRowsInContiguousRowMajorOrder() throws {
        var trace = try SolutionTrace(variableCount: 3, estimatedPointCapacity: 2)
        try trace.append([1.0, 2.0, 3.0])
        try trace.append([4.0, 5.0, 6.0])

        #expect(trace.pointCount == 2)
        #expect(trace.variableCount == 3)
        #expect(trace.rowMajorValues == [1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
        #expect(try trace.value(pointIndex: 1, variableIndex: 2) == 6.0)
    }

    @Test
    func exposesPointBufferWithoutMaterializingRows() throws {
        var trace = try SolutionTrace(variableCount: 2)
        try trace.append([10.0, 20.0])
        try trace.append([30.0, 40.0])

        let values = try trace.withPoint(at: 1) { point in
            #expect(point.count == 2)
            return [point[0], point[1]]
        }

        #expect(values == [30.0, 40.0])
    }

    @Test
    func exposesColumnViewWithoutMaterializingRows() throws {
        let trace = try SolutionTrace(
            variableCount: 3,
            rowMajorValues: [
                1.0, 2.0, 3.0,
                4.0, 5.0, 6.0,
                7.0, 8.0, 9.0
            ]
        )

        let column = try trace.column(variableIndex: 1)

        #expect(column.count == 3)
        #expect(Array(column) == [2.0, 5.0, 8.0])
    }

    @Test
    func transientResultExposesTraceBackedPointAccess() throws {
        let trace = try SolutionTrace(
            variableCount: 2,
            rowMajorValues: [1.0, 2.0, 3.0, 4.0]
        )
        let result = try TransientResult(
            timePoints: [0.0, 1.0],
            solutionTrace: trace,
            variableMap: [:],
            timeSteps: 1,
            rejectedSteps: 0
        )

        #expect(try result.value(variableIndex: 1, timeIndex: 0) == 2.0)
        #expect(try result.checkedValue(variableIndex: 1, timeIndex: 0) == 2.0)
        let secondPoint = try result.withSolution(at: 1) { point in
            [point[0], point[1]]
        }
        #expect(secondPoint == [3.0, 4.0])
    }

    @Test
    func rejectsInvalidTraceShape() {
        #expect(throws: SolutionTrace.ValidationError.negativeVariableCount(-1)) {
            _ = try SolutionTrace(variableCount: -1)
        }

        #expect(throws: SolutionTrace.ValidationError.invalidRowMajorValueCount(variableCount: 2, valueCount: 3)) {
            _ = try SolutionTrace(variableCount: 2, rowMajorValues: [1.0, 2.0, 3.0])
        }
    }

    @Test
    func rejectsCapacityOverflow() {
        #expect(
            throws: SolutionTrace.ValidationError.capacityOverflow(
                variableCount: Int.max,
                pointCapacity: 2
            )
        ) {
            _ = try SolutionTrace(
                variableCount: Int.max,
                estimatedPointCapacity: 2
            )
        }
    }

    @Test
    func rejectsMismatchedAppendWidth() throws {
        var trace = try SolutionTrace(variableCount: 2)

        #expect(throws: SolutionTrace.ValidationError.solutionWidthMismatch(expected: 2, actual: 1)) {
            try trace.append([1.0])
        }
    }

    @Test
    func rejectsOutOfRangeAccess() throws {
        var trace = try SolutionTrace(variableCount: 2)
        try trace.append([1.0, 2.0])

        #expect(throws: SolutionTrace.ValidationError.pointIndexOutOfRange(index: 1, pointCount: 1)) {
            _ = try trace.value(pointIndex: 1, variableIndex: 0)
        }

        #expect(throws: SolutionTrace.ValidationError.variableIndexOutOfRange(index: 2, variableCount: 2)) {
            _ = try trace.column(variableIndex: 2)
        }
    }

    @Test
    func transientResultCheckedAccessReportsInvalidIndices() throws {
        let trace = try SolutionTrace(
            variableCount: 2,
            rowMajorValues: [1.0, 2.0]
        )
        let result = try TransientResult(
            timePoints: [0.0],
            solutionTrace: trace,
            variableMap: [:],
            timeSteps: 0,
            rejectedSteps: 0
        )

        #expect(throws: SolutionTrace.ValidationError.pointIndexOutOfRange(index: 1, pointCount: 1)) {
            _ = try result.checkedValue(variableIndex: 0, timeIndex: 1)
        }
    }
}
