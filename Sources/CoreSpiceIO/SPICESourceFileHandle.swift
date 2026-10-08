import Foundation

/// A read's exclusively owned handle; all reads are bounded and close is checked.
protocol SPICESourceFileHandle: AnyObject {
    func seekToEnd() throws -> UInt64
    func seek(toOffset: UInt64) throws
    func read(upToCount: Int) throws -> Data?
    func close() throws
}
