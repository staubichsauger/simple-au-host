import SwiftUI

private enum MultiTrackWorkspaceTab: String, CaseIterable, Identifiable {
    case rack = "Rack"
    case show = "Show"
    case setup = "Setup"

    var id: String { rawValue }
}

struct MultiTrackView: View {
    @StateObject private var viewModel = MultiTrackViewModel()
    @State private var isImportingSession = false
    @State private var isExportingSession = false
    @State private var selectedTab: MultiTrackWorkspaceTab = .rack
    @State private var showsDiagnostics = true
    @State private var selectedRackTrackID: UUID?
    @State private var selectedRackPluginID: UUID?
    @State private var sessionDocument = MultiTrackSessionDocument(
        session: MultiTrackSessionFile(
            name: "Untitled Session",
            inputDeviceID: nil,
            outputDeviceID: nil,
            bufferSize: 128,
            latencyBufferSettings: MultiTrackLatencyBufferSettings(hardwareBufferSize: 128),
            tracks: [MultiTrackTrackConfiguration(name: "Track 1", layout: .mono)]
        )
    )
    let onBackToModeSelection: (() -> Void)?

    init(onBackToModeSelection: (() -> Void)? = nil) {
        self.onBackToModeSelection = onBackToModeSelection
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
            syncRackSelection()
        }
        .onChange(of: viewModel.tracks) { _, _ in
            syncRackSelection()
        }
        .fileImporter(
            isPresented: $isImportingSession,
            allowedContentTypes: [.simpleAUHostMultiTrackSession, .json]
        ) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                try viewModel.loadSession(from: url)
                syncRackSelection()
            } catch {
                viewModel.statusMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExportingSession,
            document: sessionDocument,
            contentType: .simpleAUHostMultiTrackSession,
            defaultFilename: viewModel.suggestedSessionFilename()
        ) { result in
            switch result {
            case .success(let url):
                viewModel.rememberExportedSessionURL(url)
            case .failure(let error):
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }

    private var workspaceTabs: some View {
        HStack(spacing: 12) {
            sessionTitleView
            workspaceTabButtons

            if selectedTab == .rack {
                Spacer()
                rackTabActions
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var sessionTitleView: some View {
        Text(viewModel.currentSessionName)
            .font(.system(size: 20, weight: .black, design: .rounded))
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
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(tabBackground(for: tab))
                .foregroundStyle(tabForeground(for: tab))
        }
        .buttonStyle(.plain)
    }

    private func tabBackground(for tab: MultiTrackWorkspaceTab) -> some ShapeStyle {
        selectedTab == tab ? Color.white.opacity(0.08) : Color.clear
    }

    private func tabForeground(for tab: MultiTrackWorkspaceTab) -> Color {
        selectedTab == tab ? StudioTheme.accent : StudioTheme.mutedText
    }

    private var rackTabActions: some View {
        HStack(spacing: 12) {
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
        rackStripBoard
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var showWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sessionActionPanel
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
            }
            .padding(.bottom, 8)
        }
    }

    private var rackStripBoard: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                ForEach($viewModel.tracks) { $track in
                    rackStrip($track)
                        .frame(width: 218)
                }

                rackAddTrackStrip
                    .frame(width: 218)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private var rackAddTrackStrip: some View {
        VStack(spacing: 12) {
            addMonoTrackButton
            addStereoTrackButton
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
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

        return VStack(alignment: .leading, spacing: 12) {
            rackStripHeaderContainer(track, value: value, isSelectedTrack: isSelectedTrack)
            rackInsertSection(track, value: value)

            Spacer(minLength: 0)

            rackStripFooter(track, value: value)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelectedTrack ? StudioTheme.accent.opacity(0.45) : Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private func rackStripHeaderContainer(
        _ track: Binding<MultiTrackTrackConfiguration>,
        value: MultiTrackTrackConfiguration,
        isSelectedTrack: Bool
    ) -> some View {
        rackStripHeader(track, value: value, isSelectedTrack: isSelectedTrack)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelectedTrack ? Color.white.opacity(0.09) : Color.white.opacity(0.04))
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
        VStack(spacing: 8) {
            ForEach(Array(track.plugins.enumerated()), id: \.element.id) { index, plugin in
                rackInsertSlot(trackID: value.id, plugin: plugin, index: index)
            }

            Button {
                viewModel.addPluginInsert(to: value.id)
                selectedRackTrackID = value.id
                selectedRackPluginID = viewModel.tracks.first(where: { $0.id == value.id })?.plugins.last?.id
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                    Text("ADD PLUGIN")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.035))
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

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("INSERT \(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.mutedText)
                Spacer()
                Circle()
                    .fill(plugin.wrappedValue.pluginID == nil ? Color.white.opacity(0.18) : StudioTheme.accent)
                    .frame(width: 8, height: 8)
            }

            HStack(spacing: 8) {
                Picker("Insert \(index + 1)", selection: plugin.pluginID) {
                    Text("Empty").tag(String?.none)
                    ForEach(viewModel.plugins) { availablePlugin in
                        Text(availablePlugin.name).tag(Optional(availablePlugin.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(viewModel.isRunning)

                if plugin.wrappedValue.pluginID != nil {
                    Button {
                        viewModel.openPluginEditor(for: trackID, pluginID: plugin.wrappedValue.id)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(!viewModel.canOpenPluginEditor(for: plugin.wrappedValue))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color(red: 0.06, green: 0.18, blue: 0.24) : Color.white.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color(red: 0.34, green: 0.84, blue: 0.97) : Color.white.opacity(0.06), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        VStack(alignment: .leading, spacing: 8) {
            TextField("Track name", text: track.name)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .black, design: .rounded))
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
        let channels = viewModel.availableInputStartChannels(for: track.wrappedValue)
        return rackControlRow(title: "Input") {
            Picker("Input", selection: track.inputStartChannel) {
                ForEach(channels, id: \.self) { channel in
                    Text("Ch \(channel)").tag(channel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(viewModel.isRunning || channels.isEmpty)
        }
    }

    private func rackOutputControl(_ track: Binding<MultiTrackTrackConfiguration>) -> some View {
        let channels = viewModel.availableOutputStartChannels(for: track.wrappedValue)
        return rackControlRow(title: "Output") {
            Picker("Output", selection: track.outputStartChannel) {
                ForEach(channels, id: \.self) { channel in
                    Text("Ch \(channel)").tag(channel)
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

    private func rackStripFooter(
        _ track: Binding<MultiTrackTrackConfiguration>,
        value: MultiTrackTrackConfiguration
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enabled", isOn: track.isEnabled)
                .toggleStyle(.switch)
                .disabled(viewModel.isRunning)

            Button("Remove Track") {
                viewModel.removeTrack(id: value.id)
                syncRackSelection()
            }
            .buttonStyle(StudioDestructiveButtonStyle())
            .disabled(viewModel.isRunning)
        }
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
                        isImportingSession = true
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(viewModel.isRunning)

                    Button("Save") {
                        do {
                            if viewModel.hasStoredSessionFile {
                                try viewModel.saveSession()
                            } else {
                                sessionDocument = viewModel.sessionDocumentForExport()
                                isExportingSession = true
                            }
                        } catch {
                            viewModel.statusMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(StudioPrimaryButtonStyle())

                    Button("Save As") {
                        sessionDocument = viewModel.sessionDocumentForExport()
                        isExportingSession = true
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                }

                HStack(spacing: 12) {
                    if let onBackToModeSelection {
                        Button("Change Mode") {
                            onBackToModeSelection()
                        }
                        .buttonStyle(StudioSecondaryButtonStyle())
                        .disabled(viewModel.isRunning)
                    }

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

    private var showStatusPanel: some View {
        StudioPanel("Current Show", subtitle: "Session identity, warnings, and live status.") {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StudioMetricTile("Session", value: viewModel.currentSessionName)
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

            Picker("Insert \(index + 1)", selection: plugin.pluginID) {
                Text("Bypass").tag(String?.none)
                ForEach(viewModel.plugins) { availablePlugin in
                    Text(availablePlugin.name).tag(Optional(availablePlugin.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
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
                Toggle("Show Diagnostics", isOn: $showsDiagnostics)
                    .toggleStyle(.switch)

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
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(StudioTheme.mutedText)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(StudioTheme.strongText)
        }
    }

    private func rackControlRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(StudioTheme.mutedText)
                .frame(width: 52, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
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

    private func updateSelectedPluginID(_ newValue: String?) {
        guard let trackID = selectedTrack?.id,
              let pluginID = selectedPlugin?.id,
              let trackIndex = viewModel.tracks.firstIndex(where: { $0.id == trackID }),
              let pluginIndex = viewModel.tracks[trackIndex].plugins.firstIndex(where: { $0.id == pluginID }) else {
            return
        }

        viewModel.tracks[trackIndex].plugins[pluginIndex].pluginID = newValue
        selectedRackPluginID = viewModel.tracks[trackIndex].plugins[pluginIndex].id
    }

    private func trimmedTelemetry(_ value: String, prefix: String) -> String {
        value.replacingOccurrences(of: prefix, with: "")
    }
}
