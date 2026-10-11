import XCTest
@testable import Pawtrackr

final class LocalizationTests: XCTestCase {
    
    func testKeyStrings_AreLocalizedInEnglish() {
        // These keys should match the values in Localizable.strings (en)
        XCTAssertEqual(NSLocalizedString("clients.tab", comment: ""), "Clients")
        XCTAssertEqual(NSLocalizedString("insights.tab", comment: ""), "Insights")
        XCTAssertEqual(NSLocalizedString("settings.tab", comment: ""), "Settings")
        
        XCTAssertEqual(NSLocalizedString("common.save", comment: ""), "Save")
        XCTAssertEqual(NSLocalizedString("common.cancel", comment: ""), "Cancel")
        XCTAssertEqual(NSLocalizedString("common.done", comment: ""), "Done")
        
        XCTAssertEqual(NSLocalizedString("species.dog", comment: ""), "Dog")
        XCTAssertEqual(NSLocalizedString("species.cat", comment: ""), "Cat")
        
        XCTAssertEqual(NSLocalizedString("gender.male", comment: ""), "Male")
        XCTAssertEqual(NSLocalizedString("gender.female", comment: ""), "Female")
    }
    
    func testCheckoutStrings_ArePresent() {
        XCTAssertEqual(NSLocalizedString("checkout.complete_title", comment: ""), "Checkout Complete!")
        XCTAssertTrue(NSLocalizedString("checkout.processing", comment: "").contains("Processing"))
    }

    func testSpanishBundlesContainEverySwiftLocalizationKey() throws {
        let repositoryRoot = try Self.repositoryRoot()
        let sourceRoot = repositoryRoot.appendingPathComponent("Pawtrackr")
        let localizationRoot = sourceRoot.appendingPathComponent("App/Navigation/Coordinators/Localizable")
        let keysUsedInSwift = try Self.swiftLocalizationKeys(under: sourceRoot)

        for locale in ["es", "es-419"] {
            let stringsURL = localizationRoot
                .appendingPathComponent("\(locale).lproj")
                .appendingPathComponent("Localizable.strings")
            let localizedKeys = try Self.keys(inStringsFile: stringsURL)
            let missing = keysUsedInSwift.subtracting(localizedKeys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(locale).lproj is missing localization keys: \(missing.joined(separator: ", "))")
        }
    }

    /// English has its own table too: a key missing there falls back to the
    /// device language's bundle instead of the code's English text.
    func testEnglishBundleContainsEverySwiftLocalizationKey() throws {
        let sourceRoot = try Self.repositoryRoot().appendingPathComponent("Pawtrackr")
        let keysUsedInSwift = try Self.swiftLocalizationKeys(under: sourceRoot)
        let localizedKeys = try Self.keys(inStringsFile: Self.stringsURL(locale: "en", sourceRoot: sourceRoot))
        let missing = keysUsedInSwift.subtracting(localizedKeys).sorted()
        XCTAssertTrue(missing.isEmpty, "en.lproj is missing localization keys: \(missing.joined(separator: ", "))")
    }

    /// A translation with a different placeholder list crashes or garbles
    /// `String(format:)`, so every key must carry the same specifiers in
    /// en, es and es-419.
    func testFormatSpecifiersMatchAcrossLocales() throws {
        let sourceRoot = try Self.repositoryRoot().appendingPathComponent("Pawtrackr")
        var tables: [String: [String: String]] = [:]
        for locale in ["en", "es", "es-419"] {
            let url = Self.stringsURL(locale: locale, sourceRoot: sourceRoot)
            let data = try Data(contentsOf: url)
            tables[locale] = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
        }
        let english = try XCTUnwrap(tables["en"])
        var mismatches: [String] = []
        for (key, englishValue) in english {
            let expected = Self.formatSpecifiers(in: englishValue)
            for locale in ["es", "es-419"] {
                guard let value = tables[locale]?[key] else { continue }
                if Self.formatSpecifiers(in: value) != expected {
                    mismatches.append("\(locale) \(key)")
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "Format specifiers differ from English: \(mismatches.sorted().joined(separator: ", "))")
    }

    func testSpanishTablesCoverTheSameKeys() throws {
        let sourceRoot = try Self.repositoryRoot().appendingPathComponent("Pawtrackr")
        let spain = try Self.keys(inStringsFile: Self.stringsURL(locale: "es", sourceRoot: sourceRoot))
        let latinAmerica = try Self.keys(inStringsFile: Self.stringsURL(locale: "es-419", sourceRoot: sourceRoot))
        XCTAssertEqual(spain.symmetricDifference(latinAmerica).sorted(), [])
    }

    func testLoyaltyWordingFollowsTheAppLanguage() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: AppSettingsKeys.appLanguageOverride)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppSettingsKeys.appLanguageOverride)
            } else {
                defaults.removeObject(forKey: AppSettingsKeys.appLanguageOverride)
            }
        }

        defaults.set(AppLanguageOverride.en.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
        XCTAssertEqual(LoyaltyCopy.points(1), "1 point")
        XCTAssertEqual(LoyaltyCopy.points(25), "25 points")
        XCTAssertEqual(LoyaltyTier.gold.displayName, "Gold")

        defaults.set(AppLanguageOverride.es.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
        XCTAssertEqual(LoyaltyCopy.points(1), "1 punto")
        XCTAssertEqual(LoyaltyCopy.points(25), "25 puntos")
        XCTAssertEqual(LoyaltyTier.gold.displayName, "Oro")
    }

    /// The onboarding simulator shows the catalog a new salon is seeded with,
    /// in the same order and at the same costs.
    func testLoyaltySimulatorShowsTheSeededCatalog() {
        let ladder = LoyaltyRewardCatalog.rewardLadder
        XCTAssertEqual(ladder.map(\.points), LoyaltyReward.builtInCatalog.map(\.pointCost))
        XCTAssertEqual(ladder.count, LoyaltyReward.builtInCatalog.count)
    }

    private static func stringsURL(locale: String, sourceRoot: URL) -> URL {
        sourceRoot
            .appendingPathComponent("App/Navigation/Coordinators/Localizable")
            .appendingPathComponent("\(locale).lproj")
            .appendingPathComponent("Localizable.strings")
    }

    /// Conversion characters in placeholder order, e.g. "%1$d of %2$@" -> ["d", "@"].
    private static func formatSpecifiers(in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            // No space flag: "15% Off" is a percent sign, not "% O".
            pattern: #"%(?:(\d+)\$)?[-+#0]*\d*(?:\.\d+)?(?:ll|l|hh|h|z|q)?([@dDiuUxXoOfFeEgGcCsS%])"#
        ) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var positioned: [(Int, String)] = []
        var sequential = 0
        for match in regex.matches(in: value, range: range) {
            guard let conversionRange = Range(match.range(at: 2), in: value) else { continue }
            var conversion = String(value[conversionRange])
            if conversion == "%" { continue }
            switch conversion {
            case "d", "D", "i", "u", "U", "x", "X", "o", "O", "c", "C": conversion = "d"
            case "f", "F", "e", "E", "g", "G": conversion = "f"
            case "s", "S": conversion = "@"
            default: break
            }
            let position: Int
            if let positionRange = Range(match.range(at: 1), in: value), let explicit = Int(value[positionRange]) {
                position = explicit
            } else {
                sequential += 1
                position = sequential
            }
            positioned.append((position, conversion))
        }
        return positioned.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath)
        while candidate.path != "/" {
            let project = candidate.appendingPathComponent("Pawtrackr.xcodeproj")
            if FileManager.default.fileExists(atPath: project.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate Pawtrackr repository root.")
    }

    private static func swiftLocalizationKeys(under sourceRoot: URL) throws -> Set<String> {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }

        let patterns = [
            #"(?:NSLocalizedString|LocalizedStringKey|localized|settingsLocalized|devicesLocalized)\(\s*"([A-Za-z_][A-Za-z0-9_.-]*)""#,
            #"(?:Text|TextField|SecureField|Label|Button|Picker|Toggle|DatePicker|ContentUnavailableView|navigationTitle)\(\s*"([A-Za-z_][A-Za-z0-9_.-]*\.[A-Za-z0-9_.-]*)""#
        ]
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        var keys = Set<String>()

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for regex in regexes {
                for match in regex.matches(in: source, range: range) {
                    guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                    keys.insert(String(source[keyRange]))
                }
            }
        }

        return keys
    }

    private static func keys(inStringsFile url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = plist as? [String: String] else {
            XCTFail("Could not parse \(url.path) as a strings table.")
            return []
        }
        return Set(dictionary.keys)
    }
}
