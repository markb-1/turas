import SwiftUI
import UIKit
import XCTest
@testable import Turas

final class ThemeTests: XCTestCase {
    /// Every token resolves in both appearances to the spec's hex values.
    func testColourSetsHaveLightAndDarkValues() throws {
        let expected: [(name: String, light: UInt32, dark: UInt32)] = [
            ("Brand", 0x007A6C, 0x2BB3A0),
            ("Ink", 0x0F2A24, 0xE8F0ED),
            ("Surface", 0xF6F8F7, 0x0E1513),
            ("Card", 0xFFFFFF, 0x17211E),
            ("Muted", 0x6B7D78, 0x8FA39D),
            ("Late", 0xB86E00, 0xF0A93B),
            ("Cancelled", 0xB3261E, 0xF2867E),
        ]
        for token in expected {
            let colour = try XCTUnwrap(UIColor(named: token.name), "\(token.name) colour set is missing")
            let light = colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            let dark = colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            XCTAssertEqual(Self.hex(light), token.light, "\(token.name) light", file: #filePath, line: #line)
            XCTAssertEqual(Self.hex(dark), token.dark, "\(token.name) dark", file: #filePath, line: #line)
        }
    }

    func testLineColours() {
        XCTAssertEqual(Theme.lineColor(mode: .luas, route: "Green"), Theme.luasGreen)
        XCTAssertEqual(Theme.lineColor(mode: .luas, route: "Red"), Theme.luasRed)
        XCTAssertEqual(Theme.lineColor(mode: .luas, route: "Purple"), Theme.luasGreen, "an unknown Luas line still gets a Luas colour")
        XCTAssertEqual(Theme.lineColor(mode: .train, route: "DART"), Theme.dart)
        XCTAssertEqual(Theme.lineColor(mode: .train, route: "Commuter"), Theme.irishRail)
        XCTAssertEqual(Theme.lineColor(mode: .bus, route: "39A"), Theme.ink)
        XCTAssertEqual(Theme.badgeTextColor(mode: .bus, route: "39A"), Theme.card)
        XCTAssertEqual(Theme.badgeTextColor(mode: .luas, route: "Red"), .white)
    }

    func testTimeColours() {
        XCTAssertEqual(Theme.timeColor(for: .live, cancelled: false), Theme.brand)
        XCTAssertEqual(Theme.timeColor(for: .realtime, cancelled: false), Theme.ink, "a prediction without a tracked vehicle is not live")
        XCTAssertEqual(Theme.timeColor(for: .timetable, cancelled: false), Theme.muted)
        XCTAssertEqual(Theme.timeColor(for: .live, cancelled: true), Theme.cancelled)
    }

    func testHexInitialiser() {
        XCTAssertEqual(Self.hex(UIColor(Color(hex: 0x00A651))), 0x00A651)
        XCTAssertEqual(Self.hex(UIColor(Color(hex: 0xE3001B))), 0xE3001B)
    }

    private static func hex(_ colour: UIColor) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}
