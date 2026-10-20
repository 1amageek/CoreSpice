import CoreSpiceAnalysis

/// Fixed-buffer numeric triplets; sorting and coalescing are explicitly checkpointed.
internal struct NativePrescribedVoltageMassTriplet: Sendable {
    var row: Int
    var column: Int
    var value: CompensatedEnclosure

    static func canonicalize(_ entries: inout [Self], scratch: inout [Self], count: Int,
        checkpoint: () throws -> Void) throws -> Int {
        var width = 1
        while width < count {
            var base = 0
            while base < count {
                let middle = base + min(width, count - base)
                let end = middle + min(width, count - middle)
                var left = base, right = middle
                for output in base..<end {
                    try checkpoint()
                    let takeLeft: Bool
                    if left == middle { takeLeft = false }
                    else if right == end { takeLeft = true }
                    else {
                        try checkpoint()
                        takeLeft = entries[left].row < entries[right].row
                            || (entries[left].row == entries[right].row && entries[left].column <= entries[right].column)
                    }
                    if takeLeft { scratch[output] = entries[left]; left += 1 }
                    else { scratch[output] = entries[right]; right += 1 }
                }
                base = end
            }
            swap(&entries, &scratch)
            width = width > count / 2 ? count : width * 2
        }
        var combined = 0
        for index in 0..<count {
            try checkpoint()
            let item = entries[index]
            if combined > 0, entries[combined - 1].row == item.row, entries[combined - 1].column == item.column {
                try checkpoint()
                entries[combined - 1].value = try entries[combined - 1].value.adding(item.value)
            } else { entries[combined] = item; combined += 1 }
        }
        let zero = try CompensatedEnclosure(center: .zero)
        var nonzero = 0
        for index in 0..<combined {
            try checkpoint()
            if entries[index].value != zero { entries[nonzero] = entries[index]; nonzero += 1 }
        }
        return nonzero
    }
}
