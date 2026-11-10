import AppKit

/// TypeSafe's Jev: ~0.25 s multiple-choice answers. Sorts each request so simple ones skip the Gemini loop.
/// Docs: https://docs.typesafe.ai/api/system-one
@MainActor
enum Jev {
    static let model = "jev-1.14.0"

    enum Route: Equatable { case openApp(InstalledApp), math, web, memory, agent }

    /// Only trusts Jev when it's sure; anything unclear goes to the full agent.
    static func route(_ transcript: String, key: String) async -> Route {
        let apps = AppCatalog.shared.candidates(for: transcript)
        var appOptions = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ("a\($0.offset)", $0.element.name) })
        appOptions["none"] = "None of these apps"
        let questions: [String: Any] = [
            "route": ["type": "choice", "instructions": "What kind of request is the transcript?", "criteria": [
                "open_app": "Only open, launch or switch to one app. Nothing else to do in it.",
                "math": "A calculation to answer, without naming an app to do it in.",
                "web": "A general question answered from the web: facts, news, weather, prices, definitions, how-tos.",
                "memory": "About what the user did, saw or worked on before (their own screen history).",
                "agent": "Anything else: doing something in an app, several steps, typing, sending, clicking, settings.",
            ]],
            "app": ["type": "choice", "instructions": "Which app does the transcript name?", "criteria": appOptions],
        ]
        let t0 = Date()
        guard let a = await ask(state: ["transcript": transcript], questions: questions, key: key),
              let r = a["route"], r.confidence >= 0.8 else { return .agent }
        DesktopAgent.log(String(format: "jev %.2fs: %@ %.2f · app %@", Date().timeIntervalSince(t0), r.choice, r.confidence, a["app"]?.choice ?? "-"))
        switch r.choice {
        case "open_app":
            guard let c = a["app"], c.confidence >= 0.8, c.choice != "none", let i = Int(c.choice.dropFirst()), i < apps.count else { return .agent }
            return .openApp(apps[i])
        case "math": return .math
        case "web": return .web
        case "memory": return .memory
        default: return .agent
        }
    }

    private struct Choice { let choice: String; let confidence: Double }

    private static func ask(state: [String: String], questions: [String: Any], key: String) async -> [String: Choice]? {
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "state": state, "questions": questions])
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let answers = o["answers"] as? [String: [String: Any]]
        else { DesktopAgent.log("jev: no answer"); return nil }
        return answers.compactMapValues { a in
            guard let c = a["choice"] as? String, let conf = a["confidence"] as? Double else { return nil }
            return Choice(choice: c, confidence: conf)
        }
    }
}

/// "What's 123 times 45" → 5535, in code. Plain numbers and + − × ÷ only; anything else returns nil.
enum Arithmetic {
    static func answer(_ transcript: String) -> String? {
        var s = " " + transcript.lowercased() + " "
        for (w, op) in [("multiplied by", "*"), ("times", "*"), (" x ", " * "), ("×", "*"), ("divided by", "/"), ("÷", "/"), (" over ", " / "),
                        ("plus", "+"), ("minus", "-"), ("−", "-")] { s = s.replacingOccurrences(of: w, with: op) }
        s = s.replacingOccurrences(of: #"(\d),(\d{3})"#, with: "$1$2", options: .regularExpression)
        // The expression is the run of numbers and operators; words around it ("what's", "?") are dropped.
        guard let m = s.range(of: #"-?\d+(\.\d+)?(\s*[-+*/]\s*-?\d+(\.\d+)?)+"#, options: .regularExpression) else { return nil }
        let expr = String(s[m])
        guard let v = eval(expr), v.isFinite else { return nil }
        let pretty = expr.replacingOccurrences(of: "*", with: "×").replacingOccurrences(of: "/", with: "÷")
            .replacingOccurrences(of: #"\s*([-+×÷])\s*"#, with: " $1 ", options: .regularExpression)
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 6
        return "\(pretty) = \(f.string(from: NSNumber(value: v)) ?? "\(v)")"
    }

    /// Left to right with × ÷ before + −.
    private static func eval(_ expr: String) -> Double? {
        var nums: [Double] = [], ops: [Character] = [], cur = "", expectNumber = true
        for c in expr where c != " " {
            if c.isNumber || c == "." || (c == "-" && expectNumber && cur.isEmpty) { cur.append(c); expectNumber = false; continue }
            guard let n = Double(cur) else { return nil }
            nums.append(n); cur = ""; ops.append(c); expectNumber = true
        }
        guard let last = Double(cur) else { return nil }
        nums.append(last)
        var n2: [Double] = [nums[0]], o2: [Character] = []
        for (i, op) in ops.enumerated() {
            let b = nums[i + 1]
            switch op {
            case "*": n2[n2.count - 1] *= b
            case "/": guard b != 0 else { return nil }; n2[n2.count - 1] /= b
            default: n2.append(b); o2.append(op)
            }
        }
        var v = n2[0]
        for (i, op) in o2.enumerated() { v = op == "+" ? v + n2[i + 1] : v - n2[i + 1] }
        return v
    }
}
