/// Per-row overflow storage for entries that fall outside the symbolic LU pattern.
///
/// When partial pivoting swaps rows during sparse LU factorization, the new row
/// may have non-zeros at columns not predicted by symbolic analysis. These entries
/// are stored here using a sorted array of (column, value) pairs.
struct DynamicSparseRow<Value: Sendable>: Sendable {

    private var entries: [(column: Int, value: Value)] = []

    /// The number of overflow entries in this row.
    var count: Int { entries.count }

    /// Sets the value at the given column, inserting or updating as needed.
    mutating func set(column: Int, value: Value) {
        if let idx = entries.firstIndex(where: { $0.column >= column }) {
            if entries[idx].column == column {
                entries[idx].value = value
            } else {
                entries.insert((column, value), at: idx)
            }
        } else {
            entries.append((column, value))
        }
    }

    /// Retrieves the value at the given column, or nil if not present.
    func get(column: Int) -> Value? {
        for entry in entries where entry.column == column {
            return entry.value
        }
        return nil
    }

    /// Iterates over all entries, calling the closure with (column, value).
    func forEach(_ body: (Int, Value) -> Void) {
        for entry in entries {
            body(entry.column, entry.value)
        }
    }
}
