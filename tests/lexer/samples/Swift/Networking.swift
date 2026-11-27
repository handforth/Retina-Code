//
//  Networking.swift
//  Second Swift sample: result builders, macros, async, unterminated nested comment
//

import Foundation
import Combine
#if canImport(Observation)
import Observation
#endif

public enum HTTPMethod: String, CaseIterable, Sendable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
}

public struct Request<Response: Decodable & Sendable>: Sendable {
    public var path: String
    public var method: HTTPMethod = .get
    public var headers: [String: String] = ["Accept": "application/json"]
    public var body: Data? = nil
    public var timeout: TimeInterval = 30.0

    public init(_ path: String, method: HTTPMethod = .get) {
        self.path = path
        self.method = method
    }
}

public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: @unchecked Sendable, Transport {
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

public final class Client<T: Transport>: @unchecked Sendable {
    private let base: URL
    private let transport: T
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(base: URL, transport: T) {
        self.base = base
        self.transport = transport
    }

    public func send<R>(_ req: Request<R>) async throws -> R {
        var url = base.appendingPathComponent(req.path)
        if req.method == .get, let q = req.body.flatMap({ String(data: $0, encoding: .utf8) }) {
            url = URL(string: "\(url.absoluteString)?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        }
        var r = URLRequest(url: url, timeoutInterval: req.timeout)
        r.httpMethod = req.method.rawValue
        req.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await transport.send(r)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetworkError.status((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
        }
        return try decoder.decode(R.self, from: data)
    }
}

public enum NetworkError: Error, CustomStringConvertible {
    case status(Int, String)
    case decoding(underlying: any Error)
    public var description: String {
        switch self {
        case let .status(code, body) where code >= 500:
            return "server error \(code): \(body.prefix(80))"
        case .status(let code, _):
            return "client error \(code)"
        case .decoding(let e):
            return #"decoding failed: "\#(e)""#
        }
    }
}

@resultBuilder
enum StringBuilder {
    static func buildBlock(_ parts: String...) -> String { parts.joined(separator: "\n") }
    static func buildOptional(_ part: String?) -> String { part ?? "" }
    static func buildEither(first: String) -> String { first }
    static func buildEither(second: String) -> String { second }
    static func buildArray(_ parts: [String]) -> String { parts.joined() }
}

@StringBuilder
func report(verbose: Bool, items: [Int]) -> String {
    "Report"
    "-------"
    if verbose {
        "Verbose mode with \(items.count) items"
    } else {
        "Quiet"
    }
    for i in items {
        "item #\(i) = \(i * i) (\(Double(i) / 2.0))"
    }
}

let jsonTemplate = """
    {
      "name": "\(name)",
      "escaped": "a \\"quote\\" here",
      "raw": \#("not raw here, the hash is literal")
    }
    """

let rawJson = #"""
    {"pattern": "\d+\.\d+", "interp": "\#(value)"}
    """#

let tripleHash = ###"""
    ""# and "## and """# are all fine here, \###(x) interpolates
    """###

struct Matrix<let Rows: Int, let Cols: Int> {}  // value generics
let tuple: (a: Int, b: String) = (a: 1, b: "two")
let closure: (Int) -> (Int) -> Int = { a in { b in a + b } }
let trailing = [3, 1, 2].sorted { $0 > $1 }
let multipleTrailing = UIView.animate(withDuration: 0.3) {
    view.alpha = 0
} completion: { _ in
    view.removeFromSuperview()
}

func variadic<each T>(_ values: repeat each T) {}
let some: some Collection<Int> = [1, 2, 3]
let any: any Error = NetworkError.status(404, "")
let sendable: @Sendable () -> Void = {}
let escaping: (@escaping () -> Void) -> Void = { f in f() }

let numbers = [0b1111_0000, 0o755, 0xDEAD_BEEF, 1_000.000_1, 6.022e23, 1e-10, 0x1p-2]
let negativeHex = -0x7F
let chars: [Character] = ["\u{1F468}\u{200D}\u{1F469}", "é", "\n", "\""]

@Observable
final class Settings {
    var theme = "dark"
    @ObservationIgnored var cache: [String: Any] = [:]
}

@freestanding(expression)
macro stringify<T>(_ value: T) -> (T, String) = #externalMacro(module: "Macros", type: "StringifyMacro")

/* This comment is opened and contains a nested opener that is never balanced:
   /* nested level two
   let notCode = "string"
   */ back to level one — still a comment
   func alsoNotCode() {}
   "quotes" 'single' `backticks`
end of file reached while still inside the outer comment
