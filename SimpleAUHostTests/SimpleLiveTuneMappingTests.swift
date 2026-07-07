@preconcurrency import AudioToolbox
import XCTest
@testable import SimpleAUHost

final class SimpleLiveTuneMappingTests: XCTestCase {
    func testPluginIdentityMatchesComponentCodes() {
        let plugin = AudioUnitPluginInfo(
            id: "aufx:Sltn:Stau",
            name: "Unexpected Display Name",
            componentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: SimpleLiveTuneParameterMap.componentSubType,
                componentManufacturer: SimpleLiveTuneParameterMap.componentManufacturer,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        )

        XCTAssertTrue(SimpleLiveTuneParameterMap.matches(plugin))
    }

    func testPluginIdentityFallsBackToName() {
        let plugin = AudioUnitPluginInfo(
            id: "fake.simple.live.tune",
            name: "Simple Live Tune",
            componentDescription: AudioComponentDescription(
                componentType: 0,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        )

        XCTAssertTrue(SimpleLiveTuneParameterMap.matches(plugin))
    }

    func testPluginIdentityFallsBackToCompactName() {
        let plugin = AudioUnitPluginInfo(
            id: "fake.simplelivetune",
            name: "Staubichsauger: SimpleLiveTune",
            componentDescription: AudioComponentDescription(
                componentType: 0,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        )

        XCTAssertTrue(SimpleLiveTuneParameterMap.matches(plugin))
    }

    func testScaleModeMapsToSimpleLiveTuneValues() {
        let cases: [(TuneScaleMode, Int)] = [
            (.chromatic, 0),
            (.major, 1),
            (.minor, 2)
        ]

        for (scaleMode, expectedValue) in cases {
            XCTAssertEqual(scaleMode.simpleLiveTunePluginValue, expectedValue)
        }
    }

    func testKeySelectionMapsToSemitoneIndex() {
        let cases: [(TuneNoteLetter, TuneAccidental, Int)] = [
            (.c, .natural, 0),
            (.c, .sharp, 1),
            (.d, .flat, 1),
            (.d, .natural, 2),
            (.d, .sharp, 3),
            (.e, .flat, 3),
            (.e, .natural, 4),
            (.f, .natural, 5),
            (.f, .sharp, 6),
            (.g, .flat, 6),
            (.g, .natural, 7),
            (.g, .sharp, 8),
            (.a, .flat, 8),
            (.a, .natural, 9),
            (.a, .sharp, 10),
            (.b, .flat, 10),
            (.b, .natural, 11)
        ]

        for (noteLetter, accidental, expectedValue) in cases {
            let selection = TuneKeySelection(
                scaleMode: .major,
                noteLetter: noteLetter,
                accidental: accidental
            )

            XCTAssertEqual(selection.simpleLiveTuneKeyValue, expectedValue, selection.rootTitle)
        }
    }

    func testKeySelectionNormalizesUnsupportedAccidentalsBeforeAdapterMapping() {
        let cases: [(TuneNoteLetter, TuneAccidental, Int)] = [
            (.c, .flat, 0),
            (.e, .sharp, 4),
            (.f, .flat, 5),
            (.b, .sharp, 11)
        ]

        for (noteLetter, accidental, expectedValue) in cases {
            let selection = TuneKeySelection(
                scaleMode: .minor,
                noteLetter: noteLetter,
                accidental: accidental
            ).normalized

            XCTAssertEqual(selection.simpleLiveTuneKeyValue, expectedValue)
            XCTAssertEqual(selection.accidental, .natural)
        }
    }

    func testStrengthPresetMapsToSimpleLiveTuneMilliseconds() {
        let cases: [(TuneStrengthPreset, Float, Float)] = [
            (.fast, 15, 50),
            (.standard, 20, 60),
            (.slow, 40, 90)
        ]

        for (preset, expectedRetuneSpeed, expectedNoteTransition) in cases {
            XCTAssertEqual(preset.simpleLiveTuneRetuneSpeed, expectedRetuneSpeed)
            XCTAssertEqual(preset.simpleLiveTuneNoteTransition, expectedNoteTransition)
            XCTAssertEqual(
                TuneStrengthPreset.matchingSimpleLiveTuneValues(
                    retuneSpeed: expectedRetuneSpeed,
                    noteTransition: expectedNoteTransition
                ),
                preset
            )
        }
    }

    func testStrengthPresetDetectionUsesTolerance() {
        XCTAssertEqual(
            TuneStrengthPreset.matchingSimpleLiveTuneValues(
                retuneSpeed: 20.2,
                noteTransition: 59.8
            ),
            .standard
        )
        XCTAssertEqual(
            TuneStrengthPreset.matchingSimpleLiveTuneValues(
                retuneSpeed: 20.3,
                noteTransition: 60
            ),
            .custom
        )
    }

    func testKeyParameterResolutionFallsBackToNames() throws {
        let control = FakeSimpleLiveTuneParameterControl(parameterNames: [
            10: "Key",
            11: "Scale",
            12: "Retune",
            13: "Transition",
            14: "Bypass"
        ])

        let parameterIDs = try SimpleLiveTuneParameterMap.resolveKeyParameterIDs(for: control)

        XCTAssertEqual(parameterIDs.key, 10)
        XCTAssertEqual(parameterIDs.scale, 11)
        XCTAssertEqual(try SimpleLiveTuneParameterMap.resolveBypassParameterID(for: control), 14)
    }

    func testStrengthParameterResolutionFallsBackToNames() throws {
        let control = FakeSimpleLiveTuneParameterControl(parameterNames: [
            10: "Key",
            11: "Scale",
            12: "Retune",
            13: "Transition",
            14: "Bypass"
        ])

        let parameterIDs = try SimpleLiveTuneParameterMap.resolveStrengthParameterIDs(for: control)

        XCTAssertEqual(parameterIDs.retuneSpeed, 12)
        XCTAssertEqual(parameterIDs.noteTransition, 13)
    }

    func testParameterResolutionPrefersHardcodedIDsWhenAdvertised() throws {
        let control = FakeSimpleLiveTuneParameterControl(parameterNames: [
            10: "Key",
            11: "Scale",
            SimpleLiveTuneParameterMap.keyParameterID: "SLT Key"
        ])

        let parameterIDs = try SimpleLiveTuneParameterMap.resolveKeyParameterIDs(for: control)

        XCTAssertEqual(parameterIDs.key, SimpleLiveTuneParameterMap.keyParameterID)
        XCTAssertEqual(parameterIDs.scale, 11)
    }
}

private final class FakeSimpleLiveTuneParameterControl: PluginParameterControl {
    let pluginInfo = AudioUnitPluginInfo(
        id: "fake.simple.live.tune",
        name: "SimpleLiveTune",
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
