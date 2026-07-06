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

    static func resolveStrengthParameterIDs(for unit: AudioUnit) throws -> (
        speed: AudioUnitParameterID,
        noteTransition: AudioUnitParameterID
    ) {
        let parameterIDs = try availableParameterIDs(for: unit)

        guard let speedParameterID = try findParameterID(
            in: unit,
            parameterIDs: parameterIDs,
            preferredNames: speedPreferredNames,
            matchingAll: speedParameterTokens
        ) else {
            throw AudioHostError("Failed to locate the Waves Tune Speed parameter.")
        }

        guard let noteTransitionParameterID = try findParameterID(
            in: unit,
            parameterIDs: parameterIDs,
            preferredNames: noteTransitionPreferredNames,
            matchingAll: noteTransitionParameterTokens
        ) else {
            throw AudioHostError("Failed to locate the Waves Tune Note Transition parameter.")
        }

        return (speedParameterID, noteTransitionParameterID)
    }

    static func strengthValues(for unit: AudioUnit) throws -> (
        speed: Float,
        noteTransition: Float
    ) {
        let parameterIDs = try resolveStrengthParameterIDs(for: unit)
        return (
            try displayedParameterValue(for: parameterIDs.speed, in: unit),
            try displayedParameterValue(for: parameterIDs.noteTransition, in: unit)
        )
    }

    private static func availableParameterIDs(for unit: AudioUnit) throws -> [AudioUnitParameterID] {
        var propertySize: UInt32 = 0
        try checkStatus(
            AudioUnitGetPropertyInfo(
                unit,
                kAudioUnitProperty_ParameterList,
                kAudioUnitScope_Global,
                0,
                &propertySize,
                nil
            ),
            "Failed to inspect Audio Unit parameters"
        )

        let count = Int(propertySize) / MemoryLayout<AudioUnitParameterID>.size
        guard count > 0 else { return [] }

        var parameterIDs = Array(repeating: AudioUnitParameterID(0), count: count)
        try parameterIDs.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            try checkStatus(
                AudioUnitGetProperty(
                    unit,
                    kAudioUnitProperty_ParameterList,
                    kAudioUnitScope_Global,
                    0,
                    baseAddress,
                    &propertySize
                ),
                "Failed to load Audio Unit parameters"
            )
        }
        return parameterIDs
    }

    private static func findParameterID(
        in unit: AudioUnit,
        parameterIDs: [AudioUnitParameterID],
        preferredNames: [String],
        matchingAll tokens: [String]
    ) throws -> AudioUnitParameterID? {
        let normalizedTokens = tokens.map { $0.lowercased() }
        let normalizedPreferredNames = preferredNames.map(normalizeParameterName)
        var fallbackMatch: AudioUnitParameterID?

        for parameterID in parameterIDs {
            let parameterName = try parameterDisplayName(for: parameterID, in: unit)
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

    private static func parameterDisplayName(
        for parameterID: AudioUnitParameterID,
        in unit: AudioUnit
    ) throws -> String {
        var parameterInfo = AudioUnitParameterInfo()
        var propertySize = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
        try checkStatus(
            AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_ParameterInfo,
                kAudioUnitScope_Global,
                parameterID,
                &parameterInfo,
                &propertySize
            ),
            "Failed to read Audio Unit parameter info"
        )

        return withUnsafePointer(to: parameterInfo.name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: parameterInfo.name)) { namePointer in
                String(cString: namePointer)
            }
        }
    }

    private static func displayedParameterValue(
        for parameterID: AudioUnitParameterID,
        in unit: AudioUnit
    ) throws -> Float {
        if let displayString = try parameterString(for: parameterID, in: unit),
           let displayValue = parseLeadingFloat(from: displayString) {
            return displayValue
        }

        var rawValue = AudioUnitParameterValue(0)
        try checkStatus(
            AudioUnitGetParameter(
                unit,
                parameterID,
                kAudioUnitScope_Global,
                0,
                &rawValue
            ),
            "Failed to read the Audio Unit parameter value"
        )
        return Float(rawValue)
    }

    static func parameterValue(
        for parameterID: AudioUnitParameterID,
        displayValue: Float,
        in unit: AudioUnit
    ) throws -> AudioUnitParameterValue {
        for candidate in parameterValueStringCandidates(for: displayValue) {
            if let resolvedValue = try parameterValue(
                for: parameterID,
                string: candidate,
                in: unit
            ) {
                return resolvedValue
            }
        }

        return AudioUnitParameterValue(displayValue)
    }

    private static func parameterString(
        for parameterID: AudioUnitParameterID,
        in unit: AudioUnit
    ) throws -> String? {
        var currentValue = AudioUnitParameterValue(0)
        try checkStatus(
            AudioUnitGetParameter(
                unit,
                parameterID,
                kAudioUnitScope_Global,
                0,
                &currentValue
            ),
            "Failed to read the Audio Unit parameter value"
        )

        return try withUnsafePointer(to: &currentValue) { valuePointer in
            var request = AudioUnitParameterStringFromValue(
                inParamID: parameterID,
                inValue: valuePointer,
                outString: nil
            )
            var propertySize = UInt32(MemoryLayout<AudioUnitParameterStringFromValue>.size)
            try checkStatus(
                AudioUnitGetProperty(
                    unit,
                    kAudioUnitProperty_ParameterStringFromValue,
                    kAudioUnitScope_Global,
                    0,
                    &request,
                    &propertySize
                ),
                "Failed to format the Audio Unit parameter value"
            )

            guard let outString = request.outString else { return nil }
            return outString.takeRetainedValue() as String
        }
    }

    private static func parameterValue(
        for parameterID: AudioUnitParameterID,
        string: String,
        in unit: AudioUnit
    ) throws -> AudioUnitParameterValue? {
        let cfString = string as CFString
        var request = AudioUnitParameterValueFromString(
            inParamID: parameterID,
            inString: Unmanaged.passUnretained(cfString),
            outValue: 0
        )
        var propertySize = UInt32(MemoryLayout<AudioUnitParameterValueFromString>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_ParameterValueFromString,
            kAudioUnitScope_Global,
            0,
            &request,
            &propertySize
        )

        guard status == noErr else { return nil }
        return request.outValue
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

    private static func parseLeadingFloat(from string: String) -> Float? {
        let scanner = Scanner(string: string)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        return scanner.scanFloat()
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
        try applyToWavesTuneRealtimeUnits { plugin in
            var bypassedValue: UInt32 = isBypassed ? 1 : 0
            try checkStatus(
                AudioUnitSetProperty(
                    plugin.unit,
                    kAudioUnitProperty_BypassEffect,
                    kAudioUnitScope_Global,
                    0,
                    &bypassedValue,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                "Failed to update Waves Tune bypass"
            )
        }
    }

    func applyWavesTuneRealtimeKeySelection(_ selection: WavesTuneKeySelection) throws -> Int {
        let normalizedSelection = selection.normalized
        return try applyToWavesTuneRealtimeUnits { plugin in
            try checkStatus(
                AudioUnitSetParameter(
                    plugin.unit,
                    WavesTuneRealtimeParameterMap.scaleTypeParameterID,
                    kAudioUnitScope_Global,
                    0,
                    AudioUnitParameterValue(normalizedSelection.pluginScaleTypeValue),
                    0
                ),
                "Failed to update the Waves Tune scale type"
            )
            try checkStatus(
                AudioUnitSetParameter(
                    plugin.unit,
                    WavesTuneRealtimeParameterMap.scaleRootParameterID,
                    kAudioUnitScope_Global,
                    0,
                    AudioUnitParameterValue(normalizedSelection.pluginScaleRootValue),
                    0
                ),
                "Failed to update the Waves Tune scale root"
            )
        }
    }

    func applyWavesTuneRealtimeStrength(_ strength: WavesTuneStrengthPreset) throws -> Int {
        guard let speed = strength.speed,
              let noteTransition = strength.noteTransition else {
            return 0
        }

        return try applyToWavesTuneRealtimeUnits { plugin in
            let parameterIDs = try WavesTuneRealtimeParameterMap.resolveStrengthParameterIDs(for: plugin.unit)
            let speedValue = try WavesTuneRealtimeParameterMap.parameterValue(
                for: parameterIDs.speed,
                displayValue: speed,
                in: plugin.unit
            )
            let noteTransitionValue = try WavesTuneRealtimeParameterMap.parameterValue(
                for: parameterIDs.noteTransition,
                displayValue: noteTransition,
                in: plugin.unit
            )
            try checkStatus(
                AudioUnitSetParameter(
                    plugin.unit,
                    parameterIDs.speed,
                    kAudioUnitScope_Global,
                    0,
                    speedValue,
                    0
                ),
                "Failed to update the Waves Tune Speed parameter"
            )
            try checkStatus(
                AudioUnitSetParameter(
                    plugin.unit,
                    parameterIDs.noteTransition,
                    kAudioUnitScope_Global,
                    0,
                    noteTransitionValue,
                    0
                ),
                "Failed to update the Waves Tune Note Transition parameter"
            )
        }
    }

    func currentWavesTuneRealtimeStrengthPreset() throws -> WavesTuneStrengthPreset? {
        var resolvedPreset: WavesTuneStrengthPreset?

        for plugin in plugins where WavesTuneRealtimeParameterMap.matches(plugin.plugin) {
            let values = try WavesTuneRealtimeParameterMap.strengthValues(for: plugin.unit)
            let preset = WavesTuneStrengthPreset.matchingDisplayValues(
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

    private func applyToWavesTuneRealtimeUnits(
        _ body: (PluginRuntime) throws -> Void
    ) throws -> Int {
        var affectedUnits = 0

        for plugin in plugins where WavesTuneRealtimeParameterMap.matches(plugin.plugin) {
            try body(plugin)
            affectedUnits += 1
        }

        return affectedUnits
    }
}
