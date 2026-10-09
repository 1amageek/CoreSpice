import CoreSpiceParsedIR

public protocol SPICESimulationPreparing: Sendable {
    func prepare(_ request: SPICESimulationPreparationRequest, resources: any SPICESourceResourceAccounting)
        async throws(SPICESimulationPreparationError) -> PreparedSPICESimulation
}
