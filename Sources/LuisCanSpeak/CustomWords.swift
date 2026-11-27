import Foundation

/// Words the speech engine should expect, so it spells them right.
/// They live in a plain text file you can edit, one word or phrase per line.
enum CustomWords {
    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Luis Can Speak/custom-words.txt")
    }

    /// Creates the file with a starter list the first time.
    static func ensureFile() {
        let url = fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? starter.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reads the list, plus your own name from macOS so it's spelled right too.
    static func load() -> [String] {
        ensureFile()
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var words = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        words += NSFullUserName().split(separator: " ").map(String.init)
        return Array(Set(words)).sorted()
    }

    private static let starter = """
    # Luis Can Speak custom words. One word or phrase per line.
    # Lines that start with # are ignored. Changes apply the next time you talk.
    # These help in English and in Spanish.

    # Claude and AI
    Claude
    Claude Code
    Anthropic
    Opus
    Sonnet
    Haiku
    Fable
    MCP
    subagent
    prompt
    hook
    hooks

    # Tools on this Mac
    cmux
    Ghostty
    Wispr Flow
    Obsidian
    Linear
    GitHub
    Homebrew
    Xcode
    macOS
    zsh
    jq
    curl
    pbcopy
    Personal Voice
    menu bar

    # Code words
    repo
    monorepo
    PR
    pull request
    commit
    rebase
    worktree
    branch
    merge
    lint
    typecheck
    localhost
    CLI
    API
    SDK
    JSON
    YAML
    README
    env

    # Languages and frameworks
    TypeScript
    JavaScript
    Node.js
    pnpm
    npm
    React
    Vite
    Fastify
    tRPC
    Drizzle
    Drizzle Kit
    PostgreSQL
    Postgres
    SQL
    Swift
    SwiftUI
    Playwright

    # Cloud
    AWS
    Terraform
    Cognito
    Bedrock
    Lambda
    S3
    IAM
    Netlify
    """
}
