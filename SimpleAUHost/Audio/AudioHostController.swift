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

extension Notification.Name {
    /// Posted by AudioToolbox when Audio Unit components are registered or
    /// unregistered while the app runs.
    static let audioComponentRegistrationsChanged = Notification.Name(
        kAudioComponentRegistrationsChangedNotification as String
    )
}

final class AudioHostController: @unchecked Sendable {
    private static let pluginCatalogLock = NSLock()
    private nonisolated(unsafe) static var cachedPlugins: [AudioUnitPluginInfo]?
    /// Clears the plugin catalog cache whenever the system's Audio Unit
    /// registrations change, so newly installed (or removed) plugins are picked
    /// up without an app restart. Lazily registered on first catalog access.
    /// `nonisolated(unsafe)` is acceptable: the token is written once during
    /// lazy static initialization and only ever read to force registration.
    private nonisolated(unsafe) static let registrationsChangedObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: .audioComponentRegistrationsChanged,
        object: nil,
        queue: nil
    ) { _ in
        AudioHostController.invalidatePluginCache()
    }

    static func invalidatePluginCache() {
        pluginCatalogLock.lock()
        cachedPlugins = nil
        pluginCatalogLock.unlock()
    }

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
        _ = Self.registrationsChangedObserver
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

/// Owns heap-allocated pthread primitives so they always operate on stable
/// addresses. Passing class stored properties inout (`&mutex`) to C is not
/// guaranteed to pin the property's address and is unsupported for
/// `pthread_mutex_t`/`pthread_cond_t`.
///
/// The mutex uses `PTHREAD_PRIO_INHERIT` because `signal()` is called from the
/// realtime audio callbacks: without priority inheritance the realtime thread
/// could block behind a preempted lower-priority worker holding the mutex
/// (priority inversion → audible dropout).
final class AudioWorkerWakeup {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t> = .allocate(capacity: 1)
    private let condition: UnsafeMutablePointer<pthread_cond_t> = .allocate(capacity: 1)
    private var isSignaled = false

    init() {
        mutex.initialize(to: pthread_mutex_t())
        condition.initialize(to: pthread_cond_t())
        var mutexAttributes = pthread_mutexattr_t()
        pthread_mutexattr_init(&mutexAttributes)
        pthread_mutexattr_setprotocol(&mutexAttributes, PTHREAD_PRIO_INHERIT)
        pthread_mutex_init(mutex, &mutexAttributes)
        pthread_mutexattr_destroy(&mutexAttributes)
        pthread_cond_init(condition, nil)
    }

    deinit {
        pthread_cond_destroy(condition)
        pthread_mutex_destroy(mutex)
        condition.deinitialize(count: 1)
        mutex.deinitialize(count: 1)
        condition.deallocate()
        mutex.deallocate()
    }

    func signal() {
        pthread_mutex_lock(mutex)
        isSignaled = true
        pthread_cond_signal(condition)
        pthread_mutex_unlock(mutex)
    }

    func wait() {
        pthread_mutex_lock(mutex)
        while !isSignaled {
            pthread_cond_wait(condition, mutex)
        }
        isSignaled = false
        pthread_mutex_unlock(mutex)
    }
}

/// Owns a heap-allocated `SAHAtomicCounter` so its `_Atomic` value always has a
/// stable shared address. Do not pass class stored properties inout to the C
/// atomics API — Swift may materialize a temporary copy.
final class AtomicCounter: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<SAHAtomicCounter>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: SAHAtomicCounter())
        SAHAtomicCounterReset(pointer)
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always)
    func reset() {
        SAHAtomicCounterReset(pointer)
    }

    @inline(__always)
    func load() -> UInt64 {
        SAHAtomicCounterLoad(pointer)
    }

    @inline(__always)
    func increment() {
        SAHAtomicCounterIncrement(pointer)
    }

    @inline(__always)
    func add(_ amount: UInt64) {
        SAHAtomicCounterAdd(pointer, amount)
    }

    @inline(__always)
    func storeMax(_ candidate: UInt64) {
        SAHAtomicCounterStoreMax(pointer, candidate)
    }
}

/// Owns a heap-allocated `SAHFloatRingBuffer` so its `_Atomic` read/write
/// indices always share one stable address across the producer and consumer
/// threads. See `AtomicCounter` for why inout access is not safe.
final class FloatRingBuffer: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<SAHFloatRingBuffer>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: SAHFloatRingBuffer())
    }

    deinit {
        SAHFloatRingBufferDeinit(pointer)
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    var capacity: UInt32 {
        pointer.pointee.capacity
    }

    @discardableResult
    func initialize(minimumCapacity: UInt32) -> Bool {
        SAHFloatRingBufferInit(pointer, minimumCapacity)
    }

    @inline(__always)
    func clear() {
        SAHFloatRingBufferClear(pointer)
    }

    @inline(__always)
    func availableRead() -> UInt32 {
        SAHFloatRingBufferAvailableRead(pointer)
    }

    @inline(__always)
    func availableWrite() -> UInt32 {
        SAHFloatRingBufferAvailableWrite(pointer)
    }

    @inline(__always)
    func read(into output: UnsafeMutablePointer<Float>, count: UInt32) -> UInt32 {
        SAHFloatRingBufferRead(pointer, output, count)
    }

    @inline(__always)
    func write(from input: UnsafePointer<Float>, count: UInt32) -> UInt32 {
        SAHFloatRingBufferWrite(pointer, input, count)
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
