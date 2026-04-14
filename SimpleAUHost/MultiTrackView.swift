import AppKit
import SwiftUI

private enum MultiTrackWorkspaceTab: String, CaseIterable, Identifiable {
    case rack = "Rack"
    case show = "Show"
    case setup = "Setup"

    var id: String { rawValue }
}

private enum RackInspectorMode: String, CaseIterable, Identifiable {
    case plugin = "Plugin"
    case tuning = "Tuning"

    var id: String { rawValue }
}

private struct PendingSessionLoadRequest {
    let url: URL
    let sessionName: String
}

private struct RackPluginSelectionRequest: Identifiable {
    let trackID: UUID
    let insertID: UUID
    let insertTitle: String
    let emptyTitle: String

    var id: String {
        "\(trackID.uuidString)::\(insertID.uuidString)"
    }
}

struct MultiTrackView: View {
    @StateObject private var viewModel = MultiTrackViewModel()
    let closeCoordinator: AppCloseCoordinator
    @State private var selectedTab: MultiTrackWorkspaceTab = .rack
    @State private var showsDiagnostics = true
    @State private var showsEmbeddedPluginPane = true
    @State private var showsAddWavesTuneSongSheet = false
    @State private var rackInspectorMode: RackInspectorMode = .plugin
    @State private var selectedRackTrackID: UUID?
    @State private var selectedRackPluginID: UUID?
    @State private var pendingSessionLoadRequest: PendingSessionLoadRequest?
    @State private var rackPluginSelectionRequest: RackPluginSelectionRequest?
    @State private var draftWavesTuneSongTitle = ""
    @State private var draftWavesTuneSongKey = WavesTuneKeySelection()
    @State private var tuningPopoutPanel: NSPanel?

    init(closeCoordinator: AppCloseCoordinator) {
        self.closeCoordinator = closeCoordinator
    }

    var body: some View {
        StudioShell(
            eyebrow: "",
            title: "",
            subtitle: ""
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                workspaceTabs
                workspaceBody
            }
        }
        .task {
            viewModel.load()
            configureCloseHandling()
            syncRackSelection()
            updateTelemetryPublishing()
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
        .onChange(of: selectedTab) { _, _ in
            updateTelemetryPublishing()
            refreshEmbeddedPluginPane()
        }
        .onChange(of: rackInspectorMode) { _, _ in
            refreshEmbeddedPluginPane()
        }
        .onChange(of: showsDiagnostics) { _, _ in
            updateTelemetryPublishing()
        }
        .onChange(of: showsEmbeddedPluginPane) { _, _ in
            refreshEmbeddedPluginPane()
        }
        .onChange(of: viewModel.isRunning) { _, _ in
            updateTelemetryPublishing()
            refreshEmbeddedPluginPane()
        }
        .onDisappear {
            viewModel.setTelemetryPublishingEnabled(false)
            viewModel.clearEmbeddedPluginEditor()
            tuningPopoutPanel?.close()
            tuningPopoutPanel = nil
            closeCoordinator.updateHandler(nil)
        }
        .alert("Discard Unsaved Changes?", isPresented: Binding(
            get: { pendingSessionLoadRequest != nil },
            set: { isPresented in
                if !isPresented {
                    pendingSessionLoadRequest = nil
                }
            }
        )) {
            Button("Cancel", role: .cancel) {
                pendingSessionLoadRequest = nil
            }

            Button("Load", role: .destructive) {
                if let request = pendingSessionLoadRequest {
                    performSessionLoad(from: request.url)
                }
                pendingSessionLoadRequest = nil
            }
        } message: {
            Text("Load \(pendingSessionLoadRequest?.sessionName ?? "this show") and discard the current unsaved changes?")
        }
        .sheet(isPresented: $showsAddWavesTuneSongSheet) {
            addWavesTuneSongSheet
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

    private var workspaceTabs: some View {
        HStack(spacing: 8) {
            sessionTitleView
            workspaceTabButtons

            Spacer()

            rackTabActions
                .opacity(selectedTab == .rack ? 1 : 0)
                .allowsHitTesting(selectedTab == .rack)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.20))
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var sessionTitleView: some View {
        Text(viewModel.currentSessionDisplayName)
            .font(.system(size: 14, weight: .semibold, design: .default))
            .foregroundStyle(StudioTheme.strongText)
            .lineLimit(1)
    }

    private var workspaceTabButtons: some View {
        HStack(spacing: 0) {
            ForEach(MultiTrackWorkspaceTab.allCases) { tab in
                workspaceTabButton(for: tab)
            }
        }
    }

    private func workspaceTabButton(for tab: MultiTrackWorkspaceTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Text(tab.rawValue.uppercased())
                .font(.system(size: 11, weight: .medium, design: .default))
                .tracking(1.0)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(tabBackground(for: tab))
                .foregroundStyle(tabForeground(for: tab))
        }
        .buttonStyle(.plain)
    }

    private func tabBackground(for tab: MultiTrackWorkspaceTab) -> some ShapeStyle {
        selectedTab == tab ? Color.white.opacity(0.06) : Color.clear
    }

    private func tabForeground(for tab: MultiTrackWorkspaceTab) -> Color {
        selectedTab == tab ? StudioTheme.accent : StudioTheme.mutedText
    }

    private var rackTabActions: some View {
        HStack(spacing: 12) {
            Button {
                showsEmbeddedPluginPane.toggle()
            } label: {
                Label(showsEmbeddedPluginPane ? "Hide Panel" : "Show Panel", systemImage: showsEmbeddedPluginPane ? "sidebar.right" : "rectangle.split.2x1")
            }
            .buttonStyle(StudioSecondaryButtonStyle())

            startStopButton
            addMonoTrackButton
            addStereoTrackButton
        }
    }

    private var startStopButton: some View {
        Group {
            if viewModel.isRunning {
                Button {
                    viewModel.toggleStartStop()
                } label: {
                    Label("Running", systemImage: "stop.fill")
                }
                .buttonStyle(StudioDestructiveButtonStyle())
            } else {
                Button {
                    viewModel.toggleStartStop()
                } label: {
                    Label("Stopped", systemImage: "play.fill")
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(!viewModel.canStart)
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

    @ViewBuilder
    private var workspaceBody: some View {
        switch selectedTab {
        case .rack:
            rackWorkspace
        case .show:
            showWorkspace
        case .setup:
            setupWorkspace
        }
    }

    private var rackWorkspace: some View {
        HSplitView {
            rackStripBoard
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if showsEmbeddedPluginPane {
                rackInspectorPane
                    .frame(minWidth: 460, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var showWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sessionActionPanel
                managedSessionsPanel
                showStatusPanel
                diagnosticsPanel
            }
            .padding(.bottom, 8)
        }
    }

    private var setupWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sessionOverviewPanel
                bufferingPanel
                companionControlPanel
            }
            .padding(.bottom, 8)
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
                    ForEach(RackInspectorMode.allCases) { mode in
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    compactMetricCard(
                        title: "Instances",
                        value: "\(viewModel.configuredWavesTuneRealtimeInsertCount)",
                        tint: viewModel.configuredWavesTuneRealtimeInsertCount > 0 ? StudioTheme.accent : StudioTheme.mutedText
                    )
                    compactMetricCard(title: "Applied", value: viewModel.appliedWavesTuneKeyTitle)
                    compactMetricCard(
                        title: "State",
                        value: viewModel.wavesTuneState.isEnabled ? "Active" : "Bypassed",
                        tint: viewModel.wavesTuneState.isEnabled ? StudioTheme.accent : StudioTheme.warning
                    )
                }

                Toggle("Tune Active", isOn: Binding(
                    get: { viewModel.wavesTuneState.isEnabled },
                    set: { viewModel.setWavesTuneEnabled($0) }
                ))
                .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            StudioFieldLabel("Setlist")
                            Text(viewModel.selectedWavesTuneSongTitle)
                                .font(.system(size: 13, weight: .semibold, design: .default))
                                .foregroundStyle(StudioTheme.strongText)
                            Text(selectedWavesTuneSongSummary)
                                .font(.system(size: 10, weight: .regular, design: .default))
                                .foregroundStyle(StudioTheme.mutedText)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 8) {
                            Button("Key Panic") {
                                viewModel.triggerWavesTuneKeyPanic()
                            }
                            .buttonStyle(StudioDestructiveButtonStyle())

                            Button {
                                viewModel.stepWavesTuneSong(direction: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(StudioSecondaryButtonStyle())
                            .disabled(!viewModel.canSelectPreviousWavesTuneSong)

                            Button {
                                viewModel.stepWavesTuneSong(direction: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(StudioSecondaryButtonStyle())
                            .disabled(!viewModel.canSelectNextWavesTuneSong)

                            Button("Add Song") {
                                presentAddWavesTuneSongSheet()
                            }
                            .buttonStyle(StudioSecondaryButtonStyle())
                        }
                    }

                    if viewModel.wavesTuneSongs.isEmpty {
                        Text("Add songs in show order. Selecting a song or stepping next/previous applies its key immediately.")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.mutedText)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(Array(viewModel.wavesTuneSongs.enumerated()), id: \.element.id) { index, song in
                                wavesTuneSongRow(song, index: index)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        StudioFieldLabel("Scale")
                        Picker("Scale", selection: Binding(
                            get: { viewModel.wavesTuneState.stagedKey.scaleMode },
                            set: { viewModel.setWavesTuneScaleMode($0) }
                        )) {
                            ForEach(WavesTuneScaleMode.allCases) { scaleMode in
                                Text(scaleMode.title).tag(scaleMode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        StudioFieldLabel("Accidental")
                        HStack(spacing: 4) {
                            ForEach(WavesTuneAccidental.allCases) { accidental in
                                let isAllowed = WavesTuneKeySelection.supports(
                                    accidental: accidental,
                                    for: viewModel.wavesTuneState.stagedKey.noteLetter
                                )
                                tuningChoiceButton(
                                    title: accidental.title,
                                    isSelected: viewModel.wavesTuneState.stagedKey.accidental == accidental,
                                    isEnabled: isAllowed
                                ) {
                                    viewModel.setWavesTuneAccidental(accidental)
                                }
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                HStack(spacing: 4) {
                    ForEach(WavesTuneNoteLetter.allCases) { noteLetter in
                        tuningChoiceButton(
                            title: noteLetter.title,
                            isSelected: viewModel.wavesTuneState.stagedKey.noteLetter == noteLetter
                        ) {
                            viewModel.setWavesTuneNoteLetter(noteLetter)
                        }
                    }
                }

                if viewModel.configuredWavesTuneRealtimeInsertCount == 0 {
                    Text("Add a Waves Tune Real-Time insert to any enabled track to use these controls.")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.mutedText)
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Staged")
                            .font(.system(size: 9, weight: .medium, design: .default))
                            .tracking(1.0)
                            .foregroundStyle(StudioTheme.mutedText)
                        Text(viewModel.stagedWavesTuneKeyTitle)
                            .font(.system(size: 13, weight: .semibold, design: .default))
                            .foregroundStyle(StudioTheme.strongText)
                    }

                    Spacer()

                    Button("Save Song Key") {
                        viewModel.saveStagedKeyToSelectedWavesTuneSong()
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(!viewModel.canSaveStagedKeyToSelectedWavesTuneSong)

                    Button("Apply") {
                        viewModel.applyStagedWavesTuneKey()
                    }
                    .buttonStyle(StudioPrimaryButtonStyle())
                    .disabled(!viewModel.canApplyStagedWavesTuneKey)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var addWavesTuneSongSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Song")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(StudioTheme.strongText)

            VStack(alignment: .leading, spacing: 8) {
                StudioFieldLabel("Song Name")
                TextField("Song title", text: $draftWavesTuneSongTitle)
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

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    StudioFieldLabel("Scale")
                    Picker("Song Scale", selection: $draftWavesTuneSongKey.scaleMode) {
                        ForEach(WavesTuneScaleMode.allCases) { scaleMode in
                            Text(scaleMode.title).tag(scaleMode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    StudioFieldLabel("Accidental")
                    HStack(spacing: 4) {
                        ForEach(WavesTuneAccidental.allCases) { accidental in
                            let isAllowed = WavesTuneKeySelection.supports(
                                accidental: accidental,
                                for: draftWavesTuneSongKey.noteLetter
                            )
                            tuningChoiceButton(
                                title: accidental.title,
                                isSelected: draftWavesTuneSongKey.accidental == accidental,
                                isEnabled: isAllowed
                            ) {
                                draftWavesTuneSongKey.accidental = accidental
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 4) {
                ForEach(WavesTuneNoteLetter.allCases) { noteLetter in
                    tuningChoiceButton(
                        title: noteLetter.title,
                        isSelected: draftWavesTuneSongKey.noteLetter == noteLetter
                    ) {
                        draftWavesTuneSongKey.noteLetter = noteLetter
                        draftWavesTuneSongKey.normalize()
                    }
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Key")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(StudioTheme.mutedText)
                    Text(draftWavesTuneSongKey.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(StudioTheme.strongText)
                }

                Spacer()

                Button("Cancel") {
                    dismissAddWavesTuneSongSheet()
                }
                .buttonStyle(StudioSecondaryButtonStyle())

                Button("Add Song") {
                    confirmAddWavesTuneSong()
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                .disabled(!canConfirmAddWavesTuneSong)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(StudioTheme.panelFill)
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

    private var selectedTrackCount: Int {
        viewModel.tracks.filter(\.isEnabled).count
    }

    private var selectedPluginInfoForRack: AudioUnitPluginInfo? {
        guard let pluginID = selectedPlugin?.pluginID else { return nil }
        return viewModel.plugins.first(where: { $0.id == pluginID })
    }

    private func openSelectedPluginEditor() {
        guard let track = selectedTrack else { return }
        if let plugin = selectedPlugin {
            viewModel.openPluginEditor(for: track.id, pluginID: plugin.id)
        } else {
            viewModel.openPluginEditor(for: track.id)
        }
    }

    private func removeSelectedInsert() {
        guard let track = selectedTrack, let plugin = selectedPlugin else { return }
        viewModel.removePluginInsert(trackID: track.id, pluginID: plugin.id)
        syncRackSelection()
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

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(plugin.wrappedValue.pluginID == nil ? Color.white.opacity(0.15) : StudioTheme.accent)
                    .frame(width: 6, height: 6)
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .medium, design: .default))
                    .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.mutedText)
                Spacer()
                if plugin.wrappedValue.pluginID != nil {
                    Button {
                        viewModel.openPluginEditor(for: trackID, pluginID: plugin.wrappedValue.id)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.mutedText)
                    .disabled(!viewModel.canOpenPluginEditor(for: plugin.wrappedValue))
                }
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
        return rackControlRow(title: "Input") {
            Picker("Input", selection: track.inputStartChannel) {
                ForEach(channels, id: \.self) { channel in
                    Text(channelLabel(startChannel: channel, layout: value.layout)).tag(channel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(viewModel.isRunning || channels.isEmpty)
        }
    }

    private func rackOutputControl(_ track: Binding<MultiTrackTrackConfiguration>) -> some View {
        let value = track.wrappedValue
        let channels = viewModel.availableOutputStartChannels(for: value)
        return rackControlRow(title: "Output") {
            Picker("Output", selection: track.outputStartChannel) {
                ForEach(channels, id: \.self) { channel in
                    Text(channelLabel(startChannel: channel, layout: value.layout)).tag(channel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(viewModel.isRunning || channels.isEmpty)
        }
    }

    private func rackModeControl(_ track: Binding<MultiTrackTrackConfiguration>) -> some View {
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

            // FX clipboard + presets in a compact icon-labeled grid
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
                    loadChainPreset(for: value.id)
                    if selectedRackTrackID == value.id {
                        selectedRackPluginID = viewModel.tracks.first(where: { $0.id == value.id })?.plugins.first?.id
                    }
                }
                .disabled(viewModel.isRunning)

                rackFooterButton("Params", icon: "slider.horizontal.3") {
                    saveParameterPreset(for: value.id)
                }
                .disabled(!value.hasPlugins)

                rackFooterButton("Params", icon: "square.and.arrow.up.on.square") {
                    loadParameterPreset(for: value.id)
                    if selectedRackTrackID == value.id {
                        selectedRackPluginID = viewModel.tracks.first(where: { $0.id == value.id })?.plugins.first?.id
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

    private var sessionActionPanel: some View {
        StudioPanel("Show", subtitle: "Manage the session file and core transport actions for this show.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button("New Show") {
                        viewModel.createNewSession()
                        syncRackSelection()
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(viewModel.isRunning)

                    Button("Open Show") {
                        openSessionPanel()
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(viewModel.isRunning)

                    Button("Save") {
                        do {
                            if viewModel.hasStoredSessionFile {
                                try viewModel.saveSession()
                            } else {
                                saveSessionAs()
                            }
                        } catch {
                            viewModel.statusMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(StudioPrimaryButtonStyle())

                    Button("Save As") {
                        saveSessionAs()
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                }

                HStack(spacing: 12) {
                    Button("Refresh Devices") {
                        viewModel.load()
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(viewModel.isRunning)

                    Button(viewModel.isRunning ? "Stop Engine" : "Start Engine") {
                        viewModel.toggleStartStop()
                    }
                    .buttonStyle(StudioPrimaryButtonStyle())
                    .disabled(!viewModel.canStart && !viewModel.isRunning)
                }
            }
        }
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
                requestSessionLoad(from: session.url)
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

    private var sessionOverviewPanel: some View {
        StudioPanel("I/O Setup", subtitle: "Global interfaces and hardware buffer shared by all tracks in the current show.") {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        setupDevicePicker(
                            title: "Input Interface",
                            selection: $viewModel.selectedInputDeviceID,
                            devices: viewModel.inputDevices
                        ) {
                            viewModel.handleDeviceSelectionChange()
                        }

                        setupDevicePicker(
                            title: "Output Interface",
                            selection: $viewModel.selectedOutputDeviceID,
                            devices: viewModel.outputDevices
                        ) {
                            viewModel.handleDeviceSelectionChange()
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        setupDevicePicker(
                            title: "Input Interface",
                            selection: $viewModel.selectedInputDeviceID,
                            devices: viewModel.inputDevices
                        ) {
                            viewModel.handleDeviceSelectionChange()
                        }

                        setupDevicePicker(
                            title: "Output Interface",
                            selection: $viewModel.selectedOutputDeviceID,
                            devices: viewModel.outputDevices
                        ) {
                            viewModel.handleDeviceSelectionChange()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    StudioFieldLabel("Hardware Buffer")
                    ScrollView(.horizontal, showsIndicators: false) {
                        Picker("Hardware buffer size", selection: $viewModel.selectedBufferSize) {
                            ForEach(viewModel.availableBufferSizes, id: \.self) { size in
                                Text("\(size) frames").tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(minWidth: 780)
                        .onChange(of: viewModel.selectedBufferSize) { _, newValue in
                            viewModel.customBufferSizeText = String(newValue)
                        }
                    }

                    HStack(spacing: 10) {
                        TextField("Custom frames", text: $viewModel.customBufferSizeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                            .onSubmit {
                                viewModel.applyCustomBufferSize()
                            }

                        Button("Apply") {
                            viewModel.applyCustomBufferSize()
                        }
                        .buttonStyle(StudioSecondaryButtonStyle())
                        .disabled(viewModel.isBusy || viewModel.isRunning)
                    }

                    Text(viewModel.bufferSizeHelpText)
                        .font(.caption)
                        .foregroundStyle(StudioTheme.mutedText)
                }
            }
            .disabled(viewModel.isBusy || viewModel.isRunning)
        }
    }

    private var bufferingPanel: some View {
        StudioPanel("Latency Setup", subtitle: "Buffered and broadcast tracks use larger internal blocks than the hardware buffer.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    StudioFieldLabel("Realtime")
                    Spacer()
                    Text("\(viewModel.selectedBufferSize) frames")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(StudioTheme.accent)
                }

                Text("Buffered and Broadcast/Post must be whole multiples of the hardware buffer size.")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.mutedText)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        latencyField(title: "Buffered", text: $viewModel.bufferedInternalBufferText, action: viewModel.applyBufferedInternalBufferSize)
                        latencyField(title: "Broadcast/Post", text: $viewModel.broadcastInternalBufferText, action: viewModel.applyBroadcastInternalBufferSize)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        latencyField(title: "Buffered", text: $viewModel.bufferedInternalBufferText, action: viewModel.applyBufferedInternalBufferSize)
                        latencyField(title: "Broadcast/Post", text: $viewModel.broadcastInternalBufferText, action: viewModel.applyBroadcastInternalBufferSize)
                    }
                }
            }
        }
    }

    private var companionControlPanel: some View {
        StudioPanel("Companion Control", subtitle: "Local HTTP endpoint for Bitfocus Companion or other control surfaces.") {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StudioMetricTile("Endpoint", value: viewModel.companionControlEndpointURLString, tint: StudioTheme.accent)
                    StudioMetricTile("Status", value: viewModel.companionControlStatus)
                    StudioMetricTile("Scope", value: "Multi Track mode only")
                    StudioMetricTile("Actions", value: "Enable, panic, stage key, apply, next/previous song")
                }

                Text("Companion can poll `GET /api/v1/state` and trigger POST actions under `/api/v1/actions/waves-tune/...`. The displayed endpoint uses 127.0.0.1, which is the intended address when Companion runs on the same Mac.")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trackToolbarPanel: some View {
        StudioPanel("Track Setup", subtitle: "Add mono or stereo strips before arranging them in the rack.") {
            HStack(spacing: 12) {
                Button("Add Mono Track") {
                    viewModel.addMonoTrack()
                    syncRackSelection()
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(viewModel.isRunning)

                Button("Add Stereo Track") {
                    viewModel.addStereoTrack()
                    syncRackSelection()
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                .disabled(viewModel.isRunning)
            }
        }
    }

    private var setupTrackGrid: some View {
        StudioPanel("Track Details", subtitle: "Detailed routing and insert configuration for each strip.") {
            LazyVStack(spacing: 16) {
                ForEach($viewModel.tracks) { $track in
                    setupTrackCard($track)
                }
            }
        }
    }

    private func setupTrackCard(_ track: Binding<MultiTrackTrackConfiguration>) -> some View {
        let value = track.wrappedValue

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(value.name)
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(StudioTheme.strongText)

                Spacer()

                Button("Save Chain") {
                    saveChainPreset(for: value.id)
                }
                .buttonStyle(StudioSecondaryButtonStyle())

                Button("Load Chain") {
                    loadChainPreset(for: value.id)
                    if selectedRackTrackID == value.id {
                        selectedRackPluginID = viewModel.tracks.first(where: { $0.id == value.id })?.plugins.first?.id
                    }
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(viewModel.isRunning)

                Button("Save Parameters") {
                    saveParameterPreset(for: value.id)
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(!value.hasPlugins)

                Button("Load Parameters") {
                    loadParameterPreset(for: value.id)
                    if selectedRackTrackID == value.id {
                        selectedRackPluginID = viewModel.tracks.first(where: { $0.id == value.id })?.plugins.first?.id
                    }
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(!value.hasPlugins)

                Button("Focus In Rack") {
                    selectedTab = .rack
                    selectedRackTrackID = value.id
                    selectedRackPluginID = value.plugins.first?.id
                }
                .buttonStyle(StudioSecondaryButtonStyle())

                Button("Remove Track") {
                    viewModel.removeTrack(id: value.id)
                    syncRackSelection()
                }
                .buttonStyle(StudioDestructiveButtonStyle())
                .disabled(viewModel.isRunning)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    trackSettingsForm(track, value: value)
                    trackInsertList(track, value: value)
                }

                VStack(alignment: .leading, spacing: 16) {
                    trackSettingsForm(track, value: value)
                    trackInsertList(track, value: value)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func trackSettingsForm(_ track: Binding<MultiTrackTrackConfiguration>, value: MultiTrackTrackConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioFieldLabel("Track Name")
            TextField("Track name", text: track.name)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isRunning)

            Toggle("Enabled", isOn: track.isEnabled)
                .toggleStyle(.switch)
                .disabled(viewModel.isRunning)

            StudioFieldLabel("Layout")
            Picker("Layout", selection: track.layout) {
                ForEach(TrackChannelLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(viewModel.isRunning)
            .onChange(of: track.wrappedValue.layout) { _, _ in
                viewModel.sanitizeTrack(id: value.id)
            }

            StudioFieldLabel("Latency Class")
            Picker("Latency class", selection: track.latencyClass) {
                ForEach(TrackLatencyClass.allCases) { latencyClass in
                    Text(latencyClass.title).tag(latencyClass)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(viewModel.isRunning)

            StudioFieldLabel("Input Start Channel")
            Picker("Input start channel", selection: track.inputStartChannel) {
                ForEach(viewModel.availableInputStartChannels(for: value), id: \.self) { channel in
                    Text("Channel \(channel)").tag(channel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(viewModel.isRunning || viewModel.availableInputStartChannels(for: value).isEmpty)

            StudioFieldLabel("Output Start Channel")
            Picker("Output start channel", selection: track.outputStartChannel) {
                ForEach(viewModel.availableOutputStartChannels(for: value), id: \.self) { channel in
                    Text("Channel \(channel)").tag(channel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(viewModel.isRunning || viewModel.availableOutputStartChannels(for: value).isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trackInsertList(_ track: Binding<MultiTrackTrackConfiguration>, value: MultiTrackTrackConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("INSERTS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(StudioTheme.accent)

                Spacer()

                Button("Add Plugin") {
                    viewModel.addPluginInsert(to: value.id)
                    selectedRackTrackID = value.id
                    selectedRackPluginID = viewModel.tracks.first(where: { $0.id == value.id })?.plugins.last?.id
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(viewModel.isRunning)
            }

            if value.plugins.isEmpty {
                Text("No inserts on this track.")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.mutedText)
            } else {
                ForEach(Array(track.plugins.enumerated()), id: \.element.id) { index, plugin in
                    pluginRow(trackID: value.id, plugin: plugin, index: index, totalCount: value.plugins.count)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pluginRow(
        trackID: UUID,
        plugin: Binding<MultiTrackTrackConfiguration.PluginInsert>,
        index: Int,
        totalCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(viewModel.pluginInsertLabel(for: plugin.wrappedValue, index: index))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(StudioTheme.mutedText)

                Spacer()

                Button {
                    viewModel.movePluginInsert(trackID: trackID, pluginID: plugin.wrappedValue.id, direction: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRunning || index == 0)

                Button {
                    viewModel.movePluginInsert(trackID: trackID, pluginID: plugin.wrappedValue.id, direction: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRunning || index == totalCount - 1)

                Button("Focus") {
                    selectedTab = .rack
                    selectedRackTrackID = trackID
                    selectedRackPluginID = plugin.wrappedValue.id
                }
                .buttonStyle(.borderless)

                Button("Remove", role: .destructive) {
                    viewModel.removePluginInsert(trackID: trackID, pluginID: plugin.wrappedValue.id)
                    syncRackSelection()
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRunning)
            }

            pluginSelectionButton(
                title: pluginSelectionTitle(for: plugin.wrappedValue.pluginID, emptyTitle: "Bypass")
            ) {
                openPluginSelection(
                    trackID: trackID,
                    insertID: plugin.wrappedValue.id,
                    insertTitle: viewModel.pluginInsertLabel(for: plugin.wrappedValue, index: index),
                    emptyTitle: "Bypass"
                )
            }
            .disabled(viewModel.isRunning)

            Button("Open Plugin UI") {
                viewModel.openPluginEditor(for: trackID, pluginID: plugin.wrappedValue.id)
            }
            .buttonStyle(StudioSecondaryButtonStyle())
            .disabled(!viewModel.canOpenPluginEditor(for: plugin.wrappedValue))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
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
                        StudioMetricTile("Engine", value: viewModel.statusMessage)
                    }
                }
            }
        }
    }

    private func setupDevicePicker(
        title: String,
        selection: Binding<AudioDeviceID?>,
        devices: [AudioDeviceInfo],
        onChange: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioFieldLabel(title)
            Picker(title, selection: selection) {
                ForEach(devices) { device in
                    Text(device.displayName).tag(Optional(device.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: selection.wrappedValue) { _, _ in
                onChange()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func latencyField(
        title: String,
        text: Binding<String>,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioFieldLabel(title)
            HStack(spacing: 10) {
                TextField("Frames", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit {
                        action()
                    }

                Button("Apply") {
                    action()
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(viewModel.isBusy || viewModel.isRunning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func rackMiniLabel(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium, design: .default))
                .tracking(0.8)
                .foregroundStyle(StudioTheme.mutedText)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioTheme.strongText)
        }
    }

    private func rackControlRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium, design: .default))
                .tracking(0.8)
                .foregroundStyle(StudioTheme.mutedText)
                .frame(width: 48, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func tuningChoiceButton(
        title: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
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

    private func compactMetricCard(
        title: String,
        value: String,
        tint: Color = StudioTheme.strongText
    ) -> some View {
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

    private func wavesTuneSongRow(_ song: WavesTuneSongEntry, index: Int) -> some View {
        let isSelected = viewModel.wavesTuneState.selectedSongID == song.id

        return HStack(spacing: 6) {
            Button {
                viewModel.selectWavesTuneSong(song.id)
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

            TextField(
                "Song \(index + 1)",
                text: Binding(
                    get: { song.title },
                    set: { viewModel.updateWavesTuneSongTitle(song.id, title: $0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .default))
            .foregroundStyle(StudioTheme.strongText)

            Button(song.key.title) {
                viewModel.selectWavesTuneSong(song.id)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium, design: .default))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? StudioTheme.accent.opacity(0.15) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(isSelected ? StudioTheme.accent.opacity(0.50) : Color.white.opacity(0.06), lineWidth: 1)
            )
            .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.strongText)

            Button {
                viewModel.removeWavesTuneSong(song.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.warning)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? StudioTheme.accent.opacity(0.08) : Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? StudioTheme.accent.opacity(0.30) : Color.white.opacity(0.05), lineWidth: 1)
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

    private func selectedTrackRoutingSummary(_ track: MultiTrackTrackConfiguration) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StudioMetricTile("Input", value: "Channel \(track.inputStartChannel)")
            StudioMetricTile("Output", value: "Channel \(track.outputStartChannel)")
            StudioMetricTile("Inserts", value: "\(track.plugins.count)")
            StudioMetricTile("Internal Buffer", value: viewModel.internalBufferDescription(for: track))
        }
    }

    private func syncRackSelection() {
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

    private var canOpenSelectedPluginUI: Bool {
        guard let plugin = selectedPlugin else { return false }
        return viewModel.canOpenPluginEditor(for: plugin)
    }

    private func openPluginSelection(
        trackID: UUID,
        insertID: UUID,
        insertTitle: String,
        emptyTitle: String
    ) {
        rackPluginSelectionRequest = RackPluginSelectionRequest(
            trackID: trackID,
            insertID: insertID,
            insertTitle: insertTitle,
            emptyTitle: emptyTitle
        )
    }

    private func currentPluginID(for request: RackPluginSelectionRequest) -> String? {
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
        guard selectedTab == .rack, showsEmbeddedPluginPane, rackInspectorMode == .plugin else {
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

    private func popOutTuningInspector() {
        if let existing = tuningPopoutPanel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let tuningView = TuningPopoutView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: tuningView)
        hostingController.preferredContentSize = NSSize(width: 480, height: 600)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Waves Tune Control"
        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        tuningPopoutPanel = panel
    }

    private func updateTelemetryPublishing() {
        let shouldPublishTelemetry = viewModel.isRunning && selectedTab == .show && showsDiagnostics
        viewModel.setTelemetryPublishingEnabled(shouldPublishTelemetry)
    }

    private func openSessionPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.simpleAUHostMultiTrackSession, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = try? viewModel.managedSessionsDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        requestSessionLoad(from: url)
    }

    private func configureCloseHandling() {
        closeCoordinator.updateHandler(
            .init(
                hasUnsavedChanges: { viewModel.hasUnsavedChanges },
                documentName: { viewModel.currentSessionName },
                save: { saveCurrentSessionForClose() }
            )
        )
    }

    @discardableResult
    private func saveCurrentSessionForClose() -> Bool {
        do {
            if viewModel.hasStoredSessionFile {
                try viewModel.saveSession()
                return true
            }
            return saveSessionAs()
        } catch {
            viewModel.statusMessage = error.localizedDescription
            presentErrorAlert(error)
            return false
        }
    }

    @discardableResult
    private func saveSessionAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.simpleAUHostMultiTrackSession]
        panel.canCreateDirectories = true
        panel.directoryURL = try? viewModel.managedSessionsDirectoryURL()
        panel.nameFieldStringValue = viewModel.suggestedSessionFilename()

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        do {
            try viewModel.saveSession(to: url)
            return true
        } catch {
            viewModel.statusMessage = error.localizedDescription
            presentErrorAlert(error)
            return false
        }
    }

    private func presentErrorAlert(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private func saveChainPreset(for trackID: UUID) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = try? viewModel.chainPresetsDirectoryURL()
        panel.nameFieldStringValue = viewModel.suggestedChainPresetFilename(for: trackID)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try viewModel.saveChainPreset(for: trackID, to: url)
        } catch {
            viewModel.statusMessage = error.localizedDescription
        }
    }

    private func loadChainPreset(for trackID: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = try? viewModel.chainPresetsDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try viewModel.loadChainPreset(for: trackID, from: url)
        } catch {
            viewModel.statusMessage = error.localizedDescription
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

        do {
            try viewModel.saveParameterPreset(for: trackID, to: url)
        } catch {
            viewModel.statusMessage = error.localizedDescription
        }
    }

    private func loadParameterPreset(for trackID: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = try? viewModel.parameterPresetsDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try viewModel.loadParameterPreset(for: trackID, from: url)
        } catch {
            viewModel.statusMessage = error.localizedDescription
        }
    }

    private func requestSessionLoad(from url: URL) {
        let sessionName = url.deletingPathExtension().lastPathComponent
        if viewModel.hasUnsavedChanges {
            pendingSessionLoadRequest = PendingSessionLoadRequest(url: url, sessionName: sessionName)
            return
        }

        performSessionLoad(from: url)
    }

    private func performSessionLoad(from url: URL) {
        do {
            try viewModel.loadSession(from: url)
            syncRackSelection()
        } catch {
            viewModel.statusMessage = error.localizedDescription
        }
    }

    private func trimmedTelemetry(_ value: String, prefix: String) -> String {
        value.replacingOccurrences(of: prefix, with: "")
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

private struct TuningPopoutView: View {
    @ObservedObject var viewModel: MultiTrackViewModel
    @State private var showsAddSongSheet = false
    @State private var draftSongTitle = ""
    @State private var draftSongKey = WavesTuneKeySelection()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    metricCard(
                        title: "Instances",
                        value: "\(viewModel.configuredWavesTuneRealtimeInsertCount)",
                        tint: viewModel.configuredWavesTuneRealtimeInsertCount > 0 ? StudioTheme.accent : StudioTheme.mutedText
                    )
                    metricCard(title: "Applied", value: viewModel.appliedWavesTuneKeyTitle)
                    metricCard(
                        title: "State",
                        value: viewModel.wavesTuneState.isEnabled ? "Active" : "Bypassed",
                        tint: viewModel.wavesTuneState.isEnabled ? StudioTheme.accent : StudioTheme.warning
                    )
                }

                Toggle("Tune Active", isOn: Binding(
                    get: { viewModel.wavesTuneState.isEnabled },
                    set: { viewModel.setWavesTuneEnabled($0) }
                ))
                .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            StudioFieldLabel("Setlist")
                            Text(viewModel.selectedWavesTuneSongTitle)
                                .font(.system(size: 13, weight: .semibold, design: .default))
                                .foregroundStyle(StudioTheme.strongText)
                            Text(songSummary)
                                .font(.system(size: 10, weight: .regular, design: .default))
                                .foregroundStyle(StudioTheme.mutedText)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 8) {
                            Button("Key Panic") {
                                viewModel.triggerWavesTuneKeyPanic()
                            }
                            .buttonStyle(StudioDestructiveButtonStyle())

                            Button {
                                viewModel.stepWavesTuneSong(direction: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(StudioSecondaryButtonStyle())
                            .disabled(!viewModel.canSelectPreviousWavesTuneSong)

                            Button {
                                viewModel.stepWavesTuneSong(direction: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(StudioSecondaryButtonStyle())
                            .disabled(!viewModel.canSelectNextWavesTuneSong)

                            Button("Add Song") {
                                draftSongTitle = ""
                                draftSongKey = WavesTuneKeySelection()
                                showsAddSongSheet = true
                            }
                            .buttonStyle(StudioSecondaryButtonStyle())
                        }
                    }

                    if viewModel.wavesTuneSongs.isEmpty {
                        Text("Add songs in show order. Selecting a song or stepping next/previous applies its key immediately.")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.mutedText)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(Array(viewModel.wavesTuneSongs.enumerated()), id: \.element.id) { index, song in
                                songRow(song, index: index)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        StudioFieldLabel("Scale")
                        Picker("Scale", selection: Binding(
                            get: { viewModel.wavesTuneState.stagedKey.scaleMode },
                            set: { viewModel.setWavesTuneScaleMode($0) }
                        )) {
                            ForEach(WavesTuneScaleMode.allCases) { scaleMode in
                                Text(scaleMode.title).tag(scaleMode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        StudioFieldLabel("Accidental")
                        HStack(spacing: 4) {
                            ForEach(WavesTuneAccidental.allCases) { accidental in
                                let isAllowed = WavesTuneKeySelection.supports(
                                    accidental: accidental,
                                    for: viewModel.wavesTuneState.stagedKey.noteLetter
                                )
                                choiceButton(
                                    title: accidental.title,
                                    isSelected: viewModel.wavesTuneState.stagedKey.accidental == accidental,
                                    isEnabled: isAllowed
                                ) {
                                    viewModel.setWavesTuneAccidental(accidental)
                                }
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                HStack(spacing: 4) {
                    ForEach(WavesTuneNoteLetter.allCases) { noteLetter in
                        choiceButton(
                            title: noteLetter.title,
                            isSelected: viewModel.wavesTuneState.stagedKey.noteLetter == noteLetter
                        ) {
                            viewModel.setWavesTuneNoteLetter(noteLetter)
                        }
                    }
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Staged")
                            .font(.system(size: 9, weight: .medium, design: .default))
                            .tracking(1.0)
                            .foregroundStyle(StudioTheme.mutedText)
                        Text(viewModel.stagedWavesTuneKeyTitle)
                            .font(.system(size: 13, weight: .semibold, design: .default))
                            .foregroundStyle(StudioTheme.strongText)
                    }

                    Spacer()

                    Button("Save Song Key") {
                        viewModel.saveStagedKeyToSelectedWavesTuneSong()
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(!viewModel.canSaveStagedKeyToSelectedWavesTuneSong)

                    Button("Apply") {
                        viewModel.applyStagedWavesTuneKey()
                    }
                    .buttonStyle(StudioPrimaryButtonStyle())
                    .disabled(!viewModel.canApplyStagedWavesTuneKey)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 440, minHeight: 400)
        .background(StudioTheme.panelFill)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsAddSongSheet) {
            addSongSheet
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

    private var addSongSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Song")
                .font(.system(size: 16, weight: .semibold, design: .default))
                .foregroundStyle(StudioTheme.strongText)

            TextField("Song title", text: $draftSongTitle)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { showsAddSongSheet = false }
                    .buttonStyle(StudioSecondaryButtonStyle())
                Button("Add") {
                    let title = draftSongTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    viewModel.addWavesTuneSong(title: title, key: draftSongKey)
                    showsAddSongSheet = false
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                .disabled(draftSongTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(StudioTheme.panelFill)
    }

    private func songRow(_ song: WavesTuneSongEntry, index: Int) -> some View {
        let isSelected = viewModel.wavesTuneState.selectedSongID == song.id

        return HStack(spacing: 6) {
            Button {
                viewModel.selectWavesTuneSong(song.id)
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

            Text(song.title)
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundStyle(StudioTheme.strongText)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(song.key.title)
                .font(.system(size: 10, weight: .medium, design: .default))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isSelected ? StudioTheme.accent.opacity(0.15) : Color.white.opacity(0.04))
                )
                .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.strongText)

            Button {
                viewModel.removeWavesTuneSong(song.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.warning)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? StudioTheme.accent.opacity(0.08) : Color.white.opacity(0.025))
        )
    }

    private func metricCard(title: String, value: String, tint: Color = StudioTheme.strongText) -> some View {
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
    }

    private func choiceButton(
        title: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
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

private struct EmbeddedPluginEditorContainer: NSViewControllerRepresentable {
    let viewController: NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        HostingEditorViewController(contentViewController: viewController)
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        guard let hostingController = nsViewController as? HostingEditorViewController else { return }
        hostingController.setContentViewController(viewController)
    }
}

private struct RackPluginSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let emptyTitle: String
    let currentPluginID: String?
    let plugins: [AudioUnitPluginInfo]
    let onSelect: (String?) -> Void

    @State private var searchText = ""

    private var filteredPlugins: [AudioUnitPluginInfo] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return plugins }

        return plugins.filter { plugin in
            plugin.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(StudioTheme.strongText)

            TextField("Search plugins", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    pluginChoiceRow(
                        title: emptyTitle,
                        isSelected: currentPluginID == nil
                    ) {
                        onSelect(nil)
                        dismiss()
                    }

                    ForEach(filteredPlugins) { plugin in
                        pluginChoiceRow(
                            title: plugin.name,
                            isSelected: currentPluginID == plugin.id
                        ) {
                            onSelect(plugin.id)
                            dismiss()
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Text("\(filteredPlugins.count) plugin(s)")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.mutedText)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(StudioSecondaryButtonStyle())
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 520)
        .background(StudioTheme.panelFill)
    }

    private func pluginChoiceRow(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.mutedText)

                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(StudioTheme.strongText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? StudioTheme.accent.opacity(0.16) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? StudioTheme.accent.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private final class HostingEditorViewController: NSViewController {
    private var hostedViewController: NSViewController?
    private let canvasView = FlippedCanvasView()

    init(contentViewController: NSViewController) {
        super.init(nibName: nil, bundle: nil)
        setContentViewController(contentViewController)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.clipsToBounds = true
        view = canvasView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        hostedViewController?.view.layoutSubtreeIfNeeded()
    }

    func setContentViewController(_ viewController: NSViewController) {
        guard hostedViewController !== viewController else { return }

        hostedViewController?.view.removeFromSuperview()
        hostedViewController?.removeFromParent()

        hostedViewController = viewController
        loadViewIfNeeded()
        addChild(viewController)

        let hostedView = viewController.view
        hostedViewController?.view.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        let fittingSize = hostedView.fittingSize
        let preferredSize = viewController.preferredContentSize
        let frameSize = hostedView.frame.size
        let boundsSize = hostedView.bounds.size
        let width = max(520, fittingSize.width, preferredSize.width, frameSize.width, boundsSize.width)
        let height = max(360, fittingSize.height, preferredSize.height, frameSize.height, boundsSize.height)

        hostedView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostedView.bounds = NSRect(x: 0, y: 0, width: width, height: height)
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.subviews.forEach { $0.removeFromSuperview() }
        canvasView.addSubview(hostedView)
        canvasView.needsLayout = true

        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor),
            hostedView.topAnchor.constraint(equalTo: canvasView.topAnchor),
            hostedView.widthAnchor.constraint(equalToConstant: width),
            hostedView.heightAnchor.constraint(equalToConstant: height)
        ])
    }
}

private final class FlippedCanvasView: NSView {
    override var isFlipped: Bool { true }
}
