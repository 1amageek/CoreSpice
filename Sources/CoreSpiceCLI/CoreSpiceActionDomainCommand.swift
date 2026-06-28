import Foundation
import CoreSpice

struct CoreSpiceActionDomainCommand: Sendable {
    let jsonOutput: Bool

    init(arguments: [String]) throws {
        var jsonOutput = false
        for argument in arguments {
            switch argument {
            case "--json":
                jsonOutput = true
            default:
                throw CLIError.invalidArguments("unknown action-domain argument: \(argument)")
            }
        }
        self.jsonOutput = jsonOutput
    }

    func run() throws {
        let snapshot = CoreSpiceActionDomainExporter().snapshot()
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("action_domain=\(snapshot.domainID)")
            print("operations=\(snapshot.operations.count)")
        }
    }
}
