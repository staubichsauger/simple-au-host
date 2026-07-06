import SwiftUI

struct ShowTabView: View {
    @ObservedObject var viewModel: MultiTrackViewModel
    @Binding var showsDiagnostics: Bool
    let requestCreateNewSession: () -> Void
    let openSessionPanel: () -> Void
    let saveSessionAs: () -> Bool
    let requestSessionLoad: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                showSessionAndListPanel
                showStatusPanel
                diagnosticsPanel
            }
            .padding(.bottom, 8)
        }
    }

    private var showSessionAndListPanel: some View {
        StudioPanel("Show", subtitle: "Manage the session file and quick-load saved shows.") {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    newShowButton
                    openShowButton
                    saveShowButton
                    saveAsShowButton
                }
                .frame(width: 120)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    StudioFieldLabel("Managed Sessions", subtitle: "Newest first.")

                    if viewModel.managedSessions.isEmpty {
                        Text("No managed sessions have been saved yet.")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.mutedText)
                    } else {
                        ForEach(viewModel.managedSessions) { session in
                            managedSessionRow(session)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var showStatusPanel: some View {
        StudioPanel("Current Show", subtitle: "Session identity, warnings, and live status.") {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StudioMetricTile("Session", value: viewModel.currentSessionDisplayName)
                    StudioMetricTile("Engine", value: viewModel.statusMessage)
                    StudioMetricTile("Tracks", value: "\(viewModel.tracks.count)")
                    StudioMetricTile("Enabled", value: "\(viewModel.tracks.filter(\.isEnabled).count)")
                }

                if !viewModel.sessionWarnings.isEmpty {
                    warningList(viewModel.sessionWarnings)
                }

                if !viewModel.invalidTrackMessages.isEmpty {
                    warningList(viewModel.invalidTrackMessages)
                }

                if !viewModel.latencyBufferValidationMessages.isEmpty {
                    warningList(viewModel.latencyBufferValidationMessages)
                }
            }
        }
    }

    private var diagnosticsPanel: some View {
        StudioPanel("Diagnostics", subtitle: "Warnings and live engine telemetry for the current show.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle("Show Diagnostics", isOn: $showsDiagnostics)
                        .toggleStyle(.switch)

                    Spacer()

                    Button("Reset Dropout Stats") {
                        viewModel.resetDropoutCounters()
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(!viewModel.isRunning && viewModel.audioDropoutCount == 0 && viewModel.droppedFrameCount == 0)
                }

                if showsDiagnostics {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StudioMetricTile("Dropouts", value: "\(viewModel.audioDropoutCount)", tint: viewModel.audioDropoutCount > 0 ? StudioTheme.warning : StudioTheme.strongText)
                        StudioMetricTile("Dropped Frames", value: "\(viewModel.droppedFrameCount)")
                        StudioMetricTile("Callbacks", value: trimmedTelemetry(viewModel.telemetrySummary, prefix: "Callbacks in/out: "))
                        StudioMetricTile("Ring", value: trimmedTelemetry(viewModel.ringTelemetrySummary, prefix: "Peak ring occupancy in/out: "))
                        StudioMetricTile("Workers", value: trimmedTelemetry(viewModel.workerTelemetrySummary, prefix: "Workers: "))
                        StudioMetricTile("Realtime", value: trimmedTelemetry(viewModel.realtimeTelemetrySummary, prefix: "Realtime: "))
                        StudioMetricTile("Buffered", value: trimmedTelemetry(viewModel.bufferedTelemetrySummary, prefix: "Buffered: "))
                        StudioMetricTile("Broadcast", value: trimmedTelemetry(viewModel.broadcastTelemetrySummary, prefix: "Broadcast: "))
                        StudioMetricTile("Engine", value: viewModel.statusMessage)
                    }
                }
            }
        }
    }

    private var newShowButton: some View {
        Button {
            requestCreateNewSession()
        } label: {
            Text("New Show").frame(maxWidth: .infinity)
        }
        .buttonStyle(StudioSecondaryButtonStyle())
        .disabled(viewModel.isRunning)
    }

    private var openShowButton: some View {
        Button {
            openSessionPanel()
        } label: {
            Text("Open Show").frame(maxWidth: .infinity)
        }
        .buttonStyle(StudioSecondaryButtonStyle())
        .disabled(viewModel.isRunning)
    }

    private var saveShowButton: some View {
        Button {
            Task {
                if viewModel.hasStoredSessionFile {
                    do {
                        try await viewModel.saveSessionAsync()
                    } catch {
                        viewModel.statusMessage = error.localizedDescription
                    }
                } else {
                    _ = saveSessionAs()
                }
            }
        } label: {
            Text("Save").frame(maxWidth: .infinity)
        }
        .buttonStyle(StudioPrimaryButtonStyle())
    }

    private var saveAsShowButton: some View {
        Button {
            _ = saveSessionAs()
        } label: {
            Text("Save As").frame(maxWidth: .infinity)
        }
        .buttonStyle(StudioSecondaryButtonStyle())
    }

    private func managedSessionRow(_ session: ManagedSessionFile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(StudioTheme.strongText)

                Text(session.modifiedDateLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.mutedText)
            }

            Spacer()

            Button("Load") {
                requestSessionLoad(session.url)
            }
            .buttonStyle(StudioSecondaryButtonStyle())
            .disabled(viewModel.isRunning)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    private func warningList(_ messages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func trimmedTelemetry(_ value: String, prefix: String) -> String {
        value.replacingOccurrences(of: prefix, with: "")
    }
}
