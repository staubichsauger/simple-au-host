import SwiftUI

@main
struct SimpleAUHostApp: App {
    var body: some Scene {
        WindowGroup {
            HostModeRootView()
                .frame(minWidth: 720, minHeight: 680)
        }
        .defaultSize(width: 720, height: 680)
        .windowResizability(.contentSize)
    }
}
