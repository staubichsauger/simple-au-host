import XCTest
@testable import SimpleAUHost

final class WavesTuneMappingTests: XCTestCase {
    func testPluginScaleRootValueCoversSupportedRoots() {
        let cases: [(WavesTuneNoteLetter, WavesTuneAccidental, Int)] = [
            (.c, .natural, 0),
            (.c, .sharp, 1),
            (.d, .flat, 2),
            (.d, .natural, 3),
            (.d, .sharp, 4),
            (.e, .flat, 5),
            (.e, .natural, 6),
            (.f, .natural, 7),
            (.f, .sharp, 8),
            (.g, .flat, 9),
            (.g, .natural, 10),
            (.g, .sharp, 11),
            (.a, .flat, 12),
            (.a, .natural, 13),
            (.a, .sharp, 14),
            (.b, .flat, 15),
            (.b, .natural, 16)
        ]

        for (noteLetter, accidental, expectedValue) in cases {
            let selection = WavesTuneKeySelection(
                scaleMode: .major,
                noteLetter: noteLetter,
                accidental: accidental
            )

            XCTAssertEqual(
                selection.pluginScaleRootValue,
                expectedValue,
                "\(selection.rootTitle) should map to \(expectedValue)"
            )
        }
    }

    func testPluginScaleRootValueNormalizesUnsupportedAccidentals() {
        let cases: [(WavesTuneNoteLetter, WavesTuneAccidental, Int)] = [
            (.c, .flat, 0),
            (.e, .sharp, 6),
            (.f, .flat, 7),
            (.b, .sharp, 16)
        ]

        for (noteLetter, accidental, expectedValue) in cases {
            let selection = WavesTuneKeySelection(
                scaleMode: .minor,
                noteLetter: noteLetter,
                accidental: accidental
            )

            XCTAssertEqual(selection.pluginScaleRootValue, expectedValue)
            XCTAssertEqual(selection.normalized.accidental, .natural)
        }
    }

    func testCompanionControlRootChoiceParsesSupportedApiRoots() {
        let cases: [(String, WavesTuneNoteLetter, WavesTuneAccidental)] = [
            ("c", .c, .natural),
            ("c#", .c, .sharp),
            ("db", .d, .flat),
            ("d", .d, .natural),
            ("d#", .d, .sharp),
            ("eb", .e, .flat),
            ("e", .e, .natural),
            ("f", .f, .natural),
            ("f#", .f, .sharp),
            ("gb", .g, .flat),
            ("g", .g, .natural),
            ("g#", .g, .sharp),
            ("ab", .a, .flat),
            ("a", .a, .natural),
            ("a#", .a, .sharp),
            ("bb", .b, .flat),
            ("b", .b, .natural)
        ]

        for (rawValue, expectedNoteLetter, expectedAccidental) in cases {
            let choice = CompanionControlRootChoice(rawValue: rawValue)

            XCTAssertEqual(choice?.noteLetter, expectedNoteLetter, rawValue)
            XCTAssertEqual(choice?.accidental, expectedAccidental, rawValue)
        }
    }

    func testCompanionControlRootChoiceRejectsUnsupportedApiRoots() {
        XCTAssertNil(CompanionControlRootChoice(rawValue: "cb"))
        XCTAssertNil(CompanionControlRootChoice(rawValue: "e#"))
        XCTAssertNil(CompanionControlRootChoice(rawValue: "h"))
    }
}
