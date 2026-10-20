import Foundation

/// Turns a transcript into an action, using one Jev request (all questions run in parallel).
struct CommandRouter {
    enum Outcome {
        case openApp(InstalledApp)
        case openSite(URL)
        case unsure(best: InstalledApp?)
        case needAddress
        case notACommand
    }

    static let confidenceThreshold = 0.6

    let client: TypeSafeClient

    @MainActor
    func route(_ transcript: String) async throws -> Outcome {
        let catalog = AppCatalog.shared
        let apps = catalog.candidates(for: transcript)
        let sites = URLExtractor.candidates(in: transcript)

        var questions: [String: TypeSafeClient.Question] = [
            "intent": .choice("What does the user want the computer to do?", options: [
                "open_app": "launch or switch to an application installed on the Mac",
                "open_website": "open a website or web address in the browser, including domains with any ending such as .com, .sh, .ai, .io",
                "none": "anything else, or nothing actionable",
            ]),
        ]
        if !apps.isEmpty {
            var options: [String: String] = [:]
            for app in apps { options[app.name] = "the \(app.name) app" }
            questions["app"] = .choice("Which installed Mac application does the user want to open?", options: options)
        }
        if sites.count > 1 {
            var options: [String: String] = [:]
            for site in sites.prefix(255) { options[site] = "the web address \(site)" }
            questions["site"] = .choice("Which web address did the user say? Speech-to-text may have split one name into several words.", options: options)
        }

        var state = ["spoken_command": transcript, "normalized": URLExtractor.normalize(transcript)]
        if !sites.isEmpty { state["web_addresses_detected"] = sites.joined(separator: ", ") }

        let response = try await client.systemOne(state: state, questions: questions)

        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" {
            print("intent:", response.choice("intent").map { "\($0.choice) \($0.probabilities)" } ?? "-")
        }

        switch response.choice("intent")?.choice {
        case "open_website":
            let pick = sites.count == 1 ? sites.first : response.choice("site")?.choice
            guard let pick, let url = URLExtractor.url(for: pick) else { return .needAddress }
            return .openSite(url)

        case "open_app":
            guard let answer = response.choice("app") else { return .notACommand }
            let app = catalog.app(named: answer.choice)
            if let app, answer.confidence >= Self.confidenceThreshold { return .openApp(app) }
            return .unsure(best: app)

        default:
            return .notACommand
        }
    }
}
