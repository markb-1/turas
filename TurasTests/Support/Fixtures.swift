import Foundation
import XCTest

/// Loads JSON files from TurasTests/Fixtures (copied flat into the test bundle).
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "json"),
            "Fixture \(name).json is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }
}

private final class BundleToken {}
