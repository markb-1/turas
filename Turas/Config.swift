import Foundation

/// Reads configuration values from Info.plist (populated by .xcconfig files).
///
/// Values are set in Configuration/Debug.xcconfig (gitignored), referenced
/// from Info.plist as $(VAR_NAME), and substituted by Xcode at build time.
enum Config {
    static var turasServerURL: String {
        guard let url = Bundle.main.infoDictionary?["TURAS_SERVER_URL"] as? String,
              !url.isEmpty else {
            fatalError("TURAS_SERVER_URL not found in Info.plist.")
        }
        return url
    }

    static var turasServerApiKey: String {
        guard let key = Bundle.main.infoDictionary?["TURAS_SERVER_API_KEY"] as? String,
              !key.isEmpty else {
            fatalError("TURAS_SERVER_API_KEY not found in Info.plist.")
        }
        return key
    }
}
