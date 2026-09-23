import Foundation

/// A typed client for TypeSafe's System One API. Jev is the model behind it.
/// You send a state and named questions. Each answer comes back as a calibrated probability,
/// constrained to the options you gave, so the code never parses generated text.
enum Jev {
    /// TYPESAFE_ENDPOINT overrides the base URL, as in TypeSafe's own cookbooks (used for local testing).
    static var endpoint: URL {
        let base = ProcessInfo.processInfo.environment["TYPESAFE_ENDPOINT"] ?? "https://api.typesafe.ai"
        return URL(string: base)!.appendingPathComponent("v1/systemone")
    }

    /// One question. Each case is one TypeSafe primitive.
    enum Question {
        /// Yes or no. The answer is the probability of yes.
        case noul(String, yes: String? = nil, no: String? = nil)
        /// Pick one option. Keys come back in the answer; meanings are what the model reads. A nil meaning sends null.
        case choice(String, options: [(key: String, meaning: String?)])
        /// Place the state on ordered levels. The answer is a position from 0 to levels.count - 1.
        case score(String, levels: [String])

        var json: [String: Any] {
            switch self {
            case let .noul(instructions, yes, no):
                var question: [String: Any] = ["type": "noul", "instructions": instructions]
                if yes != nil || no != nil { question["criteria"] = ["true": orNull(yes), "false": orNull(no)] }
                return question
            case let .choice(instructions, options):
                var criteria: [String: Any] = [:]
                for option in options { criteria[option.key] = orNull(option.meaning) }
                return ["type": "choice", "instructions": instructions, "criteria": criteria]
            case let .score(instructions, levels):
                return ["type": "score", "instructions": instructions, "criteria": levels]
            }
        }

        private func orNull(_ text: String?) -> Any {
            if let text { return text }
            return NSNull()
        }
    }

    struct Answer: Decodable {
        let type: String
        let noul: Double?
        let choice: String?
        let score: Double?
        let probabilities: [String: Double]?
        let confidence: Double?
    }

    struct Usage: Decodable {
        let input_tokens: Int
        let output_tokens: Int?
    }

    struct Response: Decodable {
        let model: String
        let answers: [String: Answer]
        let usage: Usage?
    }

    struct Failure: LocalizedError {
        let status: Int
        let message: String

        var errorDescription: String? {
            switch status {
            case 401, 403: return "TypeSafe rejected the API key"
            case 429: return "TypeSafe rate limit reached"
            case 529: return "TypeSafe is overloaded; try again shortly"
            default: return message.isEmpty ? "TypeSafe error \(status)" : "TypeSafe error \(status): \(message)"
            }
        }

        /// Errors arrive as {"detail": {"error_type", "message"}}, or as a list of field errors for a 422.
        static func message(from data: Data) -> String {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let detail = object["detail"] ?? object["error"] ?? object
                if let text = detail as? String { return text }
                if let fields = detail as? [String: Any], let text = fields["message"] as? String ?? fields["msg"] as? String { return text }
                if let list = detail as? [[String: Any]], let first = list.first {
                    let location = (first["loc"] as? [Any])?.map { "\($0)" }.joined(separator: ".") ?? ""
                    return [location, first["msg"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: ": ")
                }
            }
            return String(decoding: data.prefix(200), as: UTF8.self)
        }
    }

    struct Client {
        var apiKey: String
        var model = "jev-latest"
        var timeout: TimeInterval = 12

        func ask(state: Any, questions: [String: Question]) async throws -> Response {
            var request = URLRequest(url: Jev.endpoint, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["model": model, "state": state, "questions": questions.mapValues(\.json)]
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw Failure(status: status, message: Failure.message(from: data)) }
            return try JSONDecoder().decode(Response.self, from: data)
        }
    }
}

/// A Swift enum Jev can pick from. The raw value is the option key; `meaning` is what the model reads.
protocol JevOption: CaseIterable, RawRepresentable where RawValue == String {
    var meaning: String { get }
}

extension Jev.Question {
    /// A Choice whose options are the cases of a Swift enum, so the answer decodes back into that enum.
    static func pick<T: JevOption>(_ instructions: String, from _: T.Type) -> Jev.Question {
        .choice(instructions, options: T.allCases.map { (key: $0.rawValue, meaning: Optional($0.meaning)) })
    }
}

extension Jev.Answer {
    /// The picked option as a Swift value, if Jev gave it at least `minimum` probability.
    func picked<T: JevOption>(_: T.Type, minimum: Double = 0.5) -> T? {
        guard let choice, let value = T(rawValue: choice) else { return nil }
        return (probabilities?[choice] ?? 1) >= minimum ? value : nil
    }
}
