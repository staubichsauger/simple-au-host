import SwiftUI

enum HostModeChoice {
    case simple
    case multiTrack
}

struct HostModeRootView: View {
    let closeCoordinator: AppCloseCoordinator
    @State private var selectedMode: HostModeChoice?

    var body: some View {
        Group {
            switch selectedMode {
            case .simple:
                ContentView {
                    selectedMode = nil
                }
            case .multiTrack:
                MultiTrackView(closeCoordinator: closeCoordinator) {
                    selectedMode = nil
                }
            case nil:
                HostModeSelectionView { mode in
                    selectedMode = mode
                }
            }
        }
        .onAppear {
            if selectedMode != .multiTrack {
                closeCoordinator.updateHandler(nil)
            }
        }
        .onChange(of: selectedMode) { _, mode in
            if mode != .multiTrack {
                closeCoordinator.updateHandler(nil)
            }
        }
    }
}

private struct HostModeSelectionView: View {
    let onSelect: (HostModeChoice) -> Void

    var body: some View {
        StudioShell(
            eyebrow: "Simple AU Host",
            title: "Choose Your Rack",
            subtitle: "A simplified live host inspired by hardware-style plugin racks. Pick the signal path that matches the session you want to run."
        ) {
            HStack(spacing: 10) {
                StudioBadge(title: "Direct Core Audio", systemImage: "waveform.path.ecg", tint: StudioTheme.accent)
                StudioBadge(title: "AUHAL Host", systemImage: "cable.connector", tint: .white.opacity(0.75))
            }
        } content: {
            GeometryReader { proxy in
                ScrollView {
                    Group {
                        VStack(alignment: .leading, spacing: 24) {
                            if proxy.size.width >= 1120 {
                                HStack(alignment: .top, spacing: 20) {
                                    modeCard(.simple)
                                    modeCard(.multiTrack)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 20) {
                                    modeCard(.simple)
                                    modeCard(.multiTrack)
                                }
                            }

                            StudioPanel("Available Feature Scope", subtitle: "This visual refresh only surfaces features already implemented in the engine.") {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                                    StudioMetricTile("Simple Path", value: "Single-channel hardware route with one optional effect.")
                                    StudioMetricTile("Track Rack", value: "Multiple mono/stereo tracks summed to shared hardware output.")
                                    StudioMetricTile("Buffer Control", value: "Hardware buffer plus internal worker-thread buffer settings.")
                                    StudioMetricTile("Diagnostics", value: "Dropout counters, callback telemetry, ring occupancy, worker status.")
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func modeCard(_ mode: HostModeChoice) -> some View {
        switch mode {
        case .simple:
            ModeCard(
                eyebrow: "Single Path",
                title: "Simple Mode",
                description: "One input, one output, one insert slot, optional worker-thread processing, and fast access to transport and diagnostics.",
                features: [
                    "Hardware input and output channel selection",
                    "Single insert plugin with bypass option",
                    "Worker-thread plugin render mode"
                ],
                buttonTitle: "Open Simple Rack",
                accent: StudioTheme.accent
            ) {
                onSelect(.simple)
            }
        case .multiTrack:
            ModeCard(
                eyebrow: "Split Rack",
                title: "Multi Track",
                description: "Multiple mono or stereo tracks with per-track routing, insert chains, latency class control, and session import/export.",
                features: [
                    "Independent track layout and routing",
                    "Per-track plugin chains and editor access",
                    "Realtime, buffered, or broadcast latency classes"
                ],
                buttonTitle: "Open Multi Track Rack",
                accent: Color(red: 0.42, green: 0.84, blue: 0.97)
            ) {
                onSelect(.multiTrack)
            }
        }
    }
}

private struct ModeCard: View {
    let eyebrow: String
    let title: String
    let description: String
    let features: [String]
    let buttonTitle: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        StudioPanel("", compact: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .tracking(1.2)
                        .foregroundStyle(accent)

                    Text(title)
                        .font(.system(size: 20, weight: .bold, design: .default))
                        .foregroundStyle(StudioTheme.strongText)

                    Text(description)
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .foregroundStyle(StudioTheme.mutedText)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(features, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark")
                            .font(.system(size: 12, weight: .regular, design: .default))
                            .foregroundStyle(StudioTheme.strongText)
                    }
                }

                Spacer(minLength: 0)

                Button(buttonTitle, action: action)
                    .buttonStyle(StudioPrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.25), lineWidth: 1)
        )
    }
}
