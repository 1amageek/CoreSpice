import CoreSpiceMOSContracts
import CoreSpiceParsedIR

extension FrontendStorage {
    func location(_ location: SourceLocation?) throws { try text(location?.file) }
    func origin(_ origin: ParsedStatementOrigin?) throws { try text(origin?.captureID); try location(origin?.location) }
    func values(_ dictionary: [String: ParsedParameterValue]) throws {
        try budget.add(MOSStorageBudget.capacityBytes(dictionary.capacity, of: (String, ParsedParameterValue).self))
        for (name, value) in dictionary { try text(name); try self.value(value) }
    }
    func strings(_ strings: [String]) throws { try retain(strings); for string in strings { try text(string) } }
    func sourceEvidence(_ source: ParsedNetlist) throws {
        try budget.add(MOSStorageBudget.capacityBytes(source.initialConditions.capacity, of: (String, ParsedParameterValue).self))
        try budget.add(MOSStorageBudget.capacityBytes(source.nodeSets.capacity, of: (String, ParsedParameterValue).self))
        try retain(source.preprocessingEvents)
        for event in source.preprocessingEvents { try text(event.expression); try location(event.location) }
        try retain(source.dependencyEvents)
        for event in source.dependencyEvents {
            try spend(); try text(event.parentCaptureID); try text(event.childCaptureID); try location(event.location)
            try text(event.path); try text(event.selectedSection); try text(event.parentSection); try text(event.preprocessingIdentity)
            try budget.add(MOSStorageBudget.capacityBytes(event.preprocessingContext.capacity, of: (String, String).self))
            for (name, value) in event.preprocessingContext { try text(name); try text(value) }
        }
        try retain(source.pvtCorners)
        for corner in source.pvtCorners { try text(corner.name); try values(corner.parameters) }
        try retain(source.mcVariations)
        for variation in source.mcVariations { try text(variation.parameter) }
    }
    func output(_ output: OutputVariable, depth: Int = 1) throws {
        guard depth <= maximumExpressionDepth else { throw MOSResolutionFailure.limitExceeded(.expressionDepth) }
        try spend(); try budget.add(UInt64(MemoryLayout<OutputVariable>.stride))
        switch output {
        case .voltage(let node, let reference): try text(node); try text(reference)
        case .current(let device), .power(let device): try text(device)
        case .magnitude(let child), .phase(let child), .real(let child), .imaginary(let child), .dB(let child): try self.output(child, depth: depth + 1)
        case .expression(let expression): try self.expression(expression)
        }
    }
    func optionalValue(_ value: ParsedParameterValue?) throws { if let value { try self.value(value) } }
    func controls(_ controls: [ParsedControlStatement]) throws {
        try retain(controls)
        for control in controls {
            try spend()
            switch control {
            case .include(let path, let location), .hdl(let path, let location): try text(path); try self.location(location)
            case .library(let path, let section, let location): try text(path); try text(section); try self.location(location)
            case .option(let name, let value, let location): try text(name); try optionalValue(value); try self.location(location)
            case .temp(let value, let location): try self.value(value); try self.location(location)
            case .initialCondition(let node, let value, let location), .nodeSet(let node, let value, let location): try text(node); try self.value(value); try self.location(location)
            case .save(let names, let location), .probe(let names, let location), .global(let names, let location): try strings(names); try self.location(location)
            case .print(let spec): try retain(spec.variables); for variable in spec.variables { try output(variable) }; try location(spec.location)
            case .plot(let spec): try retain(spec.variables); for variable in spec.variables { try output(variable) }; try location(spec.location)
            case .end(let location), .endControl(let location): try self.location(location)
            case .alter(let spec): try text(spec.target); try text(spec.parameter); try value(spec.value); try location(spec.location)
            case .function(let name, let parameters, let body, let location): try text(name); try strings(parameters); try expression(body); try self.location(location)
            case .measure(let spec):
                try text(spec.resultName); try location(spec.location)
                switch spec.measureType {
                case .when(let condition, let target): try expression(condition); if let target { try expression(target) }
                case .find(let variable, let at): try output(variable); try value(at)
                case .average(let variable, let from, let to), .rms(let variable, let from, let to), .min(let variable, let from, let to), .max(let variable, let from, let to), .peakToPeak(let variable, let from, let to), .integral(let variable, let from, let to): try output(variable); try optionalValue(from); try optionalValue(to)
                case .riseTime(let variable, _, _), .fallTime(let variable, _, _): try output(variable)
                case .delay(let first, let firstValue, let second, let secondValue): try output(first); try value(firstValue); try output(second); try value(secondValue)
                case .unsupported(let keyword, let arguments, let reason): try text(keyword); try strings(arguments); try text(reason)
                }
            }
        }
    }
    func analysis(_ analysis: ParsedAnalysisCommand, recursive: Bool = true, depth: Int = 1) throws {
        guard depth <= maximumExpressionDepth else { throw MOSResolutionFailure.limitExceeded(.expressionDepth) }
        try spend(); try budget.add(UInt64(MemoryLayout<ParsedAnalysisCommand>.stride))
        switch analysis {
        case .op: break
        case .dc(let spec):
            try text(spec.source); try text(spec.source2); try value(spec.startValue); try value(spec.stopValue); try value(spec.stepValue)
            try optionalValue(spec.startValue2); try optionalValue(spec.stopValue2); try optionalValue(spec.stepValue2)
        case .ac(let spec): try value(spec.startFrequency); try value(spec.stopFrequency)
        case .transient(let spec): try value(spec.stopTime); try optionalValue(spec.stepTime); try optionalValue(spec.startTime); try optionalValue(spec.maxStep)
        case .noise(let spec): try text(spec.outputNode); try text(spec.referenceNode); try text(spec.inputSource); try value(spec.startFrequency); try value(spec.stopFrequency)
        case .transferFunction(let spec): try text(spec.output); try text(spec.input)
        case .sensitivity(let spec): try text(spec.output); if let ac = spec.acSpec { try value(ac.startFrequency); try value(ac.stopFrequency) }
        case .monteCarlo(let spec): if recursive { try self.analysis(spec.analysis, depth: depth + 1) }
        case .poleZero(let spec): try text(spec.inputNode); try text(spec.inputReference); try text(spec.outputNode); try text(spec.outputReference)
        case .fourier(let spec): try value(spec.frequency); try strings(spec.outputs)
        }
    }
}
