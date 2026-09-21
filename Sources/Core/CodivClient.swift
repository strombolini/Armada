import Foundation

/// Thin async client for Codiv's `POST /v1/systemone` (Jev-compatible System One API).
final class CodivClient {
    struct Choice { let instructions: String; let criteria: [(String, String)] }

    struct ChoiceAnswer {
        let choice: String
        let probabilities: [String: Double]
        let confidence: Double
    }

    struct Response {
        let model: String
        let answers: [String: ChoiceAnswer]
        let inputTokens: Int
        let latencyMs: Int
    }

    enum ClientError: Error, LocalizedError {
        case noKey, offline(String), http(Int, String), badResponse, quota, auth

        var errorDescription: String? {
            switch self {
            case .noKey: return "No Codiv API key set. Open Armada › Settings."
            case .offline(let m): return "Can't reach Codiv: \(m)"
            case .http(let c, let m): return "Codiv HTTP \(c): \(m)"
            case .badResponse: return "Unexpected response from Codiv"
            case .quota: return "Codiv free quota exhausted"
            case .auth: return "Codiv rejected the API key"
            }
        }
    }

    static let shared = CodivClient()

    private let session: URLSession
    /// Running counters for the status bar / CLI.
    private(set) var requestCount = 0
    private(set) var tokenCount = 0

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "Armada/1.0 (macOS)"]
        session = URLSession(configuration: cfg)
    }

    private var endpoint: URL { URL(string: Settings.shared.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/systemone")! }

    /// Ask one or more `choice` questions about a JSON `state`.
    func choices(state: [String: Any], questions: [String: Choice]) async throws -> Response {
        let key = Settings.shared.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.noKey }
        var qs: [String: Any] = [:]
        for (id, q) in questions {
            // Preserve option order: JSONSerialization of a dictionary is unordered, so build the criteria object by hand.
            qs[id] = ["type": "choice", "instructions": q.instructions, "criteria": OrderedObject(q.criteria)]
        }
        let body: [String: Any] = ["model": Settings.shared.model, "state": state, "questions": qs]
        let data = try JSONEncoderLite.encode(body)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        var attempt = 0
        while true {
            attempt += 1
            let started = Date()
            let (respData, resp): (Data, URLResponse)
            do {
                (respData, resp) = try await session.data(for: req)
            } catch {
                let code = (error as? URLError)?.code
                // A cancelled request (the user kept typing) is not a connectivity problem — never mark Codiv offline for it.
                if code == .cancelled || error is CancellationError { throw CancellationError() }
                if attempt < 3, code == .networkConnectionLost { continue }
                let connectivity: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                                        .networkConnectionLost, .timedOut, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed]
                if let code, connectivity.contains(code) { Reachability.shared.noteFailure() }
                throw ClientError.offline(error.localizedDescription)
            }
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 200 {
                Reachability.shared.noteSuccess()
                guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                      let answers = json["answers"] as? [String: Any] else { throw ClientError.badResponse }
                var out: [String: ChoiceAnswer] = [:]
                for (id, a) in answers {
                    guard let a = a as? [String: Any] else { continue }
                    let probs = (a["probabilities"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
                    out[id] = ChoiceAnswer(choice: a["choice"] as? String ?? "", probabilities: probs, confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? 0)
                }
                let usage = json["usage"] as? [String: Any]
                let toks = (usage?["input_tokens"] as? NSNumber)?.intValue ?? 0
                requestCount += 1; tokenCount += toks
                return Response(model: json["model"] as? String ?? "", answers: out, inputTokens: toks,
                                latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            }
            let text = String(data: respData, encoding: .utf8) ?? ""
            if code == 429, text.contains("quota_exceeded") { throw ClientError.quota }
            if code == 401 || code == 403 { throw ClientError.auth }
            if (code == 429 || code == 529 || code >= 500), attempt < 4 {
                let retryAfter = Double(http?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 0.6 * Double(attempt)
                try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 4) * 1_000_000_000))
                continue
            }
            throw ClientError.http(code, String(text.prefix(300)))
        }
    }

    /// Cheap connectivity probe: `GET /v1/models` with a short timeout.
    func ping(timeout: TimeInterval = 2.5) async -> Bool {
        let key = Settings.shared.apiKey
        guard var comps = URLComponents(string: Settings.shared.baseURL) else { return false }
        comps.path = "/v1/models"
        guard let url = comps.url else { return false }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return code > 0 && code < 500
        } catch { return false }
    }
}

/// An ordered JSON object (JSONSerialization does not keep dictionary order and OpenJev shows options in order).
struct OrderedObject { let pairs: [(String, String)]; init(_ p: [(String, String)]) { pairs = p } }

/// Tiny JSON encoder that understands `OrderedObject` and plain Foundation values.
enum JSONEncoderLite {
    static func encode(_ value: Any) throws -> Data {
        var s = ""
        try write(value, into: &s)
        return Data(s.utf8)
    }

    private static func write(_ v: Any, into s: inout String) throws {
        switch v {
        case let o as OrderedObject:
            s += "{"
            for (i, (k, val)) in o.pairs.enumerated() {
                if i > 0 { s += "," }
                s += quote(k) + ":" + quote(val)
            }
            s += "}"
        case let d as [String: Any]:
            s += "{"
            var first = true
            for (k, val) in d.sorted(by: { $0.key < $1.key }) {
                if !first { s += "," }; first = false
                s += quote(k) + ":"
                try write(val, into: &s)
            }
            s += "}"
        case let a as [Any]:
            s += "["
            for (i, val) in a.enumerated() { if i > 0 { s += "," }; try write(val, into: &s) }
            s += "]"
        case let str as String: s += quote(str)
        case let b as Bool: s += b ? "true" : "false"
        case let n as NSNumber: s += n.stringValue
        case let i as Int: s += String(i)
        case let d as Double: s += String(d)
        case is NSNull: s += "null"
        default: throw CodivClient.ClientError.badResponse
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }
}
