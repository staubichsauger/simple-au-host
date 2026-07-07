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

    static func matches(_ plugin: AudioUnitPluginInfo) -> Bool {
        let description = plugin.componentDescription
        if description.componentSubType == componentSubType,
           description.componentManufacturer == componentManufacturer {
            return true
        }
        return plugin.name.localizedCaseInsensitiveContains("Simple Live Tune")
    }

    static func scaleValue(for scaleMode: WavesTuneScaleMode) -> AudioUnitParameterValue {
        AudioUnitParameterValue(scaleMode.simpleLiveTunePluginValue)
    }

    static func keyValue(for selection: WavesTuneKeySelection) -> AudioUnitParameterValue {
        AudioUnitParameterValue(selection.simpleLiveTuneKeyValue)
    }

    private static func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(OSType(0)) { result, byte in
            (result << 8) | OSType(byte)
        }
    }
}

extension MultiTrackAudioHostController.TrackRuntime {
    func setSimpleLiveTuneBypassed(_ isBypassed: Bool) throws -> Int {
        try applyToSimpleLiveTuneControls { control in
            try control.setParameter(
                SimpleLiveTuneParameterMap.bypassParameterID,
                value: isBypassed ? 1 : 0,
                failureMessage: "Failed to update Simple Live Tune bypass"
            )
        }
    }

    func applySimpleLiveTuneKeySelection(_ selection: WavesTuneKeySelection) throws -> Int {
        let normalizedSelection = selection.normalized
        return try applyToSimpleLiveTuneControls { control in
            try control.setParameter(
                SimpleLiveTuneParameterMap.scaleParameterID,
                value: SimpleLiveTuneParameterMap.scaleValue(for: normalizedSelection.scaleMode),
                failureMessage: "Failed to update the Simple Live Tune scale"
            )
            try control.setParameter(
                SimpleLiveTuneParameterMap.keyParameterID,
                value: SimpleLiveTuneParameterMap.keyValue(for: normalizedSelection),
                failureMessage: "Failed to update the Simple Live Tune key"
            )
        }
    }

    func applySimpleLiveTuneStrength(_ strength: WavesTuneStrengthPreset) throws -> Int {
        guard let retuneSpeed = strength.simpleLiveTuneRetuneSpeed,
              let noteTransition = strength.simpleLiveTuneNoteTransition else {
            return 0
        }

        return try applyToSimpleLiveTuneControls { control in
            try control.setParameter(
                SimpleLiveTuneParameterMap.retuneSpeedParameterID,
                value: retuneSpeed,
                failureMessage: "Failed to update the Simple Live Tune Retune Speed parameter"
            )
            try control.setParameter(
                SimpleLiveTuneParameterMap.noteTransitionParameterID,
                value: noteTransition,
                failureMessage: "Failed to update the Simple Live Tune Note Transition parameter"
            )
        }
    }

    func currentSimpleLiveTuneStrengthPreset() throws -> WavesTuneStrengthPreset? {
        var resolvedPreset: WavesTuneStrengthPreset?

        for control in plugins where SimpleLiveTuneParameterMap.matches(control.pluginInfo) {
            let preset = WavesTuneStrengthPreset.matchingSimpleLiveTuneValues(
                retuneSpeed: try control.displayedParameterValue(for: SimpleLiveTuneParameterMap.retuneSpeedParameterID),
                noteTransition: try control.displayedParameterValue(for: SimpleLiveTuneParameterMap.noteTransitionParameterID)
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
