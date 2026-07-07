extension WaveformReadable {

    /// Returns a lazy real-valued series for the named variable.
    public func realSeries(named name: String) -> RealWaveformView? {
        guard let index = variables.firstIndex(where: { $0.name == name }) else {
            return nil
        }
        do {
            return try RealWaveformView(validatingSource: self, variableIndex: index)
        } catch {
            return nil
        }
    }

    /// Returns a lazy real-valued series for the visible variable index.
    public func realSeries(at index: Int) -> RealWaveformView? {
        guard index >= 0, index < variableCount else { return nil }
        do {
            return try RealWaveformView(validatingSource: self, variableIndex: index)
        } catch {
            return nil
        }
    }

    /// Returns a lazy complex-valued series for the named variable.
    public func complexSeries(named name: String) -> ComplexWaveformView? {
        guard let index = variables.firstIndex(where: { $0.name == name }) else {
            return nil
        }
        do {
            return try ComplexWaveformView(validatingSource: self, variableIndex: index)
        } catch {
            return nil
        }
    }

    /// Returns a lazy complex-valued series for the visible variable index.
    public func complexSeries(at index: Int) -> ComplexWaveformView? {
        guard index >= 0, index < variableCount else { return nil }
        do {
            return try ComplexWaveformView(validatingSource: self, variableIndex: index)
        } catch {
            return nil
        }
    }
}
