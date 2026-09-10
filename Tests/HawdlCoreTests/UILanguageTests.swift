import XCTest

@testable import HawdlCore

final class UILanguageTests: XCTestCase {
    func testJapaneseVariantsResolveToJapanese() {
        for tag in ["ja", "ja-JP", "ja-Jpan", "ja-Jpan-JP"] {
            XCTAssertEqual(UILanguage.resolve(preferredLanguages: [tag]), .japanese, tag)
        }
    }

    func testEverythingElseFallsBackToEnglish() {
        for tag in ["en", "en-GB", "de-DE", "fr", "zh-Hans-CN", "ko-KR", "pt-BR"] {
            XCTAssertEqual(UILanguage.resolve(preferredLanguages: [tag]), .english, tag)
        }
    }

    /// "jam", "jav" and "jbo" are Jamaican Creole, Javanese and Lojban. A
    /// prefix test on "ja" would hand all three a Japanese UI.
    func testTagsMerelyBeginningWithJaAreNotJapanese() {
        for tag in ["jam", "jav", "jbo"] {
            XCTAssertEqual(UILanguage.resolve(preferredLanguages: [tag]), .english, tag)
        }
    }

    /// Only the primary language decides. Someone listing German first and
    /// Japanese second wants German, and with no German shipped, English is
    /// the better of the two languages that are.
    func testOnlyTheFirstEntryDecides() {
        XCTAssertEqual(UILanguage.resolve(preferredLanguages: ["de-DE", "ja-JP"]), .english)
        XCTAssertEqual(UILanguage.resolve(preferredLanguages: ["ja-JP", "en-US"]), .japanese)
    }

    func testEmptyListFallsBackToEnglish() {
        XCTAssertEqual(UILanguage.resolve(preferredLanguages: []), .english)
    }

    /// Garbage in the list must not throw or trap — it is read straight from
    /// user defaults, which anyone can write.
    func testMalformedTagsFallBackToEnglish() {
        for tag in ["not-a-language-tag", "12345"] {
            XCTAssertEqual(UILanguage.resolve(preferredLanguages: [tag]), .english, tag)
        }
    }

    /// The process-wide value has to be one of the two the app can draw.
    func testCurrentIsAlwaysResolvable() {
        XCTAssertTrue(UILanguage.allCases.contains(UILanguage.current))
    }
}
