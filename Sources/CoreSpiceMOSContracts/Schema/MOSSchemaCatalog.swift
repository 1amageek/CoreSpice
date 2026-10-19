enum MOSSchemaCatalog {
    struct Parameter { let kind: MOSParameterKind; let canonicalName: String }
    static let level1Model = catalog(real: "vto kp gamma phi lambda tox cgso cgdo cgbo cj cjsw mj mjsw pb")
    static let level2Model = catalog(real: "vto kp gamma phi lambda tox cgso cgdo cgbo cj cjsw mj mjsw pb theta eta")
    static let level3Model = catalog(real: "vto kp gamma phi lambda tox cgso cgdo cgbo cj cjsw mj mjsw pb theta eta kappa vmax")
    static let simpleInstance = catalog(real: "l w ad as pd ps m ic_vds ic_vgs ic_vbs", flag: "off")
    private static func catalog(real: String = "", integer: String = "", flag: String = "", text: String = "", vector: String = "", aliases: String = "") -> [String: Parameter] {
        var values: [String: Parameter] = [:]
        for (names, kind) in [(real, MOSParameterKind.real), (integer, .integer), (flag, .flag), (text, .text), (vector, .vector)] {
            for name in names.split(separator: " ") { values[String(name)] = Parameter(kind: kind, canonicalName: String(name)) }
        }
        for alias in aliases.split(separator: " ") {
            let pair = alias.split(separator: ":")
            if pair.count == 2, let value = values[String(pair[0])] {
                values[String(pair[0])] = Parameter(kind: value.kind, canonicalName: String(pair[1]))
            }
        }
        return values
    }
}
