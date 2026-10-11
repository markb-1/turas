import XCTest
@testable import Turas

final class ConfigTests: XCTestCase {
    func testValidConfig() {
        let config = Config.serverConfig(from: [
            "TURAS_SERVER_URL": "https://turas.example.com/",
            "TURAS_SERVER_API_KEY": " secret ",
        ])
        XCTAssertEqual(config, ServerConfig(baseURL: "https://turas.example.com", apiKey: "secret"))
    }

    func testHostWithPort() {
        let config = Config.serverConfig(from: [
            "TURAS_SERVER_URL": "http://192.168.1.5:8080",
            "TURAS_SERVER_API_KEY": "k",
        ])
        XCTAssertEqual(config?.baseURL, "http://192.168.1.5:8080")
    }

    func testMissingOrUnsubstitutedValues() {
        XCTAssertNil(Config.serverConfig(from: nil))
        XCTAssertNil(Config.serverConfig(from: [:]))
        XCTAssertNil(Config.serverConfig(from: ["TURAS_SERVER_URL": "https://a.example"]))
        XCTAssertNil(Config.serverConfig(from: ["TURAS_SERVER_URL": "", "TURAS_SERVER_API_KEY": "k"]))
        XCTAssertNil(Config.serverConfig(from: ["TURAS_SERVER_URL": "$(TURAS_SERVER_URL)", "TURAS_SERVER_API_KEY": "k"]))
        XCTAssertNil(Config.serverConfig(from: ["TURAS_SERVER_URL": "https://a.example", "TURAS_SERVER_API_KEY": "$(TURAS_SERVER_API_KEY)"]))
        XCTAssertNil(Config.serverConfig(from: ["TURAS_SERVER_URL": "not a url", "TURAS_SERVER_API_KEY": "k"]))
    }

    func testStubRunsKeepStaticDataOutOfTheDiskCache() {
        // Canned /stops answers on disk would outlive the run by 7 days and
        // show in later live runs.
        XCTAssertNil(AppDependencies.staticDataCacheDirectory(environment: ["TURAS_UITEST_STUB": "1"]))
        XCTAssertNotNil(AppDependencies.staticDataCacheDirectory(environment: [:]))
        XCTAssertEqual(AppDependencies.staticDataCacheDirectory(environment: [:]), StaticDataStore.defaultCacheDirectory())
    }
}
