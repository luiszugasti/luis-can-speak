import Foundation

/// Something Claude Code is waiting on you for. The hook call stays open until
/// you answer, so Claude Code waits too.
final class PendingDecision {
    enum Kind {
        /// A tool permission prompt (Bash, Edit, WebFetch, MCP tools, ...).
        case permission(tool: String, input: [String: Any], suggestions: [[String: Any]])
        /// Claude finished planning and wants to leave plan mode.
        case plan(input: [String: Any])
        /// Claude asked multiple-choice questions (the AskUserQuestion tool).
        case questions(input: [String: Any], questions: [[String: Any]], index: Int, answers: [String: String])
        /// An MCP server asked a yes-or-no confirmation.
        case elicitation(server: String)
    }

    let request: HookRequest
    var kind: Kind

    init(request: HookRequest, kind: Kind) {
        self.request = request
        self.kind = kind
    }

    /// What to read aloud for the current step.
    var spokenPrompt: String {
        switch kind {
        case let .permission(tool, input, suggestions):
            let always = suggestions.isEmpty ? "" : ", or always"
            return "Claude wants to \(Self.describe(tool: tool, input: input)). Say yes, no\(always)."
        case let .plan(input):
            let plan = input["plan"] as? String ?? ""
            return "Claude has a plan.\n\(plan)\nDo you approve it? Say yes, or say no and what to change."
        case let .questions(_, questions, index, _):
            return Self.describe(question: questions[index], number: index + 1, of: questions.count)
        case let .elicitation(server):
            let message = request.body["message"] as? String ?? ""
            return "The \(server) tool is asking: \(message). Say yes to accept, or no to decline."
        }
    }

    /// A short label for the menu.
    var menuTitle: String {
        switch kind {
        case let .permission(tool, _, _): return "Waiting on you: allow \(tool)?"
        case .plan: return "Waiting on you: approve the plan?"
        case let .questions(_, questions, index, _): return "Waiting on you: question \(index + 1) of \(questions.count)"
        case .elicitation: return "Waiting on you: tool confirmation"
        }
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            return "run this command: \(input["command"] as? String ?? "")"
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? "a file"
            return "\(tool == "Write" ? "write" : "edit") \((path as NSString).lastPathComponent)"
        case "Read":
            return "read \(((input["file_path"] as? String ?? "a file") as NSString).lastPathComponent)"
        case "WebFetch":
            return "fetch \(input["url"] as? String ?? "a web page")"
        case "WebSearch":
            return "search the web for \(input["query"] as? String ?? "something")"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                return "use the \(parts.dropFirst().joined(separator: " ")) tool"
            }
            return "use the \(tool) tool"
        }
    }

    static func describe(question q: [String: Any], number: Int, of total: Int) -> String {
        var text = total > 1 ? "Question \(number) of \(total). " : ""
        text += (q["question"] as? String ?? "Claude has a question.") + "\n"
        let options = q["options"] as? [[String: Any]] ?? []
        for (i, option) in options.enumerated() {
            let label = option["label"] as? String ?? ""
            let detail = option["description"] as? String ?? ""
            text += "Option \(i + 1): \(label)."
            if !detail.isEmpty { text += " \(detail)." }
            text += "\n"
        }
        let multi = q["multiSelect"] as? Bool ?? false
        text += multi ? "Say one or more numbers, or your own answer." : "Say a number, or your own answer."
        return text
    }
}

/// What you said in reply to a yes-or-no prompt.
enum YesNo: Equatable {
    case yes
    case always
    case no(String)
    case cancel
    case terminal
    case unclear
}

enum AnswerParser {
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func yesNo(_ said: String) -> YesNo {
        let s = normalize(said)
        guard !s.isEmpty else { return .unclear }
        let first = s.split(separator: " ").first.map(String.init) ?? ""

        if s.contains("terminal") || s.contains("keyboard") || s.contains("let me type") { return .terminal }
        if s.hasPrefix("cancel") || s.contains("stop everything") || s.hasPrefix("interrupt") { return .cancel }
        if first == "always" || s.contains("always allow") || s.contains("don't ask again") || s.contains("dont ask again") {
            return .always
        }
        let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "allow", "approve", "approved", "go", "do", "fine", "proceed"]
        let noWords: Set<String> = ["no", "nope", "nah", "deny", "don't", "dont", "stop", "wait", "reject"]
        if noWords.contains(first) { return .no(said.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if yesWords.contains(first) || s.hasPrefix("go ahead") { return .yes }
        return .unclear
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "first": 1, "won": 1,
        "two": 2, "second": 2, "to": 2, "too": 2,
        "three": 3, "third": 3,
        "four": 4, "fourth": 4, "for": 4,
        "five": 5, "fifth": 5,
        "six": 6, "sixth": 6,
        "seven": 7, "seventh": 7,
        "eight": 8, "eighth": 8,
    ]

    /// Picks option labels from what you said. Falls back to your own words
    /// when they don't match an option, so you can give a free answer.
    static func optionAnswer(_ said: String, options: [String], multiSelect: Bool) -> String {
        let s = normalize(said)
        var picked: [String] = []

        // Exact label matches win ("react", "use postgres").
        for label in options where !label.isEmpty {
            let l = normalize(label)
            guard !l.isEmpty else { continue }
            // Whole words only, so a label like "A" doesn't match "and".
            let pattern = #"(^|\s)"# + NSRegularExpression.escapedPattern(for: l) + #"($|\s)"#
            if s.range(of: pattern, options: .regularExpression) != nil { picked.append(label) }
        }

        // Then numbers ("option two", "1 and 3"). Only look at short replies
        // for loose words like "to" and "for", so a free answer isn't misread.
        if picked.isEmpty {
            let words = s.split(separator: " ").map(String.init)
            let short = words.count <= 6
            for word in words {
                var n: Int? = Int(word)
                if n == nil, let w = numberWords[word] {
                    let loose = ["to", "too", "for", "won"].contains(word)
                    if !loose || short { n = w }
                }
                if let n, n >= 1, n <= options.count {
                    let label = options[n - 1]
                    if !picked.contains(label) { picked.append(label) }
                }
            }
        }

        if picked.isEmpty { return said.trimmingCharacters(in: .whitespacesAndNewlines) }
        return multiSelect ? picked.joined(separator: ", ") : picked[0]
    }
}
