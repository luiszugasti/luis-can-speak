import Foundation

/// Types text into a Claude Code session running in a cmux terminal.
enum Terminal {
    static let cmux = "/Applications/cmux.app/Contents/Resources/bin/cmux"

    /// Pastes the text into the surface and presses submit.
    /// Returns nil on success, or the error text cmux printed.
    static func submit(_ text: String, surface: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmux)
        process.arguments = ["paste", "--surface", surface, "--submit", "--", text]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return "Couldn't start cmux: \(error.localizedDescription)"
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 { return nil }
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return err.isEmpty ? "cmux exited with status \(process.terminationStatus)" : err
    }
}
