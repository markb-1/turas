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
            ("Muted", 0x5F716C, 0x8FA39D),
            ("Late", 0x9C5F00, 0xF0A93B),
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

    /// Caption text (later times, the late note, cancelled times) meets
    /// WCAG AA, 4.5:1, on cards and on the panel in both appearances.
    func testCaptionColoursContrastWithBackgrounds() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            func colour(_ name: String) throws -> UIColor {
                try XCTUnwrap(UIColor(named: name)).resolvedColor(with: traits)
            }
            for text in ["Ink", "Brand", "Muted", "Late", "Cancelled"] {
                for background in ["Card", "Surface"] {
                    let ratio = Self.contrast(try colour(text), try colour(background))
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text) on \(background), \(style == .dark ? "dark" : "light")")
                }
            }
        }
    }

    func testHexInitialiser() {
        XCTAssertEqual(Self.hex(UIColor(Color(hex: 0x00A651))), 0x00A651)
        XCTAssertEqual(Self.hex(UIColor(Color(hex: 0xE3001B))), 0xE3001B)
    }

    /// WCAG contrast ratio of two opaque sRGB colours.
    private static func contrast(_ first: UIColor, _ second: UIColor) -> Double {
        func luminance(_ colour: UIColor) -> Double {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func linear(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func hex(_ colour: UIColor) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}
