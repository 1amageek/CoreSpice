import Testing
@testable import CoreSpice

@Suite("CoreSpice Umbrella Tests")
struct CoreSpiceTests {

    @Test func umbrellaImportsAvailable() {
        let node = Node(id: 1)
        #expect(node.id == 1)
        #expect(Node.ground.id == 0)
    }

    @Test func analysisIDIsUnique() {
        let id1 = AnalysisID()
        let id2 = AnalysisID()
        #expect(id1 != id2)
    }
}
