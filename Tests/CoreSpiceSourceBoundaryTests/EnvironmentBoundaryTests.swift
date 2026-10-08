import CoreSpiceParsedIR
import CoreSpiceParser
import Testing

@Suite("Checked preprocessing entry environment")
struct EnvironmentBoundaryTests {
    private let policy = "inspection-policy-v1"
    private var configuration: ParserConfiguration { ParserConfiguration(resolveIncludes: true) }

    @Test func independentlyFramedGoldenAndInsertionOrder() throws {
        let emptyResources = SourceBoundaryTestResources()
        let empty = try SPICEPreprocessingEnvironment.empty(policyIdentity: policy, configuration: configuration,
            resources: emptyResources, maximumPageByteCount: 1)
        // Golden values were independently framed with Python struct.pack('>Q') and hashlib.sha256.
        #expect(empty.identity == "sha256:71f83e10b9fae67dcbb099c6e4519c6db883c3b72fa1d9cb516ca039966f09a4")
        #expect(emptyResources.hashedBytes == 123)
        #expect(empty.parameters.isEmpty)
        let input = [SPICEPreprocessingParameter(name: "BETA", expression: "7"),
                     SPICEPreprocessingParameter(name: "Alpha", expression: "2 * beta")]
        let resources = SourceBoundaryTestResources()
        let environment = try SPICEPreprocessingEnvironment.admit(parameters: input, policyIdentity: policy,
            configuration: configuration, resources: resources, maximumPageByteCount: 7)
        #expect(environment.identity == "sha256:f955492900529c0ba1a6404e5ccac1ea188bc39e36ae2e2c78275b1ec23caef7")
        #expect(resources.hashedBytes == 173)
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.work(.lexicalBytes) > 0)
        #expect(resources.work(.retainedElements) > 0)
        #expect(environment.parameters[0] == SPICEPreprocessingParameter(name: "alpha", expression: "2 * beta"))
        #expect(environment.parameters[1] == SPICEPreprocessingParameter(name: "beta", expression: "7"))
        let reordered = try SPICEPreprocessingEnvironment.admit(parameters: [input[1], input[0]],
            policyIdentity: policy, configuration: configuration, resources: SourceBoundaryTestResources(),
            maximumPageByteCount: 4096)
        #expect(reordered.identity == environment.identity)
    }

    @Test func actualInputsAndCaseFlagDetermineIdentity() throws {
        let input = [SPICEPreprocessingParameter(name: "GAIN", expression: " 2 * x ")]
        func make(_ parameters: [SPICEPreprocessingParameter], policyIdentity: String,
                  configuration: ParserConfiguration) throws -> SPICEPreprocessingEnvironment {
            try SPICEPreprocessingEnvironment.admit(parameters: parameters, policyIdentity: policyIdentity,
                configuration: configuration, resources: SourceBoundaryTestResources(), maximumPageByteCount: 3)
        }
        let baseline = try make(input, policyIdentity: policy, configuration: configuration)
        #expect(baseline.parameters[0].expression == " 2 * x ")
        #expect(baseline.policyIdentity == policy)
        let expression = try make([SPICEPreprocessingParameter(name: "GAIN", expression: "2 * x")],
                                  policyIdentity: policy, configuration: configuration)
        let name = try make([SPICEPreprocessingParameter(name: "OFFSET", expression: " 2 * x ")],
                            policyIdentity: policy, configuration: configuration)
        let policyChange = try make(input, policyIdentity: "inspection-policy-v2", configuration: configuration)
        var sensitive = configuration
        sensitive.caseInsensitive = false
        let caseChange = try make(input, policyIdentity: policy, configuration: sensitive)
        #expect(expression.identity != baseline.identity)
        #expect(name.identity != baseline.identity)
        #expect(policyChange.identity != baseline.identity)
        #expect(caseChange.identity != baseline.identity)
        #expect(caseChange.caseInsensitive == false)
        #expect(caseChange.parameters[0].name == "gain")
        var unrelated = configuration
        unrelated.includePaths = ["/different/location"]
        unrelated.maxIncludeDepth = 17
        #expect(try make(input, policyIdentity: policy, configuration: unrelated).identity == baseline.identity)
    }

    @Test func inheritanceIsAnImmutableSortedOverlay() throws {
        let originalResources = SourceBoundaryTestResources()
        var original: SPICEPreprocessingEnvironment? = try SPICEPreprocessingEnvironment.admit(parameters: [
            SPICEPreprocessingParameter(name: "zeta", expression: "9"),
            SPICEPreprocessingParameter(name: "alpha", expression: "1")], policyIdentity: policy,
            configuration: configuration, resources: originalResources, maximumPageByteCount: 5)
        let inheritedResources = SourceBoundaryTestResources()
        var inherited: SPICEPreprocessingEnvironment? = try #require(original).inheriting(replacing: [
            SPICEPreprocessingParameter(name: "GAMMA", expression: "3"),
            SPICEPreprocessingParameter(name: "ALPHA", expression: "2")],
            resources: inheritedResources, maximumPageByteCount: 2)
        #expect(original?.parameters[0].expression == "1")
        #expect(inherited?.parameters.count == 3)
        #expect(inherited?.parameters[0] == SPICEPreprocessingParameter(name: "alpha", expression: "2"))
        #expect(inherited?.parameters[1] == SPICEPreprocessingParameter(name: "gamma", expression: "3"))
        #expect(inherited?.parameters[2] == SPICEPreprocessingParameter(name: "zeta", expression: "9"))
        #expect(inherited?.identity != original?.identity)
        let canonical = try SPICEPreprocessingEnvironment.admit(parameters: [
            SPICEPreprocessingParameter(name: "zeta", expression: "9"),
            SPICEPreprocessingParameter(name: "gamma", expression: "3"),
            SPICEPreprocessingParameter(name: "alpha", expression: "2")], policyIdentity: policy,
            configuration: configuration, resources: SourceBoundaryTestResources(), maximumPageByteCount: 256)
        #expect(inherited?.identity == canonical.identity)
        original = nil
        #expect(originalResources.used(.liveOwnedBytes) == 0)
        #expect(inherited?.parameters[2].expression == "9")
        inherited = nil
        #expect(inheritedResources.used(.liveOwnedBytes) == 0)
    }

    @Test func collisionsAreRefusedInInitialAndReplacementLists() throws {
        let duplicates = [SPICEPreprocessingParameter(name: "VALUE", expression: "1"),
                          SPICEPreprocessingParameter(name: "value", expression: "2")]
        let resources = SourceBoundaryTestResources()
        #expect(throws: SPICEBoundedSourceError.caseCollidingParameter) {
            try SPICEPreprocessingEnvironment.admit(parameters: duplicates, policyIdentity: policy,
                configuration: configuration, resources: resources, maximumPageByteCount: 4)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.hashedBytes == 0)
        let original = try SPICEPreprocessingEnvironment.empty(policyIdentity: policy, configuration: configuration,
            resources: SourceBoundaryTestResources(), maximumPageByteCount: 4)
        #expect(throws: SPICEBoundedSourceError.caseCollidingParameter) {
            try original.inheriting(replacing: duplicates, resources: resources, maximumPageByteCount: 4)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func unicodeNamesRefuseCooperativeNormalizationWithoutChangingExpressions() throws {
        let resources = SourceBoundaryTestResources()
        #expect(throws: SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode name normalization")) {
            try SPICEPreprocessingEnvironment.admit(parameters: [
                SPICEPreprocessingParameter(name: "g\u{00E4}in", expression: "2")], policyIdentity: policy,
                configuration: configuration, resources: resources, maximumPageByteCount: 1)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.hashedBytes == 0)
        let valid = try SPICEPreprocessingEnvironment.admit(parameters: [
            SPICEPreprocessingParameter(name: "gain", expression: "\u{03C0} + \u{1F642}")],
            policyIdentity: policy, configuration: configuration, resources: resources, maximumPageByteCount: 1)
        #expect(valid.parameters[0].expression == "\u{03C0} + \u{1F642}")
    }

    @Test func configurationAndPageAdmissionRefuseBeforeHashing() throws {
        let resources = SourceBoundaryTestResources()
        #expect(throws: SPICEBoundedSourceError.invalidEnvironment) {
            try SPICEPreprocessingEnvironment.empty(policyIdentity: policy, configuration: ParserConfiguration(),
                resources: resources, maximumPageByteCount: 4)
        }
        #expect(throws: SPICEBoundedSourceError.invalidEnvironment) {
            try SPICEPreprocessingEnvironment.empty(policyIdentity: "", configuration: configuration,
                resources: resources, maximumPageByteCount: 4)
        }
        for page in [UInt64(0), UInt64.max] {
            #expect(throws: SPICEBoundedSourceError.invalidPolicy) {
                try SPICEPreprocessingEnvironment.empty(policyIdentity: policy, configuration: configuration,
                    resources: resources, maximumPageByteCount: page)
            }
        }
        #expect(resources.hashedBytes == 0)
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func resourceFailuresPreserveTheirTypedCauseAndRefundOwners() {
        func attempt(_ resources: SourceBoundaryTestResources, _ expected: SourceBoundaryTestError,
                     page: UInt64 = 1) {
            #expect(throws: expected) {
                try SPICEPreprocessingEnvironment.empty(policyIdentity: policy, configuration: configuration,
                    resources: resources, maximumPageByteCount: page)
            }
            #expect(resources.used(.liveOwnedBytes) == 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
        let cancelled = SourceBoundaryTestResources()
        cancelled.setCancelled(true)
        attempt(cancelled, .cancelled)
        attempt(SourceBoundaryTestResources(liveLimit: 0), .limit(.liveOwnedBytes))
        attempt(SourceBoundaryTestResources(temporaryLimit: 0), .limit(.temporaryBytes))
        attempt(SourceBoundaryTestResources(workLimit: 0), .workLimit)
        let lateLiveRefusal = SourceBoundaryTestResources(liveLimit: UInt64(policy.utf8.count) + 70)
        attempt(lateLiveRefusal, .limit(.liveOwnedBytes))
        #expect(lateLiveRefusal.hashedBytes == 0)
        let finalizationRefusal = SourceBoundaryTestResources(temporaryLimit: 64)
        attempt(finalizationRefusal, .limit(.temporaryBytes))
        #expect(finalizationRefusal.hashedBytes == 0)
        let hashRefusal = SourceBoundaryTestResources(hashLimit: 10)
        attempt(hashRefusal, .hashLimit, page: 7)
        #expect(hashRefusal.hashedBytes == 7)
    }

    @Test func copiesAndEscapedEntriesRetainOnlyTheirOwnedPayloads() throws {
        let resources = SourceBoundaryTestResources()
        var original: SPICEPreprocessingEnvironment? = try SPICEPreprocessingEnvironment.admit(parameters: [
            SPICEPreprocessingParameter(name: "ALPHA", expression: "2 * beta"),
            SPICEPreprocessingParameter(name: "beta", expression: "7")], policyIdentity: policy,
            configuration: configuration, resources: resources, maximumPageByteCount: 4)
        let live = resources.used(.liveOwnedBytes)
        var copy = original
        original = nil
        #expect(resources.used(.liveOwnedBytes) == live)
        var entries: SPICEAccountedCollection<SPICEPreprocessingParameter>? = copy?.parameters
        var escaped: SPICEPreprocessingParameter? = entries?[0]
        copy = nil
        #expect(resources.used(.liveOwnedBytes) == live - UInt64(policy.utf8.count) - 71)
        entries = nil
        #expect(resources.used(.liveOwnedBytes) == 13)
        #expect(escaped?.name == "alpha")
        #expect(escaped?.expression == "2 * beta")
        escaped = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.releaseCount > 0)
    }
}
