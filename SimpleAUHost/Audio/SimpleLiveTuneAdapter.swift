@preconcurrency import AudioToolbox
import Foundation

enum SimpleLiveTuneParameterMap {
    static let componentSubType = fourCharCode("Sltn")
    static let componentManufacturer = fourCharCode("Stau")

    static let keyParameterID: AudioUnitParameterID = 106_079
    static let scaleParameterID: AudioUnitParameterID = 109_250_890
    static let retuneSpeedParameterID: AudioUnitParameterID = 1_213_086_891
    static let noteTransitionParameterID: AudioUnitParameterID = 423_325_013
    static let bypassParameterID: AudioUnitParameterID = 773_352_680
    private static let keyPreferredNames = ["key"]
    private static let scalePreferredNames = ["scale"]
    private static let retuneSpeedPreferredNames = ["retune", "retune speed"]
    private static let noteTransitionPreferredNames = ["note transition", "transition"]
    private static let bypassPreferredNames = ["bypass"]
    private static let keyParameterTokens = ["key"]
    private static let scaleParameterTokens = ["scale"]
    private static let retuneSpeedParameterTokens = ["retune"]
    private static let noteTransitionParameterTokens = ["transition"]
    private static let bypassParameterTokens = ["bypass"]

    static func matches(_ plugin: AudioUnitPluginInfo) -> Bool {
        let description = plugin.componentDescription
        if description.componentSubType == componentSubType,
           description.componentManufacturer == componentManufacturer {
            return true
        }

        let normalizedName = normalizeIdentity(plugin.name)
        return normalizedName.contains("simplelivetune")
    }

    static func scaleValue(for scaleMode: TuneScaleMode) -> AudioUnitParameterValue {
        AudioUnitParameterValue(scaleMode.simpleLiveTunePluginValue)
    }

    static func keyValue(for selection: TuneKeySelection) -> AudioUnitParameterValue {
        AudioUnitParameterValue(selection.simpleLiveTuneKeyValue)
    }

    static func resolveKeyParameterIDs(for control: any PluginParameterControl) throws -> (
        key: AudioUnitParameterID,
        scale: AudioUnitParameterID
    ) {
        let parameterIDs = try control.availableParameterIDs()

        return (
            try resolveParameterID(
                hardcodedID: keyParameterID,
                in: control,
                parameterIDs: parameterIDs,
                preferredNames: keyPreferredNames,
                matchingAll: keyParameterTokens,
                failureName: "Key"
            ),
            try resolveParameterID(
                hardcodedID: scaleParameterID,
                in: control,
                parameterIDs: parameterIDs,
                preferredNames: scalePreferredNames,
                matchingAll: scaleParameterTokens,
                failureName: "Scale"
            )
        )
    }

    static func resolveStrengthParameterIDs(for control: any PluginParameterControl) throws -> (
        retuneSpeed: AudioUnitParameterID,
        noteTransition: AudioUnitParameterID
    ) {
        let parameterIDs = try control.availableParameterIDs()

        return (
            try resolveParameterID(
                hardcodedID: retuneSpeedParameterID,
                in: control,
                parameterIDs: parameterIDs,
                preferredNames: retuneSpeedPreferredNames,
                matchingAll: retuneSpeedParameterTokens,
                failureName: "Retune Speed"
            ),
            try resolveParameterID(
                hardcodedID: noteTransitionParameterID,
                in: control,
                parameterIDs: parameterIDs,
                preferredNames: noteTransitionPreferredNames,
                matchingAll: noteTransitionParameterTokens,
                failureName: "Note Transition"
            )
        )
    }

    static func resolveBypassParameterID(for control: any PluginParameterControl) throws -> AudioUnitParameterID {
        try resolveParameterID(
            hardcodedID: bypassParameterID,
            in: control,
            parameterIDs: try control.availableParameterIDs(),
            preferredNames: bypassPreferredNames,
            matchingAll: bypassParameterTokens,
            failureName: "Bypass"
        )
    }

    static func strengthValues(for control: any PluginParameterControl) throws -> (
        retuneSpeed: Float,
        noteTransition: Float
    ) {
        let parameterIDs = try resolveStrengthParameterIDs(for: control)
        return (
            try control.displayedParameterValue(for: parameterIDs.retuneSpeed),
            try control.displayedParameterValue(for: parameterIDs.noteTransition)
        )
    }

    static func parameterValue(
        for parameterID: AudioUnitParameterID,
        displayValue: Float,
        using control: any PluginParameterControl
    ) throws -> AudioUnitParameterValue {
        for candidate in parameterValueStringCandidates(for: displayValue) {
            if let resolvedValue = try control.parameterValue(
                for: parameterID,
                string: candidate
            ) {
                return resolvedValue
            }
        }

        return AudioUnitParameterValue(displayValue)
    }

    private static func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(OSType(0)) { result, byte in
            (result << 8) | OSType(byte)
        }
    }

    private static func resolveParameterID(
        hardcodedID: AudioUnitParameterID,
        in control: any PluginParameterControl,
        parameterIDs: [AudioUnitParameterID],
        preferredNames: [String],
        matchingAll tokens: [String],
        failureName: String
    ) throws -> AudioUnitParameterID {
        if parameterIDs.contains(hardcodedID) {
            return hardcodedID
        }

        guard let parameterID = try findParameterID(
            in: control,
            parameterIDs: parameterIDs,
            preferredNames: preferredNames,
            matchingAll: tokens
        ) else {
            throw AudioHostError("Failed to locate the Simple Live Tune \(failureName) parameter.")
        }

        return parameterID
    }

    private static func findParameterID(
        in control: any PluginParameterControl,
        parameterIDs: [AudioUnitParameterID],
        preferredNames: [String],
        matchingAll tokens: [String]
    ) throws -> AudioUnitParameterID? {
        let normalizedTokens = tokens.map { $0.lowercased() }
        let normalizedPreferredNames = preferredNames.map(normalizeParameterName)
        var fallbackMatch: AudioUnitParameterID?

        for parameterID in parameterIDs {
            let parameterName = try control.parameterDisplayName(for: parameterID)
            let normalizedName = normalizeParameterName(parameterName)

            if normalizedPreferredNames.contains(normalizedName) {
                return parameterID
            }

            if normalizedPreferredNames.contains(where: { preferredName in
                normalizedName.contains(preferredName)
            }) {
                fallbackMatch = fallbackMatch ?? parameterID
                continue
            }

            if normalizedTokens.allSatisfy(normalizedName.contains) {
                fallbackMatch = fallbackMatch ?? parameterID
            }
        }

        return fallbackMatch
    }

    private static func parameterValueStringCandidates(for displayValue: Float) -> [String] {
        let integerValue = Int(displayValue.rounded())
        let decimalString = String(format: "%.1f", displayValue)

        return [
            "\(integerValue) ms",
            "\(decimalString) ms",
            "\(integerValue)ms",
            "\(decimalString)ms",
            "\(integerValue)",
            decimalString
        ]
    }

    private static func normalizeParameterName(_ name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizeIdentity(_ name: String) -> String {
        name
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

extension MultiTrackAudioHostController.TrackRuntime {
    func setSimpleLiveTuneBypassed(_ isBypassed: Bool) throws -> Int {
        try applyToSimpleLiveTuneControls { control in
            let bypassParameterID = try SimpleLiveTuneParameterMap.resolveBypassParameterID(for: control)
            try control.setParameter(
                bypassParameterID,
                value: isBypassed ? 1 : 0,
                failureMessage: "Failed to update Simple Live Tune bypass"
            )
        }
    }

    func applySimpleLiveTuneKeySelection(_ selection: TuneKeySelection) throws -> Int {
        let normalizedSelection = selection.normalized
        return try applyToSimpleLiveTuneControls { control in
            let parameterIDs = try SimpleLiveTuneParameterMap.resolveKeyParameterIDs(for: control)
            try control.setParameter(
                parameterIDs.scale,
                value: SimpleLiveTuneParameterMap.scaleValue(for: normalizedSelection.scaleMode),
                failureMessage: "Failed to update the Simple Live Tune scale"
            )
            try control.setParameter(
                parameterIDs.key,
                value: SimpleLiveTuneParameterMap.keyValue(for: normalizedSelection),
                failureMessage: "Failed to update the Simple Live Tune key"
            )
        }
    }

    func applySimpleLiveTuneStrength(_ strength: TuneStrengthPreset) throws -> Int {
        guard let retuneSpeed = strength.simpleLiveTuneRetuneSpeed,
              let noteTransition = strength.simpleLiveTuneNoteTransition else {
            return 0
        }

        return try applyToSimpleLiveTuneControls { control in
            let parameterIDs = try SimpleLiveTuneParameterMap.resolveStrengthParameterIDs(for: control)
            let retuneSpeedValue = try SimpleLiveTuneParameterMap.parameterValue(
                for: parameterIDs.retuneSpeed,
                displayValue: retuneSpeed,
                using: control
            )
            let noteTransitionValue = try SimpleLiveTuneParameterMap.parameterValue(
                for: parameterIDs.noteTransition,
                displayValue: noteTransition,
                using: control
            )
            try control.setParameter(
                parameterIDs.retuneSpeed,
                value: retuneSpeedValue,
                failureMessage: "Failed to update the Simple Live Tune Retune Speed parameter"
            )
            try control.setParameter(
                parameterIDs.noteTransition,
                value: noteTransitionValue,
                failureMessage: "Failed to update the Simple Live Tune Note Transition parameter"
            )
        }
    }

    func currentSimpleLiveTuneStrengthPreset() throws -> TuneStrengthPreset? {
        var resolvedPreset: TuneStrengthPreset?

        for control in plugins where SimpleLiveTuneParameterMap.matches(control.pluginInfo) {
            let values = try SimpleLiveTuneParameterMap.strengthValues(for: control)
            let preset = TuneStrengthPreset.matchingSimpleLiveTuneValues(
                retuneSpeed: values.retuneSpeed,
                noteTransition: values.noteTransition
            )

            if let resolvedPreset, resolvedPreset != preset {
                return .custom
            }

            resolvedPreset = preset
        }

        return resolvedPreset
    }

    private func applyToSimpleLiveTuneControls(
        _ body: (any PluginParameterControl) throws -> Void
    ) throws -> Int {
        var affectedControls = 0

        for control in plugins where SimpleLiveTuneParameterMap.matches(control.pluginInfo) {
            try body(control)
            affectedControls += 1
        }

        return affectedControls
    }
}
