import AudioToolbox
import CoreAudio
import Foundation

typealias AudioDeviceID = AudioObjectID

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannelCount: Int
    let outputChannelCount: Int
    let nominalSampleRate: Double
    let currentBufferSize: Int
    let bufferSizeRange: ClosedRange<Int>

    var displayName: String {
        "\(name) — \(Int(nominalSampleRate)) Hz"
    }
}

struct AudioUnitPluginInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let componentDescription: AudioComponentDescription

    static func == (lhs: AudioUnitPluginInfo, rhs: AudioUnitPluginInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct AudioHostError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

struct LatencyClassTelemetrySnapshot {
    let trackCount: Int
    let workerShardCount: Int
    let peakTrackRenderDurationMicros: UInt64
    let averageTrackRenderDurationMicros: UInt64
    let peakShardRenderDurationMicros: UInt64
    let averageShardRenderDurationMicros: UInt64
    let peakShardUtilizationPercent: UInt64
    let peakWorkerWakeupsPerSecond: UInt64

    static let zero = LatencyClassTelemetrySnapshot(
        trackCount: 0,
        workerShardCount: 0,
        peakTrackRenderDurationMicros: 0,
        averageTrackRenderDurationMicros: 0,
        peakShardRenderDurationMicros: 0,
        averageShardRenderDurationMicros: 0,
        peakShardUtilizationPercent: 0,
        peakWorkerWakeupsPerSecond: 0
    )
}

struct AudioEngineTelemetrySnapshot {
    let peakInputCallbackFrames: UInt64
    let peakOutputCallbackFrames: UInt64
    let peakEffectRenderFrames: UInt64
    let peakInputRingOccupancyFrames: UInt64
    let peakOutputRingOccupancyFrames: UInt64
    let inputRingCapacityFrames: Int
    let outputRingCapacityFrames: Int
    let peakTrackRenderDurationMicros: UInt64
    let averageTrackRenderDurationMicros: UInt64
    let peakShardRenderDurationMicros: UInt64
    let averageShardRenderDurationMicros: UInt64
    let peakShardUtilizationPercent: UInt64
    let peakWorkerWakeupsPerSecond: UInt64
    let workerShardCount: Int
    let realtime: LatencyClassTelemetrySnapshot
    let buffered: LatencyClassTelemetrySnapshot
    let broadcast: LatencyClassTelemetrySnapshot

    static let zero = AudioEngineTelemetrySnapshot(
        peakInputCallbackFrames: 0,
        peakOutputCallbackFrames: 0,
        peakEffectRenderFrames: 0,
        peakInputRingOccupancyFrames: 0,
        peakOutputRingOccupancyFrames: 0,
        inputRingCapacityFrames: 0,
        outputRingCapacityFrames: 0,
        peakTrackRenderDurationMicros: 0,
        averageTrackRenderDurationMicros: 0,
        peakShardRenderDurationMicros: 0,
        averageShardRenderDurationMicros: 0,
        peakShardUtilizationPercent: 0,
        peakWorkerWakeupsPerSecond: 0,
        workerShardCount: 0,
        realtime: .zero,
        buffered: .zero,
        broadcast: .zero
    )
}

final class AudioHostController: @unchecked Sendable {
    private static let pluginCatalogLock = NSLock()
    private nonisolated(unsafe) static var cachedPlugins: [AudioUnitPluginInfo]?

    func availableDevices() throws -> [AudioDeviceInfo] {
        let devices: [AudioDeviceID] = try getAudioObjectProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )

        return devices.compactMap { deviceID in
            do {
                let name = try getCFStringProperty(
                    objectID: deviceID,
                    selector: kAudioObjectPropertyName,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain
                )
                let uid = try getCFStringProperty(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyDeviceUID,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain
                )
                let inputChannels = try channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
                let outputChannels = try channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
                let sampleRate: Float64 = try getAudioObjectScalarProperty(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyNominalSampleRate,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain
                )
                let currentBufferSize: UInt32 = try getAudioObjectScalarProperty(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyBufferFrameSize,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain
                )
                let range: AudioValueRange = try getAudioObjectScalarProperty(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyBufferFrameSizeRange,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain
                )

                return AudioDeviceInfo(
                    id: deviceID,
                    uid: uid,
                    name: name,
                    inputChannelCount: inputChannels,
                    outputChannelCount: outputChannels,
                    nominalSampleRate: sampleRate,
                    currentBufferSize: Int(currentBufferSize),
                    bufferSizeRange: Int(range.mMinimum)...Int(range.mMaximum)
                )
            } catch {
                NSLog("Skipping unavailable Core Audio device \(deviceID): \(error.localizedDescription)")
                return nil
            }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func availablePlugins() throws -> [AudioUnitPluginInfo] {
        Self.pluginCatalogLock.lock()
        if let cachedPlugins = Self.cachedPlugins {
            Self.pluginCatalogLock.unlock()
            return cachedPlugins
        }
        Self.pluginCatalogLock.unlock()

        var plugins: [AudioUnitPluginInfo] = []
        var seenIDs = Set<String>()

        for componentType in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            var searchDescription = AudioComponentDescription(
                componentType: componentType,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            var currentComponent: AudioComponent?
            while true {
                let nextComponent = AudioComponentFindNext(currentComponent, &searchDescription)
                guard let component = nextComponent else { break }

                var description = AudioComponentDescription()
                try checkStatus(
                    AudioComponentGetDescription(component, &description),
                    "Failed to read Audio Unit description"
                )

                var nameRef: Unmanaged<CFString>?
                try checkStatus(
                    AudioComponentCopyName(component, &nameRef),
                    "Failed to read Audio Unit name"
                )
                let rawName = nameRef?.takeRetainedValue() as String? ?? "Unknown Audio Unit"
                let pluginID = [
                    String(description.componentType),
                    String(description.componentSubType),
                    String(description.componentManufacturer)
                ].joined(separator: ":")

                if seenIDs.insert(pluginID).inserted {
                    plugins.append(
                        AudioUnitPluginInfo(
                            id: pluginID,
                            name: rawName,
                            componentDescription: description
                        )
                    )
                }

                currentComponent = component
            }
        }

        let sortedPlugins = plugins.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Self.pluginCatalogLock.lock()
        Self.cachedPlugins = sortedPlugins
        Self.pluginCatalogLock.unlock()
        return sortedPlugins
    }

    func defaultInputDeviceID() throws -> AudioDeviceID {
        try getAudioObjectScalarProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID {
        try getAudioObjectScalarProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
    }

    private func channelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        try checkStatus(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            "Failed to inspect device stream configuration"
        )

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        try checkStatus(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer),
            "Failed to read device stream configuration"
        )

        let bufferList = UnsafeMutableAudioBufferListPointer(
            rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        )

        return bufferList.reduce(into: 0) { partialResult, buffer in
            partialResult += Int(buffer.mNumberChannels)
        }
    }
}

func getAudioObjectProperty<T>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) throws -> [T] {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )

    var dataSize: UInt32 = 0
    try checkStatus(
        AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize),
        "Failed to inspect Core Audio property"
    )

    let count = Int(dataSize) / MemoryLayout<T>.stride
    if count == 0 {
        return []
    }
    var values = Array<T>(unsafeUninitializedCapacity: count) { _, initializedCount in
        initializedCount = count
    }

    try values.withUnsafeMutableBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            throw AudioHostError("Failed to read Core Audio property.")
        }
        try checkStatus(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, baseAddress),
            "Failed to read Core Audio property"
        )
    }

    return values
}

func getAudioObjectScalarProperty<T>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) throws -> T {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { pointer.deallocate() }

    var dataSize = UInt32(MemoryLayout<T>.size)
    try checkStatus(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer),
        "Failed to read Core Audio scalar property"
    )

    return pointer.move()
}

func getCFStringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )
    var value: CFString?
    var dataSize = UInt32(MemoryLayout<CFString?>.size)

    try checkStatus(
        withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        },
        "Failed to read Core Audio string property"
    )

    return (value as String?) ?? "Unknown"
}

@discardableResult
func checkStatus(_ status: OSStatus, _ message: String) throws -> OSStatus {
    guard status == noErr else {
        throw AudioHostError("\(message) (\(describe(status: status))).")
    }
    return status
}

func describe(status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let chars = [
        Character(UnicodeScalar((n >> 24) & 0xFF)!),
        Character(UnicodeScalar((n >> 16) & 0xFF)!),
        Character(UnicodeScalar((n >> 8) & 0xFF)!),
        Character(UnicodeScalar(n & 0xFF)!)
    ]
    let fourCC = String(chars)
    if fourCC.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) {
        return "'\(fourCC)'"
    }
    return String(status)
}

final class AudioHostingPriorityController {
    private var activityToken: NSObjectProtocol?

    func activate(reason: String) {
        guard activityToken == nil else { return }

        var options: ProcessInfo.ActivityOptions = [
            .userInitiatedAllowingIdleSystemSleep,
            .suddenTerminationDisabled,
            .automaticTerminationDisabled
        ]
        options.insert(.latencyCritical)
        activityToken = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    }

    func deactivate() {
        guard let activityToken else { return }
        ProcessInfo.processInfo.endActivity(activityToken)
        self.activityToken = nil
    }
}

final class AudioWorkerWakeup {
    private var mutex = pthread_mutex_t()
    private var condition = pthread_cond_t()
    private var isSignaled = false

    init() {
        pthread_mutex_init(&mutex, nil)
        pthread_cond_init(&condition, nil)
    }

    deinit {
        pthread_cond_destroy(&condition)
        pthread_mutex_destroy(&mutex)
    }

    func signal() {
        pthread_mutex_lock(&mutex)
        isSignaled = true
        pthread_cond_signal(&condition)
        pthread_mutex_unlock(&mutex)
    }

    func wait() {
        pthread_mutex_lock(&mutex)
        while !isSignaled {
            pthread_cond_wait(&condition, &mutex)
        }
        isSignaled = false
        pthread_mutex_unlock(&mutex)
    }
}

final class AudioHardwareChangeObserver {
    private let queue = DispatchQueue(label: "SimpleAUHost.AudioHardwareChangeObserver")
    private var registrations: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func startMonitoring(deviceIDs: [AudioDeviceID], onChange: @escaping (String) -> Void) {
        stop()

        let addresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ]

        for deviceID in Set(deviceIDs) {
            for address in addresses {
                var propertyAddress = address
                let block: AudioObjectPropertyListenerBlock = { _, _ in
                    onChange("Audio stopped because the device configuration changed. Restart the engine to re-open the devices.")
                }
                let status = AudioObjectAddPropertyListenerBlock(deviceID, &propertyAddress, queue, block)
                if status == noErr {
                    registrations.append((deviceID, address, block))
                }
            }
        }
    }

    func stop() {
        for (deviceID, address, block) in registrations {
            var propertyAddress = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &propertyAddress, queue, block)
        }
        registrations.removeAll()
    }

    deinit {
        stop()
    }
}

func clearAudioBuffer(_ pointer: UnsafeMutablePointer<Float>, frameCount: Int) {
    guard frameCount > 0 else { return }
    memset(pointer, 0, frameCount * MemoryLayout<Float>.size)
}

func suggestedMaximumFramesPerSlice(for processingFrames: Int, nominalBufferSize: Int) -> Int {
    max(processingFrames, nominalBufferSize * 4)
}

func allocatedFrameCapacity(actualMaximumFrames: Int, nominalBufferSize: Int) -> Int {
    max(actualMaximumFrames, nominalBufferSize) + nominalBufferSize
}

func promoteCurrentThreadToAudioWorkerQoS(_ qosClass: qos_class_t = QOS_CLASS_USER_INITIATED) {
    pthread_set_qos_class_self_np(qosClass, 0)
}
