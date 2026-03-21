import SwiftUI

@main
struct SimpleAUHostApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 680)
        }
        .defaultSize(width: 720, height: 680)
        .windowResizability(.contentSize)
    }
}
