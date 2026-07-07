@preconcurrency import AudioToolbox
import Foundation

enum WavesTuneRealtimeParameterMap {
    static let scaleTypeParameterID: AudioUnitParameterID = 10
    static let scaleRootParameterID: AudioUnitParameterID = 11
    private static let speedPreferredNames = ["speed", "tune speed"]
    private static let noteTransitionPreferredNames = ["note transition", "note trans", "transition"]
    private static let speedParameterTokens = ["speed"]
    private static let noteTransitionParameterTokens = ["note", "transition"]

    static func matches(_ plugin: AudioUnitPluginInfo) -> Bool {
        plugin.name.localizedCaseInsensitiveContains("Waves Tune Real-Time")
    }

    static func resolveStrengthParameterIDs(for control: any PluginParameterControl) throws -> (
        speed: AudioUnitParameterID,
        noteTransition: AudioUnitParameterID
    ) {
        let parameterIDs = try control.availableParameterIDs()

        guard let speedParameterID = try findParameterID(
            in: control,
            parameterIDs: parameterIDs,
            preferredNames: speedPreferredNames,
            matchingAll: speedParameterTokens
        ) else {
            throw AudioHostError("Failed to locate the Waves Tune Speed parameter.")
        }

        guard let noteTransitionParameterID = try findParameterID(
            in: control,
            parameterIDs: parameterIDs,
            preferredNames: noteTransitionPreferredNames,
            matchingAll: noteTransitionParameterTokens
        ) else {
            throw AudioHostError("Failed to locate the Waves Tune Note Transition parameter.")
        }

        return (speedParameterID, noteTransitionParameterID)
    }

    static func strengthValues(for control: any PluginParameterControl) throws -> (
        speed: Float,
        noteTransition: Float
    ) {
        let parameterIDs = try resolveStrengthParameterIDs(for: control)
        return (
            try control.displayedParameterValue(for: parameterIDs.speed),
            try control.displayedParameterValue(for: parameterIDs.noteTransition)
        )
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
}

extension MultiTrackAudioHostController.TrackRuntime {
    func setWavesTuneRealtimeBypassed(_ isBypassed: Bool) throws -> Int {
        try applyToWavesTuneRealtimeControls { control in
            try control.setBypass(
                isBypassed,
                failureMessage: "Failed to update Waves Tune bypass"
            )
        }
    }

    func applyWavesTuneRealtimeKeySelection(_ selection: TuneKeySelection) throws -> Int {
        let normalizedSelection = selection.normalized
        return try applyToWavesTuneRealtimeControls { control in
            try control.setParameter(
                WavesTuneRealtimeParameterMap.scaleTypeParameterID,
                value: AudioUnitParameterValue(normalizedSelection.pluginScaleTypeValue),
                failureMessage: "Failed to update the Waves Tune scale type"
            )
            try control.setParameter(
                WavesTuneRealtimeParameterMap.scaleRootParameterID,
                value: AudioUnitParameterValue(normalizedSelection.pluginScaleRootValue),
                failureMessage: "Failed to update the Waves Tune scale root"
            )
        }
    }

    func applyWavesTuneRealtimeStrength(_ strength: TuneStrengthPreset) throws -> Int {
        guard let speed = strength.speed,
              let noteTransition = strength.noteTransition else {
            return 0
        }

        return try applyToWavesTuneRealtimeControls { control in
            let parameterIDs = try WavesTuneRealtimeParameterMap.resolveStrengthParameterIDs(for: control)
            let speedValue = try WavesTuneRealtimeParameterMap.parameterValue(
                for: parameterIDs.speed,
                displayValue: speed,
                using: control
            )
            let noteTransitionValue = try WavesTuneRealtimeParameterMap.parameterValue(
                for: parameterIDs.noteTransition,
                displayValue: noteTransition,
                using: control
            )
            try control.setParameter(
                parameterIDs.speed,
                value: speedValue,
                failureMessage: "Failed to update the Waves Tune Speed parameter"
            )
            try control.setParameter(
                parameterIDs.noteTransition,
                value: noteTransitionValue,
                failureMessage: "Failed to update the Waves Tune Note Transition parameter"
            )
        }
    }

    func currentWavesTuneRealtimeStrengthPreset() throws -> TuneStrengthPreset? {
        var resolvedPreset: TuneStrengthPreset?

        for control in plugins where WavesTuneRealtimeParameterMap.matches(control.pluginInfo) {
            let values = try WavesTuneRealtimeParameterMap.strengthValues(for: control)
            let preset = TuneStrengthPreset.matchingDisplayValues(
                speed: values.speed,
                noteTransition: values.noteTransition
            )

            if let resolvedPreset, resolvedPreset != preset {
                return .custom
            }

            resolvedPreset = preset
        }

        return resolvedPreset
    }

    private func applyToWavesTuneRealtimeControls(
        _ body: (any PluginParameterControl) throws -> Void
    ) throws -> Int {
        var affectedControls = 0

        for control in plugins where WavesTuneRealtimeParameterMap.matches(control.pluginInfo) {
            try body(control)
            affectedControls += 1
        }

        return affectedControls
    }
}
