import SwiftUI

struct EngineStartFailureAlertModifier: ViewModifier {
    @ObservedObject var viewModel: MultiTrackViewModel

    func body(content: Content) -> some View {
        content.alert(
            "Engine Failed to Start",
            isPresented: Binding(
                get: { viewModel.startFailureAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.startFailureAlert = nil
                    }
                }
            ),
            presenting: viewModel.startFailureAlert
        ) { _ in
            Button("OK", role: .cancel) {
                viewModel.startFailureAlert = nil
            }
        } message: { alert in
            Text(alert.message)
        }
    }
}
