import SwiftUI

struct TuningPopoutView: View {
    @ObservedObject var viewModel: MultiTrackViewModel
    @State private var showsAddSongSheet = false
    @State private var draftSongTitle = ""
    @State private var draftSongKey = WavesTuneKeySelection()

    var body: some View {
        ScrollView {
            WavesTuneControlPane(
                viewModel: viewModel,
                songSummary: songSummary,
                showMissingInsertHint: false,
                showsEditableSongRows: false,
                onAddSong: presentAddSongSheet
            )
            .padding(14)
        }
        .frame(minWidth: 440, minHeight: 400)
        .background(StudioTheme.panelFill)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsAddSongSheet) {
            WavesTuneAddSongSheet(
                title: $draftSongTitle,
                key: $draftSongKey,
                onCancel: { showsAddSongSheet = false },
                onConfirm: confirmAddSong
            )
        }
    }

    private var songSummary: String {
        if viewModel.wavesTuneSongs.isEmpty {
            return "No songs yet. Add one to build the setlist."
        }
        if let idx = viewModel.selectedWavesTuneSongIndex {
            return "Song \(idx + 1) of \(viewModel.wavesTuneSongs.count) - \(viewModel.selectedWavesTuneSongKeyTitle)"
        }
        return "Select a song to make it live."
    }

    private func presentAddSongSheet() {
        draftSongTitle = ""
        draftSongKey = WavesTuneKeySelection()
        showsAddSongSheet = true
    }

    private func confirmAddSong() {
        let title = draftSongTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        viewModel.addWavesTuneSong(title: title, key: draftSongKey)
        showsAddSongSheet = false
    }
}
