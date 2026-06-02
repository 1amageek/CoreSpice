import Testing
@testable import CoreSpiceAnalysis

@Suite("Solution Trace Tests")
struct SolutionTraceTests {

    @Test
    func storesRowsInContiguousRowMajorOrder() {
        var trace = SolutionTrace(variableCount: 3, estimatedPointCapacity: 2)
        trace.append([1.0, 2.0, 3.0])
        trace.append([4.0, 5.0, 6.0])

        #expect(trace.pointCount == 2)
        #expect(trace.variableCount == 3)
        #expect(trace.rowMajorValues == [1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
        #expect(trace.value(pointIndex: 1, variableIndex: 2) == 6.0)
    }

    @Test
    func exposesPointBufferWithoutMaterializingRows() {
        var trace = SolutionTrace(variableCount: 2)
        trace.append([10.0, 20.0])
        trace.append([30.0, 40.0])

        let values = trace.withPoint(at: 1) { point in
            #expect(point.count == 2)
            return [point[0], point[1]]
        }

        #expect(values == [30.0, 40.0])
    }

    @Test
    func exposesColumnViewWithoutMaterializingRows() {
        let trace = SolutionTrace(
            variableCount: 3,
            rowMajorValues: [
                1.0, 2.0, 3.0,
                4.0, 5.0, 6.0,
                7.0, 8.0, 9.0
            ]
        )

        let column = trace.column(variableIndex: 1)

        #expect(column.count == 3)
        #expect(Array(column) == [2.0, 5.0, 8.0])
    }

    @Test
    func transientResultExposesTraceBackedPointAccess() {
        let trace = SolutionTrace(
            variableCount: 2,
            rowMajorValues: [1.0, 2.0, 3.0, 4.0]
        )
        let result = TransientResult(
            timePoints: [0.0, 1.0],
            solutionTrace: trace,
            variableMap: [:],
            timeSteps: 1,
            rejectedSteps: 0
        )

        #expect(result.value(variableIndex: 1, timeIndex: 0) == 2.0)
        let secondPoint = result.withSolution(at: 1) { point in
            [point[0], point[1]]
        }
        #expect(secondPoint == [3.0, 4.0])
    }
}
