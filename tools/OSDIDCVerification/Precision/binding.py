"""Independent implementation of the published Native v6 typed-facts commitment."""
import hashlib
import artifact as a

FACTS_DOMAIN = 'CoreSpice.native-precision-replay-facts.v1'
FINAL_DOMAIN = 'CoreSpice.native-configuration.v6.osdi-precision-binding'
SOLVER = 'CoreSpice.SparseLU.SwiftCSC.v2'
LEGACY_SOLVER = 'CoreSpice.SparseLU.Accelerate.v1'
ALGORITHM_SOLVER_CONTRACTS = ((a.ALGORITHM, SOLVER), (a.ALGORITHM, LEGACY_SOLVER))


class Encoder:
    """Stream fixed u64/UTF-8 frames into SHA; never materialize an unbounded body."""
    def __init__(self, domain, maximum):
        self.maximum = maximum
        self.count = 0
        self.sha = hashlib.sha256()
        self.text(domain)

    def write(self, data):
        a.require(len(data) <= self.maximum-self.count, 'binding_encoding_limit')
        self.sha.update(data)
        self.count += len(data)

    def u(self, value):
        self.write(a.integer(value).to_bytes(8, 'big'))

    def text(self, value):
        a.require(isinstance(value, str), 'binding_string')
        data = value.encode('utf-8')
        a.require(len(data) <= self.maximum-self.count-8, 'binding_string_limit')
        self.u(len(data)); self.write(data)

    def number(self, value):
        self.u(0 if a.real(value) == 0 else a.bits(value))

    def digest(self, value):
        self.text('sha256'); self.text(a.digest(value))

    def reference(self, value):
        identity = a.artifact_identity(value)
        self.digest(identity['sha256']); self.u(identity['byteCount'])
        for name in ('role', 'kind', 'format'):
            self.text(value['descriptor'][name])

    def optional(self, value, text=False):
        self.u(0 if value is None else 1)
        if value is not None:
            self.text(value) if text else self.u(value)

    def boolean(self, value):
        a.require(type(value) is bool, 'binding_boolean')
        self.u(int(value))

    def assignment(self, value):
        self.text(value['name'])
        a.require(value['scope'] in ('model', 'instance'), 'binding_scope')
        self.u(0 if value['scope'] == 'model' else 1)
        kind, scalar = value['type'], value['value']
        self.text(kind)
        if kind == 'real':
            self.number(scalar)
        elif kind == 'integer':
            a.require(type(scalar) is int and -(1<<31) <= scalar < (1<<31), 'binding_int32')
            self.u(scalar & ((1<<64)-1))
        elif kind == 'string':
            self.text(scalar)
        else:
            raise a.Refusal('binding_parameter_type')

    def settings(self, value):
        self.text('tran'); self.u(value['analysisIndex']); self.u(value['seed'])
        convergence, transient, limits = value['convergence'], value['transient'], value['numericalLimits']
        for name in ('abstol', 'reltol', 'vntol', 'gmin', 'minDamping', 'opticalPowerTolerance'):
            self.number(convergence[name])
        self.u(convergence['maxIterations'])
        for name in ('stopTime', 'maxTimeStep', 'minTimeStep', 'lteTolerance', 'shrinkFactor'):
            self.number(transient[name])
        initial = transient.get('initialTimeStep')
        self.u(0 if initial is None else 1)
        if initial is not None:
            self.number(initial)
        self.text(transient['preferredMethod']); self.boolean(transient['useInitialConditions'])
        self.u(transient['maxTimeStepReductions']); self.u(transient['gminSteppingThreshold'])
        for name in ('initialGmin', 'finalGmin', 'gminReductionFactor'):
            self.number(transient[name])
        self.u(transient['maximumGminSteps'])
        for name in ('maximumAcceptedSteps', 'maximumSolveAttempts', 'maximumNewtonIterations', 'maximumSavedScalars',
                     'maximumMatrixDimension', 'maximumWorkUnits', 'maximumBreakpoints'):
            self.u(limits[name])
        for name in ('initialConditions', 'nodeSets'):
            self.u(len(value[name]))
            for item in value[name]:
                self.optional(item.get('row')); self.number(item['value'])
        self.number(value['temperatureKelvin']); self.number(value['nominalTemperatureKelvin'])

    def model(self, model):
        value, original = model.cold, model.original
        program, topology = value['program'], value['program']['topology']
        self.text(value['instanceName']); self.text(original['modelName']); self.reference(program['modelReference'])
        self.u(program['descriptorIndex']); self.text(original['expectedDescriptorName'])
        for name in ('modelParameters', 'instanceParameters'):
            self.u(len(original[name]))
            for assignment in original[name]:
                self.assignment(assignment)
        previous = original['previousState']
        self.u(len(previous))
        for number in previous:
            self.number(number)
        resolved = original['resolvedParameters']
        self.u(len(resolved))
        for parameter in resolved:
            self.assignment(parameter); self.u(parameter['descriptorIndex']); self.boolean(parameter['isGiven'])
        self.number(original['effectiveKelvin'])
        self.u(topology['activeUnknownCount']); self.u(topology['stateCount']); self.u(len(topology['nodes']))
        for node in topology['nodes']:
            self.u(node['index'])
            for name in ('name', 'units', 'residualUnits'):
                self.text(node[name])
            self.boolean(node['isFlow'])
            for name in ('unknownNature', 'residualNature'):
                self.u(node[name]['kind']); self.u(node[name]['index'])
            self.optional(node.get('activeUnknownIndex'))
        self.u(len(original['rawNodeGlobalRows']))
        for row in original['rawNodeGlobalRows']:
            self.optional(row)
        self.digest(program['programSHA256']); self.u(len(model.program))
        self.digest(program['setupSHA256']); self.u(len(model.setup))
        self.digest(program['semanticProfileSHA256']); self.reference(value['workerReference'])
        self.digest(value['numericProfileSHA256']); self.u(value['precisionBits'])
        for name in ('maximumProgramBytes', 'maximumMappingBytes', 'arenaBytes', 'maximumWorkUnits',
                     'minimumPrecisionBits', 'maximumPrecisionBits', 'startupTimeoutNanoseconds',
                     'evaluationTimeoutNanoseconds', 'cleanupTimeoutNanoseconds', 'pollNanoseconds'):
            self.u(value['options'][name])


def expected_identity(decoded):
    precision = decoded.precision
    a.require((precision['algorithmIdentity'], precision['solverIdentity']) in ALGORITHM_SOLVER_CONTRACTS,
              'binding_algorithm_solver')
    maximum = min(a.MAX_JSON, precision['executionBudget']['maximumEvidenceBytes'])
    facts = Encoder(FACTS_DOMAIN, maximum)
    facts.digest(precision['sourceInputIdentity'])
    facts.text(precision['algorithmIdentity']); facts.text(precision['solverIdentity'])
    facts.settings(precision['settings'])
    sources = precision['sources']
    facts.text(sources['rootKey']); facts.u(len(sources['captures']))
    for capture in sources['captures']:
        facts.text(capture['key']); facts.reference(capture['reference'])
    facts.u(len(sources['occurrences']))
    for occurrence in sources['occurrences']:
        facts.text(occurrence['key']); facts.u(occurrence['occurrenceID'])
        for name in ('parentOccurrenceID', 'statementByteOffset', 'statementOrdinal'):
            facts.optional(occurrence.get(name))
        for name in ('kind', 'parentSection', 'selectedSection'):
            facts.optional(occurrence.get(name), text=True)
    facts.u(len(decoded.execution['rows']))
    for row in decoded.execution['rows']:
        facts.u(row['row']); facts.text(row['kind'])
        facts.optional(row.get('sourceName'), text=True); facts.text(row['unit'])
    facts.u(len(precision['equationPolicy']))
    for row in precision['equationPolicy']:
        facts.text(row['kind']); facts.number(row['variableAbsoluteTolerance']); facts.number(row['equationAbsoluteTolerance'])
    facts.u(len(decoded.models))
    for model in decoded.models:
        facts.model(model)
    facts_digest = facts.sha.hexdigest()
    final = Encoder(FINAL_DOMAIN, maximum)
    final.digest(precision['legacyBaseDigest']); final.digest(facts_digest)
    return final.sha.hexdigest(), {'factsDigest': facts_digest, 'factsEncodingBytes': facts.count,
                                  'finalEncodingBytes': final.count, 'legacyBaseDigest': precision['legacyBaseDigest']}


def verify(decoded):
    try:
        identity, details = expected_identity(decoded)
        a.require(identity == decoded.precision['configurationSHA256'] == decoded.record['configurationIdentity'], 'native_v6_configuration_mismatch')
        return details
    except (KeyError, TypeError, OverflowError, UnicodeError) as error:
        raise a.Refusal('malformed_native_v6_binding:'+str(error)) from error
