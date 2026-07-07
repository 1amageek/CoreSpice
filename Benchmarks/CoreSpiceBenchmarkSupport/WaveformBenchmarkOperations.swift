import CoreSpiceIO

public enum WaveformBenchmarkOperations {
    public static func lazyProjectionComparison() throws -> BenchmarkComparison {
        let pointCount = 12_000
        let variableCount = 12
        let waveform = WaveformBenchmarkFixture.waveform(
            pointCount: pointCount,
            variableCount: variableCount
        )
        let base: any WaveformReadable = waveform
        let pointIndices = WaveformBenchmarkFixture.pointIndices(pointCount: pointCount)
        let variableIndices = WaveformBenchmarkFixture.variableIndices(variableCount: variableCount)
        let projection = WaveformProjection(
            basePointCount: waveform.pointCount,
            baseVariableCount: waveform.variableCount,
            pointIndices: pointIndices,
            variableIndices: variableIndices
        )
        let layout = WaveformViewLayout(base: base, projection: projection)

        let lazyProjection = try BenchmarkRunner.measure(
            "waveform.lazyProjection",
            iterationsPerSample: 3_000
        ) {
            let view = WaveformDataView(
                base: base,
                layout: layout
            )
            return Double(view.pointCount + view.variableCount)
        }

        let materialization = try BenchmarkRunner.measure(
            "waveform.materializedProjection",
            iterationsPerSample: 20
        ) {
            let view = WaveformDataView(
                base: base,
                layout: layout
            )
            let materialized = try view.materialized()
            return Double(materialized.pointCount + materialized.variableCount)
        }

        return BenchmarkComparison(
            name: "lazy waveform projection",
            measured: lazyProjection,
            baseline: materialization,
            maximumRatio: 0.20,
            requirement: "Lazy projection must remain at least 5x cheaper than materializing the same projection."
        )
    }

    public static func borrowedPointScanComparison() throws -> BenchmarkComparison {
        let waveform = WaveformBenchmarkFixture.waveform()
        let borrowedReference = try sumBorrowedRows(waveform)
        let materializedReference = try sumMaterializedRows(waveform)
        guard abs(borrowedReference - materializedReference) < abs(materializedReference) * 1e-12 else {
            throw BenchmarkError.referenceMismatch(
                name: "waveform.rowScan",
                lhs: borrowedReference,
                rhs: materializedReference
            )
        }

        let borrowedScan = try BenchmarkRunner.measure(
            "waveform.borrowedPointScan",
            iterationsPerSample: 12
        ) {
            try sumBorrowedRows(waveform)
        }

        let materializedScan = try BenchmarkRunner.measure(
            "waveform.materializedRowScan",
            iterationsPerSample: 4
        ) {
            try sumMaterializedRows(waveform)
        }

        return BenchmarkComparison(
            name: "borrowed row-major point scan",
            measured: borrowedScan,
            baseline: materializedScan,
            maximumRatio: 1.10,
            requirement: "Borrowed row-major scans should not be materially slower than repeated [[Double]] materialization."
        )
    }

    public static func projectedRowMajorScanComparison() throws -> BenchmarkComparison {
        let pointCount = 12_000
        let variableCount = 12
        let waveform = WaveformBenchmarkFixture.waveform(
            pointCount: pointCount,
            variableCount: variableCount
        )
        let base: any WaveformReadable = waveform
        let projection = WaveformProjection(
            basePointCount: waveform.pointCount,
            baseVariableCount: waveform.variableCount,
            pointIndices: WaveformBenchmarkFixture.pointIndices(pointCount: pointCount),
            variableIndices: WaveformBenchmarkFixture.variableIndices(variableCount: variableCount)
        )
        let layout = WaveformViewLayout(base: base, projection: projection)
        let view = WaveformDataView(base: base, layout: layout)
        let materialized = try view.materialized()

        let borrowedReference = try sumProjectedRows(view)
        let materializedReference = try sumMaterializedRows(materialized)
        guard abs(borrowedReference - materializedReference) < abs(materializedReference) * 1e-12 else {
            throw BenchmarkError.referenceMismatch(
                name: "waveform.projectedRowMajorScan",
                lhs: borrowedReference,
                rhs: materializedReference
            )
        }

        let borrowedScan = try BenchmarkRunner.measure(
            "waveform.projectedBorrowedScan",
            iterationsPerSample: 20
        ) {
            try sumProjectedRows(view)
        }

        let materializedScan = try BenchmarkRunner.measure(
            "waveform.projectedMaterializedScan",
            iterationsPerSample: 8
        ) {
            try sumMaterializedRows(materialized)
        }

        return BenchmarkComparison(
            name: "projected row-major scan",
            measured: borrowedScan,
            baseline: materializedScan,
            maximumRatio: 0.35,
            requirement: "Projected row-major scans should use strided borrowed storage instead of copied rows."
        )
    }

    public static func transientConversionComparison() throws -> BenchmarkComparison {
        let pointCount = 12_000
        let variableCount = 12
        let result = try WaveformBenchmarkFixture.transientResult(
            pointCount: pointCount,
            variableCount: variableCount
        )
        let topology = WaveformBenchmarkFixture.topology(variableCount: variableCount)
        let variableLayout = WaveformVariableLayout(
            variableMap: result.variableMap,
            topology: topology
        )

        let conversion = try BenchmarkRunner.measure(
            "transient.convertToWaveform",
            iterationsPerSample: 200
        ) {
            let waveform = try WaveformData.from(
                transientResult: result,
                variableLayout: variableLayout,
                title: "Benchmark"
            )
            guard let rowMajor = waveform.realRowMajorValues else {
                throw BenchmarkError.missingRowMajorStorage("transient.convertToWaveform")
            }
            return Double(rowMajor.pointCount + rowMajor.variableCount)
        }

        let materializedRows = try BenchmarkRunner.measure(
            "transient.convertAndMaterializeRows",
            iterationsPerSample: 4
        ) {
            let waveform = try WaveformData.from(
                transientResult: result,
                variableLayout: variableLayout,
                title: "Benchmark"
            )
            guard let rows = waveform.allRealData else {
                throw BenchmarkError.missingRowMajorStorage("transient.convertAndMaterializeRows")
            }
            return Double(rows.count + (rows.first?.count ?? 0))
        }

        let waveform = try WaveformData.from(
            transientResult: result,
            variableLayout: variableLayout,
            title: "Benchmark"
        )
        let source = result.solutionTrace.rowMajorValues
        guard let rowMajor = waveform.realRowMajorValues else {
            throw BenchmarkError.missingRowMajorStorage("transient.convertToWaveform")
        }
        let sharesStorage = source.withUnsafeBufferPointer { sourceBuffer in
            rowMajor.values.withUnsafeBufferPointer { rowMajorBuffer in
                sourceBuffer.baseAddress == rowMajorBuffer.baseAddress
            }
        }
        guard sharesStorage else {
            throw BenchmarkError.storageNotShared("transient.convertToWaveform")
        }

        return BenchmarkComparison(
            name: "transient result waveform conversion",
            measured: conversion,
            baseline: materializedRows,
            maximumRatio: 0.20,
            requirement: "Transient conversion must stay metadata-dominated relative to materializing rows."
        )
    }

    public static func sumBorrowedRows(_ waveform: WaveformData) throws -> Double {
        if let sum = waveform.withRealRowMajorValues({ values, _, _ in
            sum(values)
        }) {
            return sum
        }

        var sum = 0.0
        for point in 0..<waveform.pointCount {
            let completed = waveform.withRealValues(at: point) { values in
                for value in values {
                    sum += value
                }
                return true
            } ?? false
            guard completed else {
                throw BenchmarkError.missingPointBuffer("waveform.borrowedPointScan")
            }
        }
        return sum
    }

    public static func sumBorrowedRows(_ waveform: WaveformDataView) throws -> Double {
        if let sum = waveform.withRealRowMajorBuffer({ buffer in
            sum(buffer)
        }) {
            return sum
        }

        var sum = 0.0
        for point in 0..<waveform.pointCount {
            let completed = waveform.withRealValues(at: point) { values in
                for value in values {
                    sum += value
                }
                return true
            } ?? false
            guard completed else {
                throw BenchmarkError.missingPointBuffer("waveform.projectedBorrowedScan")
            }
        }
        return sum
    }

    public static func sumProjectedRows(_ waveform: WaveformDataView) throws -> Double {
        if let sum = waveform.withRealRowMajorBuffer({ buffer in
            sum(buffer)
        }) {
            return sum
        }

        var sum = 0.0
        for point in 0..<waveform.pointCount {
            let completed = waveform.forEachRealValue(at: point) { value in
                sum += value
            }
            guard completed else {
                throw BenchmarkError.missingPointBuffer("waveform.projectedBorrowedScan")
            }
        }
        return sum
    }

    public static func sumMaterializedRows(_ waveform: WaveformData) throws -> Double {
        guard let rows = waveform.allRealData else {
            throw BenchmarkError.missingRowMajorStorage("waveform.materializedRowScan")
        }
        var sum = 0.0
        for row in rows {
            for value in row {
                sum += value
            }
        }
        return sum
    }

    private static func sum(_ values: UnsafeBufferPointer<Double>) -> Double {
        guard let baseAddress = values.baseAddress else { return 0.0 }
        var sum = 0.0
        for index in 0..<values.count {
            sum += baseAddress[index]
        }
        return sum
    }

    private static func sum(_ buffer: RealRowMajorBuffer) -> Double {
        guard let baseAddress = buffer.values.baseAddress else { return 0.0 }
        var sum = 0.0
        for point in 0..<buffer.pointCount {
            let rowStart = buffer.startOffset + (point * buffer.rowStride)
            for variable in 0..<buffer.variableCount {
                sum += baseAddress[rowStart + variable]
            }
        }
        return sum
    }
}
