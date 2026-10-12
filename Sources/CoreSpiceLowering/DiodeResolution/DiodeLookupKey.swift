import CoreSpiceMOSContracts

struct DiodeLookupKey: Sendable, Hashable {
    let scope: MOSScopeID
    let symbol: MOSSymbolID
}
