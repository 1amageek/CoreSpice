#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#else
#error("MOS expression math requires the target SDK libc math module")
#endif

/// Standard SDK libm operations; no numerical approximation or device kernel dependency.
package enum MOSMath {
    package static func power(_ a: Double, _ b: Double) -> Double { pow(a, b) }
    package static func sine(_ x: Double) -> Double { sin(x) }
    package static func cosine(_ x: Double) -> Double { cos(x) }
    package static func tangent(_ x: Double) -> Double { tan(x) }
    package static func arcSine(_ x: Double) -> Double { asin(x) }
    package static func arcCosine(_ x: Double) -> Double { acos(x) }
    package static func arcTangent(_ x: Double) -> Double { atan(x) }
    package static func arcTangent2(_ a: Double, _ b: Double) -> Double { atan2(a, b) }
    package static func hyperbolicSine(_ x: Double) -> Double { sinh(x) }
    package static func hyperbolicCosine(_ x: Double) -> Double { cosh(x) }
    package static func hyperbolicTangent(_ x: Double) -> Double { tanh(x) }
    package static func exponential(_ x: Double) -> Double { exp(x) }
    package static func logarithm(_ x: Double) -> Double { log(x) }
    package static func logarithm10(_ x: Double) -> Double { log10(x) }
    package static func squareRoot(_ x: Double) -> Double { sqrt(x) }
}
