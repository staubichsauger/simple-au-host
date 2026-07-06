@preconcurrency import AudioToolbox
import AppKit
import Foundation

@objc(AUCocoaUIBase)
private protocol AUCocoaUIViewFactory: NSObjectProtocol {
    @objc(interfaceVersion)
    func interfaceVersion() -> UInt32

    @objc(uiViewForAudioUnit:withSize:)
    func uiViewForAudioUnit(_ audioUnit: AudioUnit, withSize size: NSSize) -> NSView?
}

extension MultiTrackAudioHostController {
    @MainActor
    final class HostedPluginEditorSession {
        let viewController: NSViewController
        private let onInvalidate: () -> Void

        init(
            viewController: NSViewController,
            onInvalidate: @escaping () -> Void = {}
        ) {
            self.viewController = viewController
            self.onInvalidate = onInvalidate
        }

        func invalidate() {
            onInvalidate()
        }
    }

    @MainActor
    final class PluginEditorWindowController: NSWindowController, NSWindowDelegate {
        let trackID: UUID
        var onClose: (() -> Void)?

        init(trackID: UUID, title: String, contentViewController: NSViewController) {
            self.trackID = trackID
            let contentView = contentViewController.view
            let fittingSize = contentView.fittingSize
            let contentSize = NSSize(width: max(520, fittingSize.width), height: max(420, fittingSize.height))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.center()
            window.contentViewController = contentViewController
            super.init(window: window)
            window.delegate = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        func windowWillClose(_ notification: Notification) {
            onClose?()
        }
    }

}

@MainActor
private final class NativePluginEditorRequest {
    typealias RequestViewControllerBlock = @convention(block) (NSViewController?) -> Void

    let id = UUID()
    private var continuation: CheckedContinuation<NSViewController?, Error>?
    private var timeoutTask: Task<Void, Never>?
    private(set) var callbackObject: AnyObject?

    init(continuation: CheckedContinuation<NSViewController?, Error>) {
        self.continuation = continuation
    }

    func installCallback(_ callback: @escaping RequestViewControllerBlock) {
        callbackObject = unsafeBitCast(callback, to: AnyObject.self)
    }

    func startTimeout(seconds: Double) {
        timeoutTask = Task { [id] in
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                PluginEditorFactory.completeNativeEditorRequest(
                    id,
                    result: .failure(AudioHostError("Timed out while waiting for the plugin editor."))
                )
            }
        }
    }

    func complete(result: Result<NSViewController?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        callbackObject = nil

        switch result {
        case .success(let viewController):
            continuation.resume(returning: viewController)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
private enum PluginEditorFactory {
    private static var pendingNativePluginEditorRequests: [UUID: NativePluginEditorRequest] = [:]

    @MainActor
    static func requestPluginEditorViewController(for effectUnit: AudioUnit) async throws -> NSViewController {
        if let nativeViewController = try await Self.requestNativeViewController(for: effectUnit) {
            return nativeViewController
        }
        if let cocoaViewController = try Self.makeCocoaPluginEditorViewController(for: effectUnit) {
            return cocoaViewController
        }
        throw AudioHostError("This plugin does not provide a host-openable editor on its live processing instance.")
    }

    @MainActor
    static func requestNativeViewController(for effectUnit: AudioUnit) async throws -> NSViewController? {
        try await withCheckedThrowingContinuation { continuation in
            let request = NativePluginEditorRequest(continuation: continuation)
            pendingNativePluginEditorRequests[request.id] = request

            let requestID = request.id
            let callback: NativePluginEditorRequest.RequestViewControllerBlock = { viewController in
                Task { @MainActor in
                    completeNativeEditorRequest(requestID, result: .success(viewController))
                }
            }
            request.installCallback(callback)
            guard let callbackObject = request.callbackObject else {
                completeNativeEditorRequest(
                    requestID,
                    result: .failure(AudioHostError("Failed to prepare the plugin editor callback."))
                )
                return
            }
            request.startTimeout(seconds: 5)
            var unmanagedCallbackObject = Unmanaged.passUnretained(callbackObject)

            let status = withExtendedLifetime(callbackObject) {
                AudioUnitSetProperty(
                    effectUnit,
                    kAudioUnitProperty_RequestViewController,
                    kAudioUnitScope_Global,
                    0,
                    &unmanagedCallbackObject,
                    UInt32(MemoryLayout<Unmanaged<AnyObject>>.size)
                )
            }

            if status != noErr {
                if status == kAudioUnitErr_InvalidProperty {
                    completeNativeEditorRequest(requestID, result: .success(nil))
                } else {
                    completeNativeEditorRequest(
                        requestID,
                        result: .failure(AudioHostError("Failed to request the plugin editor (\(describe(status: status)))."))
                    )
                }
            }
        }
    }

    @MainActor
    static func completeNativeEditorRequest(
        _ id: UUID,
        result: Result<NSViewController?, Error>
    ) {
        guard let request = pendingNativePluginEditorRequests.removeValue(forKey: id) else { return }
        request.complete(result: result)
    }

    @MainActor
    static func makeCocoaPluginEditorViewController(for effectUnit: AudioUnit) throws -> NSViewController? {
        var dataSize: UInt32 = 0
        let infoStatus = AudioUnitGetPropertyInfo(
            effectUnit,
            kAudioUnitProperty_CocoaUI,
            kAudioUnitScope_Global,
            0,
            &dataSize,
            nil
        )

        guard infoStatus == noErr,
              dataSize >= UInt32(MemoryLayout<UnsafeRawPointer?>.size + MemoryLayout<CFString?>.size) else {
            return nil
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment
        )
        defer { rawBuffer.deallocate() }

        var propertySize = dataSize
        try checkStatus(
            AudioUnitGetProperty(
                effectUnit,
                kAudioUnitProperty_CocoaUI,
                kAudioUnitScope_Global,
                0,
                rawBuffer,
                &propertySize
            ),
            "Failed to load the plugin Cocoa editor"
        )

        let bundleURLPointer = rawBuffer.assumingMemoryBound(to: Optional<CFURL>.self)
        guard let bundleURL = bundleURLPointer.pointee as URL?,
              let bundle = Bundle(url: bundleURL) else {
            throw AudioHostError("The plugin Cocoa editor bundle could not be loaded.")
        }

        do {
            try bundle.loadAndReturnError()
        } catch {
            throw AudioHostError("The plugin Cocoa editor bundle failed to load: \(error.localizedDescription)")
        }

        let classPointerOffset = MemoryLayout<UnsafeRawPointer?>.size
        let classCount = max(0, (Int(propertySize) - classPointerOffset) / MemoryLayout<CFString?>.size)
        let classNamesPointer = rawBuffer.advanced(by: classPointerOffset).assumingMemoryBound(to: Optional<CFString>.self)
        var attemptedClassNames: [String] = []

        for index in 0..<classCount {
            guard let className = classNamesPointer.advanced(by: index).pointee as String? else {
                continue
            }
            attemptedClassNames.append(className)
            if let viewController = makeCocoaPluginEditorViewController(
                bundle: bundle,
                className: className,
                effectUnit: effectUnit
            ) {
                return viewController
            }
        }

        if let principalClassName = bundle.principalClass.map(NSStringFromClass),
           !attemptedClassNames.contains(principalClassName),
           let viewController = makeCocoaPluginEditorViewController(
               bundle: bundle,
               className: principalClassName,
               effectUnit: effectUnit
           ) {
            return viewController
        }

        let attemptedDescription = attemptedClassNames.isEmpty ? "none" : attemptedClassNames.joined(separator: ", ")
        let principalDescription = bundle.principalClass.map(NSStringFromClass) ?? "none"
        throw AudioHostError(
            "The plugin advertises a Cocoa editor bundle, but no view factory could be created. " +
            "Classes tried: \(attemptedDescription). Principal class: \(principalDescription)."
        )
    }

    @MainActor
    static func makeCocoaPluginEditorViewController(
        bundle: Bundle,
        className: String,
        effectUnit: AudioUnit
    ) -> NSViewController? {
        guard let factoryType = (bundle.classNamed(className) ?? NSClassFromString(className)) as? NSObject.Type,
              let factory = factoryType.init() as? AUCocoaUIViewFactory,
              let view = factory.uiViewForAudioUnit(effectUnit, withSize: NSSize(width: 720, height: 540)) else {
            return nil
        }

        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = NSView.AutoresizingMask(arrayLiteral: .width, .height)
        let viewController = NSViewController()
        viewController.view = view
        return viewController
    }
}

extension MultiTrackAudioHostController.TrackRuntime {
    @MainActor
    func makePluginEditorSession(pluginID: UUID?) async throws -> MultiTrackAudioHostController.HostedPluginEditorSession {
        let pluginRuntime: PluginRuntime
        if let pluginID {
            guard let resolvedPlugin = plugins.first(where: { $0.insert.id == pluginID }) else {
                throw AudioHostError("This plugin insert is not loaded on the running track.")
            }
            pluginRuntime = resolvedPlugin
        } else if let firstPlugin = plugins.first {
            pluginRuntime = firstPlugin
        } else {
            throw AudioHostError("This track does not have a plugin loaded.")
        }
        let viewController = try await PluginEditorFactory.requestPluginEditorViewController(for: pluginRuntime.unit)
        return MultiTrackAudioHostController.HostedPluginEditorSession(viewController: viewController)
    }

}
