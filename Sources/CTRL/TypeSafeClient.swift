import Foundation

/// Minimal typed client for TypeSafe's System One API (`POST /v1/systemone`).
/// Docs: https://docs.typesafe.ai/api/system-one
struct TypeSafeClient {
    static let model = "jev-1.14.0"   // pinned; confidence thresholds are tuned against it

    var apiKey: String
    var session: URLSession = .shared

    struct ChoiceAnswer: Decodable {
        let choice: String
        let confidence: Double
        let probabilities: [String: Double]
    }

    struct NoulAnswer: Decodable {
        let noul: Double
    }

    /// Edges as fractions of the image, from the top-left.
    struct BoxAnswer: Decodable {
        struct Edges: Decodable { let top, bottom, left, right: Double }
        let box: Edges
        let confidence: Double
    }

    enum Question: Encodable {
        case choice(String, options: [String: String])
        case noul(String)
        case box(String)

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .choice(let instructions, let options):
                try c.encode("choice", forKey: .type)
                try c.encode(instructions, forKey: .instructions)
                try c.encode(options, forKey: .criteria)
            case .noul(let instructions):
                try c.encode("noul", forKey: .type)
                try c.encode(instructions, forKey: .instructions)
            case .box(let instructions):
                try c.encode("box", forKey: .type)
                try c.encode(instructions, forKey: .instructions)
            }
        }
        enum Keys: String, CodingKey { case type, instructions, criteria }
    }

    /// An image sent with the request; put `ref` wherever the image belongs (state or instructions).
    struct Image {
        let ref: String
        let jpeg: Data
    }

    private struct Asset: Encodable {
        let type = "image"
        let format = "jpg"
        let data_base64: String
    }

    private struct Request: Encodable {
        let model: String
        let state: [String: String]
        let questions: [String: Question]
        let assets: [String: Asset]?
    }

    /// Raw answers keyed by question name; decode each with `answer(_:as:)`.
    struct Response: Decodable {
        let model: String
        let answers: [String: AnyAnswer]

        func choice(_ key: String) -> ChoiceAnswer? { answers[key]?.choice }
        func noul(_ key: String) -> Double? { answers[key]?.noul?.noul }
        func box(_ key: String) -> BoxAnswer? { answers[key]?.box }
    }

    struct AnyAnswer: Decodable {
        let choice: ChoiceAnswer?
        let noul: NoulAnswer?
        let box: BoxAnswer?
        init(from decoder: Decoder) throws {
            choice = try? ChoiceAnswer(from: decoder)
            noul = try? NoulAnswer(from: decoder)
            box = try? BoxAnswer(from: decoder)
        }
    }

    struct APIError: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "TypeSafe \(status): \(body.prefix(140))" }
    }

    func systemOne(state: [String: String], questions: [String: Question], images: [Image] = []) async throws -> Response {
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        req.httpMethod = "POST"
        req.timeoutInterval = images.isEmpty ? 8 : 15
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let usesImages = !images.isEmpty || questions.values.contains { if case .box = $0 { true } else { false } }
        if usesImages { req.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") }
        let assets = images.isEmpty ? nil : Dictionary(uniqueKeysWithValues: images.map { ($0.ref, Asset(data_base64: $0.jpeg.base64EncodedString())) })
        req.httpBody = try JSONEncoder().encode(Request(model: Self.model, state: state, questions: questions, assets: assets))

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw APIError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
