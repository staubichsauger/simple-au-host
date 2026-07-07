import SwiftUI

struct TuningPopoutView: View {
    @ObservedObject var viewModel: MultiTrackViewModel
    @State private var showsAddSongSheet = false
    @State private var draftSongTitle = ""
    @State private var draftSongKey = TuneKeySelection()

    var body: some View {
        ScrollView {
            TuneControlPane(
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
            TuneAddSongSheet(
                title: $draftSongTitle,
                key: $draftSongKey,
                onCancel: { showsAddSongSheet = false },
                onConfirm: confirmAddSong
            )
        }
    }

    private var songSummary: String {
        if viewModel.tuneSongs.isEmpty {
            return "No songs yet. Add one to build the setlist."
        }
        if let idx = viewModel.selectedTuneSongIndex {
            return "Song \(idx + 1) of \(viewModel.tuneSongs.count) - \(viewModel.selectedTuneSongKeyTitle)"
        }
        return "Select a song to make it live."
    }

    private func presentAddSongSheet() {
        draftSongTitle = ""
        draftSongKey = TuneKeySelection()
        showsAddSongSheet = true
    }

    private func confirmAddSong() {
        let title = draftSongTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        viewModel.addTuneSong(title: title, key: draftSongKey)
        showsAddSongSheet = false
    }
}
