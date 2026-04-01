import AppKit
import SwiftUI

@MainActor
final class AppCloseCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    struct Handler {
        let hasUnsavedChanges: () -> Bool
        let documentName: () -> String
        let save: () -> Bool
    }

    private weak var observedWindow: NSWindow?
    private var allowsNextWindowClose = false
    private var handler: Handler?

    func updateHandler(_ handler: Handler?) {
        self.handler = handler
    }

    func attach(to window: NSWindow) {
        guard observedWindow !== window else { return }

        if let observedWindow, observedWindow.delegate === self {
            observedWindow.delegate = nil
        }

        observedWindow = window
        window.delegate = self
    }

    func detach(from window: NSWindow) {
        guard observedWindow === window else { return }

        if window.delegate === self {
            window.delegate = nil
        }
        observedWindow = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowsNextWindowClose {
            allowsNextWindowClose = false
            return true
        }

        return confirmClose()
    }

    func confirmApplicationTermination() -> NSApplication.TerminateReply {
        confirmClose() ? .terminateNow : .terminateCancel
    }

    private func confirmClose() -> Bool {
        guard let handler, handler.hasUnsavedChanges() else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "The show \"\(handler.documentName())\" has unsaved changes."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Ignore")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return handler.save()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func closeWindowAfterConfirmation() {
        guard let observedWindow else { return }
        allowsNextWindowClose = true
        observedWindow.performClose(nil)
    }
}

final class SimpleAUHostAppDelegate: NSObject, NSApplicationDelegate {
    weak var closeCoordinator: AppCloseCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        closeCoordinator?.confirmApplicationTermination() ?? .terminateNow
    }
}

struct MainWindowObserver: NSViewRepresentable {
    let closeCoordinator: AppCloseCoordinator

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.closeCoordinator = closeCoordinator
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.closeCoordinator = closeCoordinator
        nsView.syncObservedWindow()
    }
}

final class WindowObserverView: NSView {
    weak var closeCoordinator: AppCloseCoordinator?
    private weak var trackedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncObservedWindow()
    }

    func syncObservedWindow() {
        if let trackedWindow, trackedWindow !== window {
            closeCoordinator?.detach(from: trackedWindow)
        }

        trackedWindow = window

        if let window {
            closeCoordinator?.attach(to: window)
        }
    }
}
