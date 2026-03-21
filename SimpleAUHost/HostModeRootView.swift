import SwiftUI

enum HostModeChoice {
    case simple
    case multiTrack
}

struct HostModeRootView: View {
    @State private var selectedMode: HostModeChoice?

    var body: some View {
        Group {
            switch selectedMode {
            case .simple:
                ContentView {
                    selectedMode = nil
                }
            case .multiTrack:
                MultiTrackView {
                    selectedMode = nil
                }
            case nil:
                HostModeSelectionView { mode in
                    selectedMode = mode
                }
            }
        }
    }
}

private struct HostModeSelectionView: View {
    let onSelect: (HostModeChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose startup mode")
                    .font(.largeTitle.weight(.semibold))
                Text("Simple mode keeps the original single-path host. Multi track mode adds mono/stereo tracks, per-track mapping, and three latency classes.")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 20) {
                ModeCard(
                    title: "Simple mode",
                    description: "One input path, one output path, one inserted Audio Unit, and one hardware-oriented buffer setting.",
                    buttonTitle: "Open simple mode"
                ) {
                    onSelect(.simple)
                }

                ModeCard(
                    title: "Multi track mode",
                    description: "Multiple mono/stereo tracks with per-track input/output mapping and latency class selection.",
                    buttonTitle: "Open multi track mode"
                ) {
                    onSelect(.multiTrack)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ModeCard: View {
    let title: String
    let description: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(description)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
