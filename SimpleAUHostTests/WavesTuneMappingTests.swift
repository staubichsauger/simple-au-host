@preconcurrency import AudioToolbox
import XCTest
@testable import SimpleAUHost

final class WavesTuneMappingTests: XCTestCase {
    func testPluginScaleTypeValueCoversSupportedScaleModes() {
        let cases: [(WavesTuneScaleMode, Int)] = [
            (.chromatic, 1),
            (.major, 2),
            (.minor, 3)
        ]

        for (scaleMode, expectedValue) in cases {
            let selection = WavesTuneKeySelection(scaleMode: scaleMode)

            XCTAssertEqual(
                selection.pluginScaleTypeValue,
                expectedValue,
                "\(scaleMode.title) should map to \(expectedValue)"
            )
        }
    }

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

    func testWavesTuneStrengthParameterResolutionPrefersExactNameOverEarlierFallback() throws {
        let control = FakePluginParameterControl(parameterNames: [
            10: "Lead Vocal Speed Trim",
            11: "Speed",
            20: "Note Transition"
        ])

        let parameterIDs = try WavesTuneRealtimeParameterMap.resolveStrengthParameterIDs(for: control)

        XCTAssertEqual(parameterIDs.speed, 11)
        XCTAssertEqual(parameterIDs.noteTransition, 20)
    }

    func testWavesTuneStrengthParameterResolutionUsesFirstFallbackMatch() throws {
        let control = FakePluginParameterControl(parameterNames: [
            10: "Retune Speed Primary",
            11: "Retune Speed Secondary",
            20: "Voice Note Transition Primary",
            21: "Voice Note Transition Secondary"
        ])

        let parameterIDs = try WavesTuneRealtimeParameterMap.resolveStrengthParameterIDs(for: control)

        XCTAssertEqual(parameterIDs.speed, 10)
        XCTAssertEqual(parameterIDs.noteTransition, 20)
    }

    func testWavesTuneStrengthParameterResolutionThrowsWhenSpeedIsMissing() {
        let control = FakePluginParameterControl(parameterNames: [
            20: "Note Transition"
        ])

        XCTAssertThrowsError(try WavesTuneRealtimeParameterMap.resolveStrengthParameterIDs(for: control)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Speed parameter"))
        }
    }

    func testWavesTuneStrengthParameterResolutionThrowsWhenNoteTransitionIsMissing() {
        let control = FakePluginParameterControl(parameterNames: [
            10: "Speed"
        ])

        XCTAssertThrowsError(try WavesTuneRealtimeParameterMap.resolveStrengthParameterIDs(for: control)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Note Transition parameter"))
        }
    }
}

private final class FakePluginParameterControl: PluginParameterControl {
    let pluginInfo = AudioUnitPluginInfo(
        id: "fake.waves.tune",
        name: "Waves Tune Real-Time",
        componentDescription: AudioComponentDescription(
            componentType: 0,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    )

    private let parameterNames: [AudioUnitParameterID: String]

    init(parameterNames: [AudioUnitParameterID: String]) {
        self.parameterNames = parameterNames
    }

    func setBypass(_ isBypassed: Bool, failureMessage: String) throws {}

    func setParameter(
        _ parameterID: AudioUnitParameterID,
        value: AudioUnitParameterValue,
        failureMessage: String
    ) throws {}

    func availableParameterIDs() throws -> [AudioUnitParameterID] {
        parameterNames.keys.sorted()
    }

    func parameterDisplayName(for parameterID: AudioUnitParameterID) throws -> String {
        guard let name = parameterNames[parameterID] else {
            throw AudioHostError("Missing fake parameter \(parameterID).")
        }
        return name
    }

    func displayedParameterValue(for parameterID: AudioUnitParameterID) throws -> Float {
        throw AudioHostError("Fake control does not provide displayed values.")
    }

    func parameterValue(
        for parameterID: AudioUnitParameterID,
        string: String
    ) throws -> AudioUnitParameterValue? {
        nil
    }
}
