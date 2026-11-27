// Swift lexer stress: interpolation, raw strings, nested comments, generics
import Foundation
import SwiftUI
@testable import MyModule

/* Swift block comments nest: /* inner /* deeper */ */ still outer */
let afterNested = "visible"

/// Doc comment with `code` and - Parameter x: description
/// - Returns: something
/**
 Block doc comment with *markdown* and ``Symbol`` references.
 */
func documented(_ x: Int) -> Int { x }

let name = "World"
let simple = "Hello, \(name)!"
let nestedInterp = "\(a + "\(b)")"
let deepNested = "outer \( "middle \( "inner \(name)" ) middle" ) outer"
let exprInterp = "sum: \(1 + 2 * 3) and call: \(name.uppercased()) and \(String(format: "%.2f", 1.5))"
let escapes = "tab\t nl\n cr\r nul\0 bs\\ dq\" sq\' uni\u{1F600} \u{41}"
let trailing = "ends with backslash \\"
let unterminated = "never closed
let afterUnterminated = 1

let raw = #"Raw string with "quotes" and \n not escaped and \#(name) interpolated"#
let raw2 = ##"Double-hash raw with "# inside and \##(name) and \#(notInterp)"##
let rawBackslash = #"C:\Users\path\file"#
let rawWithEscape = #"tab:\#t newline:\#n"#

let multi = """
    Multi-line string with "quotes" and \(name)
    and a line continuation \
    joined here
    and ""two quotes"" and \""" escaped triple
    """

let multiRaw = #"""
    Raw multi-line: \n is literal, \#(name) interpolates
    """ is fine here because of the hash
    """#

let multiNestedInterp = """
    \(items.map { "item: \($0)" }.joined(separator: ", "))
    \("""
        inner multi-line \(name)
        """)
    """

let regexLiteral = /[a-z]+\d*/
let extRegex = #/
    (?<word> \w+ )   # extended regex comment
    \s*
/#
let division = total / count / 2
let charLike: Character = "a"

// Numbers
let dec = 1_000_000
let hex = 0xFF_FF
let bin = 0b1010_1010
let oct = 0o17
let flt = 1.5e-3
let hexFlt = 0x1.8p1
let neg = -0.5
let big: UInt64 = 0xFFFF_FFFF_FFFF_FFFF

// Generics, protocols, attributes
@propertyWrapper
struct Clamped<Value: Comparable> {
    var wrappedValue: Value { didSet { wrappedValue = min(max(wrappedValue, range.lowerBound), range.upperBound) } }
    let range: ClosedRange<Value>
    init(wrappedValue: Value, _ range: ClosedRange<Value>) {
        self.range = range
        self.wrappedValue = wrappedValue
    }
}

protocol Container<Element> {
    associatedtype Element
    associatedtype Iterator: IteratorProtocol where Iterator.Element == Element
    mutating func append(_ item: Element)
    subscript(i: Int) -> Element { get }
}

struct Stack<Element>: Container where Element: Equatable {
    typealias Iterator = IndexingIterator<[Element]>
    private var items: [Element] = []
    mutating func append(_ item: Element) { items.append(item) }
    subscript(i: Int) -> Element { items[i] }
}

extension Array where Element: Numeric {
    func total() -> Element { reduce(0, +) }
}

func compare<T: Comparable, U>(_ a: T, _ b: T, map: (T) throws -> U) rethrows -> [U] where U: Hashable {
    return try [a, b].sorted(by: <).map(map)
}

let cmp = a < b && c > d
let genericType: Dictionary<String, Array<Set<Int>>> = [:]
let opt: Int? = nil
let forced = opt!
let chained = obj?.prop?.method()?[0]
let coalesce = opt ?? 0
let ranges = (0..<10, 0...10, ...5, 5...)

@MainActor
final class ViewModel: ObservableObject {
    @Published var count = 0
    @Clamped(0...100) var volume = 50
    @available(iOS 15, macOS 12, *)
    func load() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://example.com/api?q=\(count)")!)
        return try JSONDecoder().decode([String].self, from: data)
    }
}

struct ContentView: View {
    @StateObject private var vm = ViewModel()
    @Environment(\.colorScheme) var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Count: \(vm.count)")
                .font(.headline)
            Button("Tap \"me\"") { vm.count += 1 }
            ForEach(0..<3) { i in
                Text(verbatim: "row \(i)")
            }
        }
        .padding()
    }
}

enum Token: Equatable {
    case number(Double)
    case ident(String)
    case op(Character)
    indirect case group([Token])
}

actor Counter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
}

#if os(macOS) && !targetEnvironment(simulator)
let platform = "mac"
#elseif os(iOS)
let platform = "ios"
#else
let platform = "other"
#endif

#warning("this is a compile-time warning")
let file = #file, line = #line, fn = #function
let selector = #selector(ViewModel.load)
let keyPath = \ViewModel.count
let macroUse = #stringify(1 + 2)

infix operator <=> : ComparisonPrecedence
func <=> <T: Comparable>(lhs: T, rhs: T) -> Int { lhs < rhs ? -1 : (lhs > rhs ? 1 : 0) }
prefix operator √
prefix func √(x: Double) -> Double { x.squareRoot() }
let `class` = "backtick identifier"
let 变量 = "unicode identifier"
let emoji😀 = 1

/* nested /* comment */ that closes */ let finalLine = "done"
