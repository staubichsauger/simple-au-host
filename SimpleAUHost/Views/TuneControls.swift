import SwiftUI

struct TuneControlPane: View {
    @ObservedObject var viewModel: MultiTrackViewModel
    let songSummary: String
    let showMissingInsertHint: Bool
    let showsEditableSongRows: Bool
    let onAddSong: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TuneMetricCard(
                    title: "Instances",
                    value: "\(viewModel.configuredTuneInsertCount)",
                    tint: viewModel.configuredTuneInsertCount > 0 ? StudioTheme.accent : StudioTheme.mutedText
                )
                TuneMetricCard(title: "Applied", value: viewModel.appliedTuneKeyTitle)
                TuneMetricCard(
                    title: "State",
                    value: viewModel.tuneState.isEnabled ? "Active" : "Bypassed",
                    tint: viewModel.tuneState.isEnabled ? StudioTheme.accent : StudioTheme.warning
                )
            }

            Toggle("Tune Active", isOn: Binding(
                get: { viewModel.tuneState.isEnabled },
                set: { viewModel.setTuneEnabled($0) }
            ))
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        StudioFieldLabel("Setlist")
                        Text(viewModel.selectedTuneSongTitle)
                            .font(.system(size: 13, weight: .semibold, design: .default))
                            .foregroundStyle(StudioTheme.strongText)
                        Text(songSummary)
                            .font(.system(size: 10, weight: .regular, design: .default))
                            .foregroundStyle(StudioTheme.mutedText)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        Button("Key Panic") {
                            viewModel.triggerTuneKeyPanic()
                        }
                        .buttonStyle(StudioDestructiveButtonStyle())

                        Button {
                            viewModel.stepTuneSong(direction: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(StudioSecondaryButtonStyle())
                        .disabled(!viewModel.canSelectPreviousTuneSong)

                        Button {
                            viewModel.stepTuneSong(direction: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(StudioSecondaryButtonStyle())
                        .disabled(!viewModel.canSelectNextTuneSong)

                        Button("Add Song") {
                            onAddSong()
                        }
                        .buttonStyle(StudioSecondaryButtonStyle())
                    }
                }

                if viewModel.tuneSongs.isEmpty {
                    Text("Add songs in show order. Selecting a song or stepping next/previous applies its key immediately.")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.mutedText)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(viewModel.tuneSongs.enumerated()), id: \.element.id) { index, song in
                            TuneSongRow(
                                viewModel: viewModel,
                                song: song,
                                index: index,
                                isEditable: showsEditableSongRows
                            )
                        }
                    }
                }
            }

            TuneKeyControls(
                key: viewModel.tuneState.stagedKey,
                setScaleMode: { viewModel.setTuneScaleMode($0) },
                setAccidental: { viewModel.setTuneAccidental($0) },
                setNoteLetter: { viewModel.setTuneNoteLetter($0) }
            )

            if showMissingInsertHint && viewModel.configuredTuneInsertCount == 0 {
                Text("Add a tuner insert to any enabled track to use these controls.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.mutedText)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Staged")
                        .font(.system(size: 9, weight: .medium, design: .default))
                        .tracking(1.0)
                        .foregroundStyle(StudioTheme.mutedText)
                    Text(viewModel.stagedTuneKeyTitle)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(StudioTheme.strongText)
                }

                Spacer()

                Button("Save Song Key") {
                    viewModel.saveStagedKeyToSelectedTuneSong()
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(!viewModel.canSaveStagedKeyToSelectedTuneSong)

                Button("Apply") {
                    viewModel.applyStagedTuneKey()
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                .disabled(!viewModel.canApplyStagedTuneKey)
            }
        }
    }
}

struct TuneAddSongSheet: View {
    @Binding var title: String
    @Binding var key: TuneKeySelection
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var canConfirm: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Song")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(StudioTheme.strongText)

            VStack(alignment: .leading, spacing: 8) {
                StudioFieldLabel("Song Name")
                TextField("Song title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(StudioTheme.strongText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }

            TuneKeyControls(
                key: key,
                setScaleMode: { key.scaleMode = $0 },
                setAccidental: { key.accidental = $0 },
                setNoteLetter: {
                    key.noteLetter = $0
                    key.normalize()
                }
            )

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Key")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(StudioTheme.mutedText)
                    Text(key.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(StudioTheme.strongText)
                }

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(StudioSecondaryButtonStyle())

                Button("Add Song") {
                    onConfirm()
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(StudioTheme.panelFill)
    }
}

struct TuneKeyControls: View {
    let key: TuneKeySelection
    let setScaleMode: (TuneScaleMode) -> Void
    let setAccidental: (TuneAccidental) -> Void
    let setNoteLetter: (TuneNoteLetter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    StudioFieldLabel("Scale")
                    Picker("Scale", selection: Binding(
                        get: { key.scaleMode },
                        set: { setScaleMode($0) }
                    )) {
                        ForEach(TuneScaleMode.allCases) { scaleMode in
                            Text(scaleMode.title).tag(scaleMode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    StudioFieldLabel("Accidental")
                    HStack(spacing: 4) {
                        ForEach(TuneAccidental.allCases) { accidental in
                            let isAllowed = TuneKeySelection.supports(
                                accidental: accidental,
                                for: key.noteLetter
                            )
                            TuneChoiceButton(
                                title: accidental.title,
                                isSelected: key.accidental == accidental,
                                isEnabled: isAllowed
                            ) {
                                setAccidental(accidental)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 4) {
                ForEach(TuneNoteLetter.allCases) { noteLetter in
                    TuneChoiceButton(
                        title: noteLetter.title,
                        isSelected: key.noteLetter == noteLetter
                    ) {
                        setNoteLetter(noteLetter)
                    }
                }
            }
        }
    }
}

struct TuneSongRow: View {
    @ObservedObject var viewModel: MultiTrackViewModel
    let song: TuneSongEntry
    let index: Int
    let isEditable: Bool

    var body: some View {
        let isSelected = viewModel.tuneState.selectedSongID == song.id

        return VStack(alignment: .leading, spacing: isEditable ? 6 : 5) {
            HStack(spacing: 6) {
                Button {
                    viewModel.selectTuneSong(song.id)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "play.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.mutedText)
                }
                .buttonStyle(.plain)

                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .default))
                    .foregroundStyle(StudioTheme.mutedText)
                    .frame(width: 16)

                if isEditable {
                    TextField(
                        "Song \(index + 1)",
                        text: Binding(
                            get: { song.title },
                            set: { viewModel.updateTuneSongTitle(song.id, title: $0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(StudioTheme.strongText)
                } else {
                    Text(song.title)
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .foregroundStyle(StudioTheme.strongText)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }

                if isEditable {
                    Button(song.key.title) {
                        viewModel.selectTuneSong(song.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium, design: .default))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(keyBackground(isSelected: isSelected))
                    .overlay(keyOverlay(isSelected: isSelected))
                    .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.strongText)
                } else {
                    Text(song.key.title)
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(keyBackground(isSelected: isSelected))
                        .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.strongText)
                }

                TuneSongIconButton(systemName: "chevron.up", help: "Move song up") {
                    viewModel.moveTuneSong(song.id, direction: -1)
                }
                .disabled(index == 0)

                TuneSongIconButton(systemName: "chevron.down", help: "Move song down") {
                    viewModel.moveTuneSong(song.id, direction: 1)
                }
                .disabled(index >= viewModel.tuneSongs.count - 1)

                TuneSongIconButton(systemName: "plus.square.on.square", help: "Duplicate song") {
                    viewModel.duplicateTuneSong(song.id)
                }

                TuneSongIconButton(systemName: "trash", help: "Remove song") {
                    viewModel.removeTuneSong(song.id)
                }
                .foregroundStyle(StudioTheme.warning)
            }

            if isEditable {
                TextField(
                    "Notes",
                    text: Binding(
                        get: { song.notes },
                        set: { viewModel.updateTuneSongNotes(song.id, notes: $0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .regular, design: .default))
                .foregroundStyle(StudioTheme.mutedText)
            } else if !song.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(song.notes)
                    .font(.system(size: 10, weight: .regular, design: .default))
                    .foregroundStyle(StudioTheme.mutedText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? StudioTheme.accent.opacity(0.08) : Color.white.opacity(0.025))
        )
        .overlay {
            if isEditable {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? StudioTheme.accent.opacity(0.30) : Color.white.opacity(0.05), lineWidth: 1)
            }
        }
    }

    private func keyBackground(isSelected: Bool) -> some ShapeStyle {
        isSelected ? StudioTheme.accent.opacity(0.15) : Color.white.opacity(0.04)
    }

    private func keyOverlay(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(isSelected ? StudioTheme.accent.opacity(0.50) : Color.white.opacity(0.06), lineWidth: 1)
    }
}

struct TuneMetricCard: View {
    let title: String
    let value: String
    let tint: Color

    init(title: String, value: String, tint: Color = StudioTheme.strongText) {
        self.title = title
        self.value = value
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium, design: .default))
                .tracking(0.8)
                .foregroundStyle(StudioTheme.mutedText)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct TuneChoiceButton: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    init(
        title: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .default))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? StudioTheme.accent.opacity(0.18) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isSelected ? StudioTheme.accent.opacity(0.60) : Color.white.opacity(0.06), lineWidth: 1)
                )
                .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.strongText)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

private struct TuneSongIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudioTheme.mutedText)
        .help(help)
    }
}
