import Foundation

/// Where the app finds the Turas server.
struct ServerConfig: Equatable, Sendable {
    /// Base URL without a trailing slash, e.g. "https://turas.example.com".
    let baseURL: String
    let apiKey: String
}

/// Reads configuration from Info.plist (populated from the .xcconfig files).
///
/// Values are set in Configuration/Debug.xcconfig and Release.xcconfig
/// (gitignored), referenced from Info.plist as $(VAR_NAME), and substituted
/// by Xcode at build time.
enum Config {
    /// The server settings for this build, or nil when they are missing.
    ///
    /// A Debug build stops here with an explanation so a developer notices
    /// straight away. A Release build never crashes: the app shows
    /// ServerNotConfiguredView instead.
    static let server: ServerConfig? = {
        let config = serverConfig(from: Bundle.main.infoDictionary)
        #if DEBUG
        if config == nil {
            fatalError("TURAS_SERVER_URL or TURAS_SERVER_API_KEY is missing from Info.plist. Create Configuration/Debug.xcconfig as described in the README, then regenerate the project with xcodegen.")
        }
        #endif
        return config
    }()

    /// Builds a ServerConfig from Info.plist values. Missing, empty or
    /// unsubstituted ("$(TURAS_SERVER_URL)") values, or a URL without a
    /// host, count as not configured.
    static func serverConfig(from info: [String: Any]?) -> ServerConfig? {
        guard let url = value(for: "TURAS_SERVER_URL", in: info),
              let apiKey = value(for: "TURAS_SERVER_API_KEY", in: info),
              let host = URL(string: url)?.host, !host.isEmpty else {
            return nil
        }
        var baseURL = url
        while baseURL.hasSuffix("/") {
            baseURL.removeLast()
        }
        return ServerConfig(baseURL: baseURL, apiKey: apiKey)
    }

    private static func value(for key: String, in info: [String: Any]?) -> String? {
        guard let raw = info?[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}
