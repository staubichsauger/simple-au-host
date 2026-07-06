@preconcurrency import AudioToolbox
import Foundation

protocol PluginParameterControl {
    var pluginInfo: AudioUnitPluginInfo { get }

    func setBypass(_ isBypassed: Bool, failureMessage: String) throws
    func setParameter(
        _ parameterID: AudioUnitParameterID,
        value: AudioUnitParameterValue,
        failureMessage: String
    ) throws
    func availableParameterIDs() throws -> [AudioUnitParameterID]
    func parameterDisplayName(for parameterID: AudioUnitParameterID) throws -> String
    func displayedParameterValue(for parameterID: AudioUnitParameterID) throws -> Float
    func parameterValue(
        for parameterID: AudioUnitParameterID,
        string: String
    ) throws -> AudioUnitParameterValue?
}

extension MultiTrackAudioHostController.TrackRuntime.PluginRuntime: PluginParameterControl {
    var pluginInfo: AudioUnitPluginInfo {
        plugin
    }

    func setBypass(_ isBypassed: Bool, failureMessage: String) throws {
        var bypassedValue: UInt32 = isBypassed ? 1 : 0
        try checkStatus(
            AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_BypassEffect,
                kAudioUnitScope_Global,
                0,
                &bypassedValue,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            failureMessage
        )
    }

    func setParameter(
        _ parameterID: AudioUnitParameterID,
        value: AudioUnitParameterValue,
        failureMessage: String
    ) throws {
        try checkStatus(
            AudioUnitSetParameter(
                unit,
                parameterID,
                kAudioUnitScope_Global,
                0,
                value,
                0
            ),
            failureMessage
        )
    }

    func availableParameterIDs() throws -> [AudioUnitParameterID] {
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

    func parameterDisplayName(for parameterID: AudioUnitParameterID) throws -> String {
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

    func displayedParameterValue(for parameterID: AudioUnitParameterID) throws -> Float {
        if let displayString = try parameterString(for: parameterID),
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

    func parameterValue(
        for parameterID: AudioUnitParameterID,
        string: String
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

    private func parameterString(for parameterID: AudioUnitParameterID) throws -> String? {
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

    private func parseLeadingFloat(from string: String) -> Float? {
        let scanner = Scanner(string: string)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        return scanner.scanFloat()
    }
}
