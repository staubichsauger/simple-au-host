import AppKit
import SwiftUI

private enum RackTabInspectorMode: String, CaseIterable, Identifiable {
    case plugin = "Plugin"
    case tuning = "Tuning"

    var id: String { rawValue }
}

private struct RackTabPluginSelectionRequest: Identifiable {
    let trackID: UUID
    let insertID: UUID
    let insertTitle: String
    let emptyTitle: String

    var id: String {
        "\(trackID.uuidString)::\(insertID.uuidString)"
    }
}

struct RackTabView: View {
    @ObservedObject var viewModel: MultiTrackViewModel
    @Binding var showsEmbeddedPluginPane: Bool
    let popOutTuningInspector: () -> Void

    @State private var rackInspectorMode: RackTabInspectorMode = .plugin
    @State private var selectedRackTrackID: UUID?
    @State private var selectedRackPluginID: UUID?
    @State private var rackPluginSelectionRequest: RackTabPluginSelectionRequest?
    @State private var showsAddWavesTuneSongSheet = false
    @State private var draftWavesTuneSongTitle = ""
    @State private var draftWavesTuneSongKey = WavesTuneKeySelection()

    var body: some View {
        HSplitView {
            rackStripBoard
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if showsEmbeddedPluginPane {
                rackInspectorPane
                    .frame(minWidth: 460, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            syncRackSelection()
            refreshEmbeddedPluginPane()
        }
        .onDisappear {
            viewModel.clearEmbeddedPluginEditor()
        }
        .onChange(of: viewModel.tracks) { _, _ in
            syncRackSelection()
            refreshEmbeddedPluginPane()
        }
        .onChange(of: selectedRackTrackID) { _, _ in
            refreshEmbeddedPluginPane()
        }
        .onChange(of: selectedRackPluginID) { _, _ in
            refreshEmbeddedPluginPane()
        }
        .onChange(of: rackInspectorMode) { _, _ in
            refreshEmbeddedPluginPane()
        }
        .onChange(of: showsEmbeddedPluginPane) { _, _ in
            refreshEmbeddedPluginPane()
        }
        .onChange(of: viewModel.isRunning) { _, _ in
            refreshEmbeddedPluginPane()
        }
        .sheet(isPresented: $showsAddWavesTuneSongSheet) {
            WavesTuneAddSongSheet(
                title: $draftWavesTuneSongTitle,
                key: $draftWavesTuneSongKey,
                onCancel: dismissAddWavesTuneSongSheet,
                onConfirm: confirmAddWavesTuneSong
            )
        }
        .sheet(item: $rackPluginSelectionRequest) { request in
            RackPluginSelectionSheet(
                title: request.insertTitle,
                emptyTitle: request.emptyTitle,
                currentPluginID: currentPluginID(for: request),
                plugins: viewModel.plugins
            ) { newPluginID in
                updatePluginID(
                    trackID: request.trackID,
                    insertID: request.insertID,
                    newValue: newPluginID
                )
            }
        }
    }

    private var rackStripBoard: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(alignment: .top, spacing: 8) {
                ForEach($viewModel.tracks) { $track in
                    rackStrip($track)
                        .frame(width: 176)
                }

                rackAddTrackStrip
                    .frame(width: 176)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private var rackAddTrackStrip: some View {
        VStack(spacing: 8) {
            addMonoTrackButton
            addStereoTrackButton
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var rackInspectorPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rackInspectorTitle)
                        .font(.system(size: 14, weight: .semibold, design: .default))
                        .foregroundStyle(StudioTheme.strongText)

                    Text(rackInspectorSubtitle)
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(StudioTheme.mutedText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    ForEach(RackTabInspectorMode.allCases) { mode in
                        Button {
                            rackInspectorMode = mode
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 10, weight: .medium, design: .default))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(rackInspectorMode == mode ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
                                )
                                .foregroundStyle(rackInspectorMode == mode ? StudioTheme.accent : StudioTheme.mutedText)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    popOutCurrentInspector()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(!canPopOutInspector)

                Button {
                    showsEmbeddedPluginPane = false
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(StudioSecondaryButtonStyle())
            }

            rackInspectorBody
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

    private var rackInspectorTitle: String {
        switch rackInspectorMode {
        case .plugin:
            selectedTrack?.name ?? "Plugin View"
        case .tuning:
            "Waves Tune Control"
        }
    }

    private var rackInspectorSubtitle: String {
        switch rackInspectorMode {
        case .plugin:
            selectedPluginInfo?.name ?? "Select an insert to inspect its editor."
        case .tuning:
            "Switch here for compact global key staging and bypass control."
        }
    }

    @ViewBuilder
    private var rackInspectorBody: some View {
        switch rackInspectorMode {
        case .plugin:
            embeddedPluginBody
        case .tuning:
            tuningInspectorBody
        }
    }

    private var tuningInspectorBody: some View {
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
    }

    @ViewBuilder
    private var embeddedPluginBody: some View {
        if !viewModel.isRunning {
            embeddedPluginPlaceholder(
                title: "Engine Stopped",
                detail: "Start the engine to embed the selected plugin UI."
            )
        } else if selectedPlugin?.pluginID == nil {
            embeddedPluginPlaceholder(
                title: "No Plugin Loaded",
                detail: "Load a plugin into the selected insert to display its editor here."
            )
        } else if let session = viewModel.embeddedPluginEditorSession {
            EmbeddedPluginEditorContainer(viewController: session.viewController)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
        } else {
            embeddedPluginPlaceholder(
                title: "Loading Editor",
                detail: "Requesting the plugin UI from the live Audio Unit instance."
            )
        }
    }

    private func embeddedPluginPlaceholder(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "dial.medium")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(StudioTheme.mutedText)

            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(StudioTheme.strongText)

            Text(detail)
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(StudioTheme.mutedText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private func rackStrip(_ track: Binding<MultiTrackTrackConfiguration>) -> some View {
        let value = track.wrappedValue
        let isSelectedTrack = selectedTrack?.id == value.id

        return VStack(alignment: .leading, spacing: 8) {
            rackStripHeaderContainer(track, value: value, isSelectedTrack: isSelectedTrack)
            rackInsertSection(track, value: value)

            Spacer(minLength: 0)

            rackStripFooter(track, value: value)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelectedTrack ? StudioTheme.accent.opacity(0.40) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func rackStripHeaderContainer(
        _ track: Binding<MultiTrackTrackConfiguration>,
        value: MultiTrackTrackConfiguration,
        isSelectedTrack: Bool
    ) -> some View {
        rackStripHeader(track, value: value, isSelectedTrack: isSelectedTrack)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelectedTrack ? Color.white.opacity(0.07) : Color.white.opacity(0.03))
            )
            .onTapGesture {
                selectedRackTrackID = value.id
                if selectedPlugin(for: value) == nil {
                    selectedRackPluginID = value.plugins.first?.id
                }
            }
    }

    private func rackInsertSection(
        _ track: Binding<MultiTrackTrackConfiguration>,
        value: MultiTrackTrackConfiguration
    ) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(track.plugins.enumerated()), id: \.element.id) { index, plugin in
                rackInsertSlot(trackID: value.id, plugin: plugin, index: index)
            }

            Button {
                viewModel.addPluginInsert(to: value.id)
                selectedRackTrackID = value.id
                selectedRackPluginID = viewModel.tracks.first(where: { $0.id == value.id })?.plugins.last?.id
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Add Plugin")
                        .font(.system(size: 10, weight: .medium, design: .default))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.mutedText)
            .disabled(viewModel.isRunning)
        }
    }

    private func rackInsertSlot(
        trackID: UUID,
        plugin: Binding<MultiTrackTrackConfiguration.PluginInsert>,
        index: Int
    ) -> some View {
        let isSelected = selectedRackTrackID == trackID && selectedRackPluginID == plugin.wrappedValue.id
        let pluginID = plugin.wrappedValue.id
        let insertCount = viewModel.tracks.first(where: { $0.id == trackID })?.plugins.count ?? 0

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(plugin.wrappedValue.pluginID == nil ? Color.white.opacity(0.15) : StudioTheme.accent)
                    .frame(width: 6, height: 6)
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .medium, design: .default))
                    .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.mutedText)
                Spacer()
                rackInsertIconButton(systemName: "chevron.up", help: "Move insert up") {
                    viewModel.movePluginInsert(trackID: trackID, pluginID: pluginID, direction: -1)
                    selectedRackTrackID = trackID
                    selectedRackPluginID = pluginID
                }
                .disabled(viewModel.isRunning || index == 0)
                rackInsertIconButton(systemName: "chevron.down", help: "Move insert down") {
                    viewModel.movePluginInsert(trackID: trackID, pluginID: pluginID, direction: 1)
                    selectedRackTrackID = trackID
                    selectedRackPluginID = pluginID
                }
                .disabled(viewModel.isRunning || index >= insertCount - 1)
                if plugin.wrappedValue.pluginID != nil {
                    rackInsertIconButton(systemName: "arrow.up.right.square", help: "Open plugin editor") {
                        viewModel.openPluginEditor(for: trackID, pluginID: plugin.wrappedValue.id)
                    }
                    .disabled(!viewModel.canOpenPluginEditor(for: plugin.wrappedValue))
                }
                rackInsertIconButton(systemName: "trash", help: "Remove insert") {
                    viewModel.removePluginInsert(trackID: trackID, pluginID: pluginID)
                    selectedRackTrackID = trackID
                    let remainingPlugins = viewModel.tracks.first(where: { $0.id == trackID })?.plugins ?? []
                    if remainingPlugins.isEmpty {
                        selectedRackPluginID = nil
                    } else {
                        selectedRackPluginID = remainingPlugins[min(index, remainingPlugins.count - 1)].id
                    }
                }
                .disabled(viewModel.isRunning)
            }

            pluginSelectionButton(
                title: pluginSelectionTitle(for: plugin.wrappedValue.pluginID, emptyTitle: "Empty")
            ) {
                openPluginSelection(
                    trackID: trackID,
                    insertID: plugin.wrappedValue.id,
                    insertTitle: "Insert \(index + 1)",
                    emptyTitle: "Empty"
                )
            }
            .disabled(viewModel.isRunning)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.06) : Color.white.opacity(0.025))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(isSelected ? StudioTheme.accent.opacity(0.40) : Color.white.opacity(0.05), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onTapGesture {
            selectedRackTrackID = trackID
            selectedRackPluginID = plugin.wrappedValue.id
        }
    }

    private func rackInsertIconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
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

    private func rackStripHeader(
        _ track: Binding<MultiTrackTrackConfiguration>,
        value: MultiTrackTrackConfiguration,
        isSelectedTrack: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Track name", text: track.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .default))
                .foregroundStyle(StudioTheme.strongText)
                .disabled(viewModel.isRunning)

            rackLayoutControl(track, value: value)
            rackInputControl(track)
            rackOutputControl(track)
            rackModeControl(track)
        }
    }

    private func rackLayoutControl(
        _ track: Binding<MultiTrackTrackConfiguration>,
        value: MultiTrackTrackConfiguration
    ) -> some View {
        rackControlRow(title: "Layout") {
            Picker("Layout", selection: track.layout) {
                ForEach(TrackChannelLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(viewModel.isRunning)
            .onChange(of: track.wrappedValue.layout) { _, _ in
                viewModel.sanitizeTrack(id: value.id)
            }
        }
    }

    private func rackInputControl(_ track: Binding<MultiTrackTrackConfiguration>) -> some View {
        let value = track.wrappedValue
        let channels = viewModel.availableInputStartChannels(for: value)
        let isInvalid = !viewModel.inputRoutingIsValid(for: value)
        return rackControlRow(title: "Input", isInvalid: isInvalid) {
            Picker("Input", selection: track.inputStartChannel) {
                ForEach(channels, id: \.self) { channel in
                    Text(channelLabel(startChannel: channel, layout: value.layout)).tag(channel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(isInvalid ? StudioTheme.warning : StudioTheme.strongText)
            .disabled(viewModel.isRunning || channels.isEmpty)
        }
    }

    private func rackOutputControl(_ track: Binding<MultiTrackTrackConfiguration>) -> some View {
        let value = track.wrappedValue
        let channels = viewModel.availableOutputStartChannels(for: value)
        let isInvalid = !viewModel.outputRoutingIsValid(for: value)
        return rackControlRow(title: "Output", isInvalid: isInvalid) {
            Picker("Output", selection: track.outputStartChannel) {
                ForEach(channels, id: \.self) { channel in
                    Text(channelLabel(startChannel: channel, layout: value.layout)).tag(channel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(isInvalid ? StudioTheme.warning : StudioTheme.strongText)
            .disabled(viewModel.isRunning || channels.isEmpty)
        }
    }

    private func rackModeControl(_ track: Binding<MultiTrackTrackConfiguration>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            rackControlRow(title: "Mode") {
                Picker("Mode", selection: track.latencyClass) {
                    ForEach(TrackLatencyClass.allCases) { latencyClass in
                        Text(latencyClass.title).tag(latencyClass)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(viewModel.isRunning)
            }

            Text(viewModel.latencyReadout(for: track.wrappedValue))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioTheme.mutedText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func channelLabel(startChannel: Int, layout: TrackChannelLayout) -> String {
        switch layout {
        case .mono:
            return "Ch \(startChannel)"
        case .stereo:
            return "\(startChannel)/\(startChannel + 1)"
        }
    }

    private func rackStripFooter(
        _ track: Binding<MultiTrackTrackConfiguration>,
        value: MultiTrackTrackConfiguration
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Enabled", isOn: track.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(viewModel.isRunning)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                rackFooterButton("Copy FX", icon: "doc.on.doc") {
                    viewModel.copyTrackProcessing(from: value.id)
                }
                rackFooterButton("Paste FX", icon: "clipboard") {
                    viewModel.pasteTrackProcessing(to: value.id)
                    if selectedRackTrackID == value.id {
                        selectedRackPluginID = viewModel.tracks.first(where: { $0.id == value.id })?.plugins.first?.id
                    }
                }
                .disabled(!viewModel.canPasteTrackProcessing(to: value.id))

                rackFooterButton("Chain", icon: "square.and.arrow.down") {
                    saveChainPreset(for: value.id)
                }
                rackFooterButton("Chain", icon: "square.and.arrow.up") {
                    loadChainPreset(for: value.id) {
                        if selectedRackTrackID == value.id {
                            selectedRackPluginID = viewModel.tracks.first(where: { $0.id == value.id })?.plugins.first?.id
                        }
                    }
                }
                .disabled(viewModel.isRunning)

                rackFooterButton("Params", icon: "slider.horizontal.3") {
                    saveParameterPreset(for: value.id)
                }
                .disabled(!value.hasPlugins)

                rackFooterButton("Params", icon: "square.and.arrow.up.on.square") {
                    loadParameterPreset(for: value.id) {
                        if selectedRackTrackID == value.id {
                            selectedRackPluginID = viewModel.tracks.first(where: { $0.id == value.id })?.plugins.first?.id
                        }
                    }
                }
                .disabled(!value.hasPlugins)
            }

            Button {
                viewModel.removeTrack(id: value.id)
                syncRackSelection()
            } label: {
                Text("Remove")
                    .font(.system(size: 10, weight: .medium, design: .default))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioDestructiveButtonStyle())
            .disabled(viewModel.isRunning)
        }
    }

    private func rackFooterButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .medium, design: .default))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
        }
        .buttonStyle(StudioSecondaryButtonStyle())
    }

    private func rackControlRow<Content: View>(
        title: String,
        isInvalid: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium, design: .default))
                .tracking(0.8)
                .foregroundStyle(isInvalid ? StudioTheme.warning : StudioTheme.mutedText)
                .frame(width: 48, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, isInvalid ? 2 : 0)
        .padding(.horizontal, isInvalid ? 4 : 0)
        .background {
            if isInvalid {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(StudioTheme.warning.opacity(0.10))
            }
        }
        .overlay {
            if isInvalid {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(StudioTheme.warning.opacity(0.55), lineWidth: 1)
            }
        }
    }

    private var addMonoTrackButton: some View {
        Button("Add Mono Track") {
            viewModel.addMonoTrack()
            syncRackSelection()
        }
        .buttonStyle(StudioSecondaryButtonStyle())
        .disabled(viewModel.isRunning)
    }

    private var addStereoTrackButton: some View {
        Button("Add Stereo Track") {
            viewModel.addStereoTrack()
            syncRackSelection()
        }
        .buttonStyle(StudioPrimaryButtonStyle())
        .disabled(viewModel.isRunning)
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

private extension RackTabView {
    func syncRackSelection() {
        guard !viewModel.tracks.isEmpty else {
            selectedRackTrackID = nil
            selectedRackPluginID = nil
            return
        }

        if selectedTrack == nil {
            selectedRackTrackID = viewModel.tracks.first?.id
        }

        if let track = selectedTrack {
            if let pluginID = selectedRackPluginID,
               track.plugins.contains(where: { $0.id == pluginID }) {
                return
            }
            selectedRackPluginID = track.plugins.first?.id
        }
    }

    private var selectedTrack: MultiTrackTrackConfiguration? {
        if let selectedRackTrackID,
           let track = viewModel.tracks.first(where: { $0.id == selectedRackTrackID }) {
            return track
        }
        return viewModel.tracks.first
    }

    private var selectedPlugin: MultiTrackTrackConfiguration.PluginInsert? {
        guard let track = selectedTrack else { return nil }
        if let selectedRackPluginID,
           let plugin = track.plugins.first(where: { $0.id == selectedRackPluginID }) {
            return plugin
        }
        return track.plugins.first
    }

    private func selectedPlugin(for track: MultiTrackTrackConfiguration) -> MultiTrackTrackConfiguration.PluginInsert? {
        if selectedRackTrackID == track.id,
           let selectedRackPluginID,
           let plugin = track.plugins.first(where: { $0.id == selectedRackPluginID }) {
            return plugin
        }
        return track.plugins.first
    }

    private var selectedPluginInfo: AudioUnitPluginInfo? {
        guard let pluginID = selectedPlugin?.pluginID else { return nil }
        return viewModel.plugins.first(where: { $0.id == pluginID })
    }

    private func openPluginSelection(
        trackID: UUID,
        insertID: UUID,
        insertTitle: String,
        emptyTitle: String
    ) {
        rackPluginSelectionRequest = RackTabPluginSelectionRequest(
            trackID: trackID,
            insertID: insertID,
            insertTitle: insertTitle,
            emptyTitle: emptyTitle
        )
    }

    private func currentPluginID(for request: RackTabPluginSelectionRequest) -> String? {
        guard let track = viewModel.tracks.first(where: { $0.id == request.trackID }),
              let insert = track.plugins.first(where: { $0.id == request.insertID }) else {
            return nil
        }

        return insert.pluginID
    }

    private func updatePluginID(trackID: UUID, insertID: UUID, newValue: String?) {
        guard let trackIndex = viewModel.tracks.firstIndex(where: { $0.id == trackID }),
              let pluginIndex = viewModel.tracks[trackIndex].plugins.firstIndex(where: { $0.id == insertID }) else {
            return
        }

        viewModel.tracks[trackIndex].plugins[pluginIndex].pluginID = newValue
        selectedRackTrackID = trackID
        selectedRackPluginID = viewModel.tracks[trackIndex].plugins[pluginIndex].id
        refreshEmbeddedPluginPane()
    }

    private func refreshEmbeddedPluginPane() {
        guard showsEmbeddedPluginPane, rackInspectorMode == .plugin else {
            viewModel.clearEmbeddedPluginEditor()
            return
        }
        guard let track = selectedTrack, let plugin = selectedPlugin, plugin.pluginID != nil else {
            viewModel.clearEmbeddedPluginEditor()
            return
        }

        viewModel.showEmbeddedPluginEditor(for: track.id, pluginID: plugin.id)
    }

    private var canPopOutInspector: Bool {
        switch rackInspectorMode {
        case .plugin:
            return viewModel.embeddedPluginEditorSession != nil
        case .tuning:
            return true
        }
    }

    private func popOutCurrentInspector() {
        switch rackInspectorMode {
        case .plugin:
            viewModel.popOutEmbeddedPluginEditor()
        case .tuning:
            popOutTuningInspector()
        }
    }

    private func saveChainPreset(for trackID: UUID) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = try? viewModel.chainPresetsDirectoryURL()
        panel.nameFieldStringValue = viewModel.suggestedChainPresetFilename(for: trackID)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            do {
                try await viewModel.saveChainPreset(for: trackID, to: url)
            } catch {
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }

    private func loadChainPreset(for trackID: UUID, onLoaded: @escaping () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = try? viewModel.chainPresetsDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            do {
                try await viewModel.loadChainPreset(for: trackID, from: url)
                onLoaded()
            } catch {
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }

    private func saveParameterPreset(for trackID: UUID) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = try? viewModel.parameterPresetsDirectoryURL()
        panel.nameFieldStringValue = viewModel.suggestedParameterPresetFilename(for: trackID)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            do {
                try await viewModel.saveParameterPreset(for: trackID, to: url)
            } catch {
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }

    private func loadParameterPreset(for trackID: UUID, onLoaded: @escaping () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = try? viewModel.parameterPresetsDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            do {
                try await viewModel.loadParameterPreset(for: trackID, from: url)
                onLoaded()
            } catch {
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }

    private func pluginSelectionTitle(for pluginID: String?, emptyTitle: String) -> String {
        guard let pluginID,
              let plugin = viewModel.plugins.first(where: { $0.id == pluginID }) else {
            return emptyTitle
        }

        return plugin.name
    }

    private func pluginSelectionButton(
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(StudioTheme.mutedText)
            }
            .font(.system(size: 10, weight: .medium, design: .default))
            .foregroundStyle(StudioTheme.strongText)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
