import SwiftUI

@main
struct SimpleAUHostApp: App {
    @NSApplicationDelegateAdaptor(SimpleAUHostAppDelegate.self) private var appDelegate
    private let closeCoordinator = AppCloseCoordinator()

    init() {
        Thread.current.qualityOfService = .userInteractive
    }

    var body: some Scene {
        WindowGroup {
            MultiTrackView(closeCoordinator: closeCoordinator)
                .frame(minWidth: 1100, minHeight: 760)
                .background(MainWindowObserver(closeCoordinator: closeCoordinator))
                .task {
                    appDelegate.closeCoordinator = closeCoordinator
                }
        }
        .defaultSize(width: 1280, height: 860)
        .windowResizability(.automatic)
    }
}
