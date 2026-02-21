import Foundation

enum LoomSecrets {
    // Read Gemini key from environment only (Xcode scheme or shell).
    static let apiKey: String = {
        let envValue = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
        return envValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static var hasAPIKey: Bool {
        !apiKey.isEmpty
    }

    // Backward compatibility for older call sites.
    static let geminiAPIKey: String = apiKey
}
