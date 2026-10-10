import CoreSpiceParsedIR

/// Traverses effective source assignments without a copied name or sorting buffer.
internal struct SPICENodeVoltageAssignments {
    let kind: SPICENodeVoltageAssignmentKind
    let source: ParsedNetlist
    private var controlIndex = 0
    private var fallbackKey: String?
    init(kind: SPICENodeVoltageAssignmentKind, source: ParsedNetlist) {
        self.kind = kind; self.source = source
    }
    private var values: [String: ParsedParameterValue] {
        switch kind { case .initialConditions: source.initialConditions; case .nodeSets: source.nodeSets }
    }
    private func assignment(_ control: ParsedControlStatement) -> (name: String, value: ParsedParameterValue)? {
        switch (kind, control) {
        case (.initialConditions, .initialCondition(let name, let value, _)),
             (.nodeSets, .nodeSet(let name, let value, _)): (name, value)
        default: nil
        }
    }
    private func equal(_ lhs: String, _ rhs: String, work: SPICENodeVoltageWork?)
    throws(SPICENodeVoltageResolutionError) -> Bool {
        if let work { return try work.equalASCII(lhs, rhs) }
        return lhs.lowercased() == rhs.lowercased()
    }
    mutating func next(work: SPICENodeVoltageWork?) throws(SPICENodeVoltageResolutionError)
    -> (name: String, value: ParsedParameterValue)? {
        while controlIndex < source.controls.count {
            try work?.step()
            let index = controlIndex; controlIndex += 1
            guard let current = assignment(source.controls[index]) else { continue }
            var later = false
            for control in source.controls[(index + 1)...] {
                try work?.step()
                if let candidate = assignment(control), try equal(current.name, candidate.name, work: work) { later = true; break }
            }
            if later { continue }
            return current
        }
        var selected: String?
        for key in values.keys {
            try work?.step()
            if let fallbackKey, key <= fallbackKey { continue }
            var controlled = false
            for control in source.controls {
                try work?.step()
                if let current = assignment(control), try equal(current.name, key, work: work) { controlled = true; break }
            }
            if !controlled, selected == nil || key < selected! { selected = key }
        }
        guard let selected, let value = values[selected] else { return nil }
        fallbackKey = selected
        return (selected, value)
    }
}
