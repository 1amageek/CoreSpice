import Testing
@testable import CoreSpiceCLI

@Suite
struct DetectorTests {

    @Test
    func detectsTransient() {
        let src = """
        inverter
        .tran 1e-9 1e-6
        .end
        """
        #expect(AnalysisDetector.detect(source: src) != nil)
    }

    @Test
    func detectsAC() {
        let src = """
        amp
        .ac dec 10 1 1e3
        .end
        """
        if case .ac(let sweep)? = AnalysisDetector.detect(source: src) {
            switch sweep {
            case .decade(let start, let stop, let ppd):
                #expect(start == 1)
                #expect(stop == 1000)
                #expect(ppd == 10)
            default:
                #expect(Bool(false))
            }
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func detectsOpAsFallback() {
        let src = """
        v1 1 0 1
        .op
        .end
        """
        if case .op? = AnalysisDetector.detect(source: src) {
            #expect(true)
        } else {
            #expect(Bool(false))
        }
    }
}
