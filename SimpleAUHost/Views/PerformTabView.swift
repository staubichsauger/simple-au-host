import SwiftUI

struct PerformTabView: View {
    private let trackCardMinimumWidth: CGFloat = 280
    private let trackCardMaximumWidth: CGFloat = 320

    @ObservedObject var viewModel: MultiTrackViewModel
    let requestCreateNewSession: () -> Void
    let openSessionPanel: () -> Void
    let saveSessionAs: () -> Bool
    let requestSessionLoad: (URL) -> Void

    @State private var showsAddWavesTuneSongSheet = false
    @State private var draftWavesTuneSongTitle = ""
    @State private var draftWavesTuneSongKey = WavesTuneKeySelection()

    var body: some View {
        HSplitView {
            performTrackBoard
                .padding(.trailing, 6)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

            performTuningPane
                .frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showsAddWavesTuneSongSheet) {
            WavesTuneAddSongSheet(
                title: $draftWavesTuneSongTitle,
                key: $draftWavesTuneSongKey,
                onCancel: dismissAddWavesTuneSongSheet,
                onConfirm: confirmAddWavesTuneSong
            )
        }
    }

    private var performTrackBoard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.performTracks.isEmpty {
                    performEmptyState
                } else {
                    LazyVGrid(columns: performTrackGridColumns, alignment: .leading, spacing: 8) {
                        ForEach(viewModel.performTracks) { track in
                            performTrackCard(track)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.vertical, 2)

                performSessionActionPanel
                managedSessionsPanel
            }
            .padding(.bottom, 8)
        }
    }

    private var performEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No Waves Tune Tracks")
                .font(.system(size: 16, weight: .semibold, design: .default))
                .foregroundStyle(StudioTheme.strongText)

            Text("Load Waves Tune Real-Time on a track in Rack to create a perform card here.")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(StudioTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StudioTheme.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(StudioTheme.panelStroke, lineWidth: 1)
        )
    }

    private var performTrackGridColumns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: trackCardMinimumWidth,
                    maximum: trackCardMaximumWidth
                ),
                spacing: 8,
                alignment: .top
            )
        ]
    }

    private func performTrackCard(_ track: MultiTrackTrackConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(track.name)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(StudioTheme.strongText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if !track.isEnabled {
                    Text("Off")
                        .font(.system(size: 9, weight: .medium, design: .default))
                        .foregroundStyle(StudioTheme.warning)
                }
            }

            StudioFieldLabel("Tune Strength")

            Picker(
                "Tune Strength",
                selection: Binding(
                    get: { track.wavesTuneStrength },
                    set: { viewModel.setWavesTuneStrength($0, for: track.id) }
                )
            ) {
                ForEach(WavesTuneStrengthPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()

            if let speed = track.wavesTuneStrength.speed,
               let noteTransition = track.wavesTuneStrength.noteTransition {
                Text("\(Int(speed)) spd \u{00B7} \(Int(noteTransition)) trans")
                    .font(.system(size: 10, weight: .regular, design: .default))
                    .foregroundStyle(StudioTheme.mutedText)
            } else {
                Text("Uses current plugin values")
                    .font(.system(size: 10, weight: .regular, design: .default))
                    .foregroundStyle(StudioTheme.mutedText)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StudioTheme.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(StudioTheme.panelStroke, lineWidth: 1)
        )
    }

    private var performTuningPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Waves Tune Control")
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundStyle(StudioTheme.strongText)

                Text("Global key staging and setlist control for the current show.")
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(StudioTheme.mutedText)
                    .lineLimit(2)
            }

            ScrollView {
                WavesTuneControlPane(
                    viewModel: viewModel,
                    songSummary: selectedWavesTuneSongSummary,
                    showMissingInsertHint: true,
                    showsEditableSongRows: true,
                    onAddSong: presentAddWavesTuneSongSheet
                )
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StudioTheme.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(StudioTheme.panelStroke, lineWidth: 1)
        )
    }

    private var performSessionActionPanel: some View {
        StudioPanel("Show", compact: true) {
            sessionFileActions
        }
    }

    private var sessionFileActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                newShowButton
                openShowButton
                saveShowButton
                saveAsShowButton
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    newShowButton
                    openShowButton
                }

                HStack(spacing: 12) {
                    saveShowButton
                    saveAsShowButton
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

    private var managedSessionsPanel: some View {
        StudioPanel("Managed Sessions", subtitle: "Quick-load shows from ~/Music/SAH/Sessions, newest first.") {
            VStack(alignment: .leading, spacing: 12) {
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
        }
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

    private var selectedWavesTuneSongSummary: String {
        if viewModel.wavesTuneSongs.isEmpty {
            return "No songs yet. Add one to build the setlist."
        }

        if let selectedIndex = viewModel.selectedWavesTuneSongIndex {
            return "Song \(selectedIndex + 1) of \(viewModel.wavesTuneSongs.count) - \(viewModel.selectedWavesTuneSongKeyTitle)"
        }

        return "Select a song to make it live."
    }

    private var canConfirmAddWavesTuneSong: Bool {
        !draftWavesTuneSongTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func presentAddWavesTuneSongSheet() {
        draftWavesTuneSongTitle = ""
        draftWavesTuneSongKey = WavesTuneKeySelection()
        showsAddWavesTuneSongSheet = true
    }

    private func dismissAddWavesTuneSongSheet() {
        showsAddWavesTuneSongSheet = false
    }

    private func confirmAddWavesTuneSong() {
        guard canConfirmAddWavesTuneSong else { return }
        viewModel.addWavesTuneSong(
            title: draftWavesTuneSongTitle,
            key: draftWavesTuneSongKey
        )
        dismissAddWavesTuneSongSheet()
    }
}
