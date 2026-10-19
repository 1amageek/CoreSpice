/// Immutable payload copies retain admission even when extracted from a result.
package struct ExactRowBuffer<Element: Sendable & Equatable>: RandomAccessCollection, Sendable, Equatable, ExpressibleByArrayLiteral {
    private let values: [Element]
    private let lease: (any Sendable)?
    package init(_ values: [Element], lease: (any Sendable)? = nil) { self.values = values; self.lease = lease }
    package init(arrayLiteral elements: Element...) { self.init(elements) }
    package var startIndex: Int { values.startIndex }
    package var endIndex: Int { values.endIndex }
    package func index(after index: Int) -> Int { values.index(after: index) }
    package func index(before index: Int) -> Int { values.index(before: index) }
    package subscript(index: Int) -> Element { values[index] }
    package static func == (lhs: Self, rhs: Self) -> Bool { lhs.values == rhs.values }
}
