import Foundation

/// Turns a transcript into an action, using one Jev request (all questions run in parallel).
struct CommandRouter {
    enum Outcome {
        case openApps(WindowManager.Plan)
        case openSite(URL)
        case unsure(best: InstalledApp?)
        case needAddress
        case notACommand
    }

    static let confidenceThreshold = 0.6
    static let extraAppThreshold = 0.5

    let client: TypeSafeClient

    @MainActor
    func route(_ transcript: String) async throws -> Outcome {
        let catalog = AppCatalog.shared
        let apps = catalog.candidates(for: transcript, limit: 254)   // 255 minus "none"
        // Your vocabulary wins over raw regex hits ("mail.sh" when you said "openmail.sh").
        let known = Vocabulary.matches(in: transcript).filter { $0.contains(".") }
        var sites = known
        for s in URLExtractor.candidates(in: transcript) where !sites.contains(s) {
            if known.contains(where: { $0.hasSuffix(s) }) { continue }   // drop fragments of a known address
            sites.append(s)
        }

        var questions: [String: TypeSafeClient.Question] = [
            "intent": .choice("What does the user want the computer to do?", options: [
                "open_app": "launch or switch to one or more applications installed on the Mac, or open windows of them",
                "open_website": "open a website or web address in the browser, including domains with any ending such as .com, .sh, .ai, .io",
                "none": "anything else, or nothing actionable",
            ]),
            "windows": .choice("How many windows of the same app does the user ask for? Speech-to-text often writes 'two' as 'to' or 'too'.", options: [
                "1": "one window, or no number mentioned",
                "2": "two windows",
                "3": "three windows",
                "4": "four windows",
            ]),
            "layout": .choice("How does the user want the windows arranged on screen?", options: [
                "none": "no arrangement mentioned",
                "side_by_side": "side by side, next to each other, split screen, left and right",
                "stacked": "stacked, one above the other, top and bottom",
                "maximize": "full screen, maximized, as big as possible",
            ]),
        ]
        if !apps.isEmpty {
            var options: [String: String] = [:]
            for app in apps { options[app.name] = "the \(app.name) app" }
            var more = options
            more["none"] = "no other application is mentioned"
            questions["app1"] = .choice("Which installed Mac application does the user mention first?", options: options)
            questions["app2"] = .choice("Which second, different application does the user mention, if any?", options: more)
            questions["app3"] = .choice("Which third, different application does the user mention, if any?", options: more)
        }
        if sites.count > 1 {
            var options: [String: String] = [:]
            for site in sites.prefix(255) { options[site] = "the web address \(site)" }
            questions["site"] = .choice("Which web address did the user say? Speech-to-text may have split one name into several words.", options: options)
        }

        var state = ["spoken_command": transcript, "normalized": URLExtractor.normalize(transcript)]
        if !sites.isEmpty { state["web_addresses_detected"] = sites.joined(separator: ", ") }
        if !known.isEmpty { state["users_known_sites"] = known.joined(separator: ", ") }

        let response = try await client.systemOne(state: state, questions: questions)

        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" {
            for k in ["intent", "app1", "app2", "app3", "windows", "layout"] {
                if let a = response.choice(k) { print("  \(k): \(a.choice) (\(String(format: "%.2f", a.confidence)))") }
            }
        }

        switch response.choice("intent")?.choice {
        case "open_website":
            let pick = sites.count == 1 ? sites.first : response.choice("site")?.choice
            guard let pick, let url = URLExtractor.url(for: pick) else { return .needAddress }
            return .openSite(url)

        case "open_app":
            guard let first = response.choice("app1") else { return .notACommand }
            guard let app1 = catalog.app(named: first.choice), first.confidence >= Self.confidenceThreshold else {
                return .unsure(best: catalog.app(named: first.choice))
            }
            var picked = [app1]
            for key in ["app2", "app3"] {
                guard let a = response.choice(key), a.choice != "none", a.confidence >= Self.extraAppThreshold,
                      let app = catalog.app(named: a.choice), !picked.contains(app) else { continue }
                picked.append(app)
            }
            let windows = Int(response.choice("windows")?.choice ?? "1") ?? 1
            let layout = WindowManager.Layout(rawValue: response.choice("layout")?.choice ?? "none") ?? .none
            return .openApps(.init(apps: picked, windowsEach: windows, layout: layout))

        default:
            return .notACommand
        }
    }
}
