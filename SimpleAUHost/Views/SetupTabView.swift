import CoreAudio
import SwiftUI

struct SetupTabView: View {
    @ObservedObject var viewModel: MultiTrackViewModel
    let chooseStartupSessionPanel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sessionOverviewPanel
                bufferingPanel
                startupSettingsPanel
                companionControlPanel
            }
            .padding(.bottom, 8)
        }
    }

    private var sessionOverviewPanel: some View {
        StudioPanel("I/O Setup", subtitle: "Global interfaces and hardware buffer shared by all tracks in the current show.") {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 16) {
                        setupDevicePicker(
                            title: "Audio Interface",
                            selection: $viewModel.selectedAudioDeviceID,
                            devices: viewModel.inputDevices
                        ) {
                            viewModel.handleDeviceSelectionChange()
                        }

                        Button("Refresh Devices") {
                            viewModel.load()
                        }
                        .buttonStyle(StudioSecondaryButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        setupDevicePicker(
                            title: "Audio Interface",
                            selection: $viewModel.selectedAudioDeviceID,
                            devices: viewModel.inputDevices
                        ) {
                            viewModel.handleDeviceSelectionChange()
                        }

                        HStack {
                            Spacer()
                            Button("Refresh Devices") {
                                viewModel.load()
                            }
                            .buttonStyle(StudioSecondaryButtonStyle())
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    StudioFieldLabel("Hardware Buffer")
                    if !viewModel.availableBufferSizes.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Picker("Hardware buffer size", selection: $viewModel.selectedBufferSize) {
                                ForEach(viewModel.availableBufferSizes, id: \.self) { size in
                                    Text("\(size) frames").tag(size)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(minWidth: 780)
                            .onChange(of: viewModel.selectedBufferSize) { _, newValue in
                                viewModel.customBufferSizeText = String(newValue)
                            }
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
                HStack(spacing: 10) {
                    StudioFieldLabel("Realtime")
                    Text("\(viewModel.selectedBufferSize) frames")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(StudioTheme.accent)
                }

                Text("Buffered and Broadcast/Post must be whole multiples of the hardware buffer size.")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.mutedText)

                VStack(alignment: .leading, spacing: 14) {
                    latencyField(title: "Buffered", text: $viewModel.bufferedInternalBufferText, action: viewModel.applyBufferedInternalBufferSize)
                    latencyField(title: "Broadcast/Post", text: $viewModel.broadcastInternalBufferText, action: viewModel.applyBroadcastInternalBufferSize)
                    broadcastPrerollPicker
                }
            }
        }
    }

    private var broadcastPrerollPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioFieldLabel("Broadcast safety preroll")
            Picker(
                "Broadcast safety preroll",
                selection: Binding(
                    get: { viewModel.broadcastPrerollMultiplier },
                    set: { viewModel.setBroadcastPrerollMultiplier($0) }
                )
            ) {
                Text("1x").tag(1)
                Text("2x").tag(2)
                Text("3x").tag(3)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .disabled(viewModel.isBusy || viewModel.isRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var startupSettingsPanel: some View {
        StudioPanel("Settings", subtitle: "Choose what the app opens when it launches.") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(
                    "Open a saved show at launch",
                    isOn: Binding(
                        get: { viewModel.loadsSavedSessionOnStartup },
                        set: { viewModel.setLoadsSavedSessionOnStartup($0) }
                    )
                )
                .toggleStyle(.checkbox)

                if viewModel.loadsSavedSessionOnStartup {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            StudioFieldLabel("Startup Show")
                            Picker(
                                "Startup Show",
                                selection: Binding(
                                    get: { viewModel.startupSavedSessionSelection },
                                    set: { viewModel.setStartupSavedSessionSelection($0) }
                                )
                            ) {
                                ForEach(StartupSavedSessionSelection.allCases) { selection in
                                    Text(selection.title).tag(selection)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 360)
                        }

                        switch viewModel.startupSavedSessionSelection {
                        case .lastSaved:
                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.lastSavedSessionDisplayName)
                                    .font(.system(size: 13, weight: .semibold, design: .default))
                                    .foregroundStyle(StudioTheme.strongText)

                                Text(viewModel.lastSavedSessionPath ?? "Save a show once and it will become available here.")
                                    .font(.caption)
                                    .foregroundStyle(StudioTheme.mutedText)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)

                                if viewModel.lastSavedSessionURL != nil && !viewModel.lastSavedSessionExists {
                                    Text("The last saved show could not be found at launch time.")
                                        .font(.caption)
                                        .foregroundStyle(StudioTheme.warning)
                                }
                            }

                        case .specific:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Button("Choose Show") {
                                        chooseStartupSessionPanel()
                                    }
                                    .buttonStyle(StudioSecondaryButtonStyle())

                                    Button("Clear") {
                                        viewModel.setStartupSpecificSessionURL(nil)
                                    }
                                    .buttonStyle(StudioSecondaryButtonStyle())
                                    .disabled(viewModel.startupSpecificSessionURL == nil)
                                }

                                Toggle(
                                    "Open selected show as template",
                                    isOn: Binding(
                                        get: { viewModel.opensStartupSpecificSessionAsTemplate },
                                        set: { viewModel.setOpensStartupSpecificSessionAsTemplate($0) }
                                    )
                                )
                                .toggleStyle(.checkbox)

                                Text(viewModel.startupSpecificSessionDisplayName)
                                    .font(.system(size: 13, weight: .semibold, design: .default))
                                    .foregroundStyle(StudioTheme.strongText)

                                Text(viewModel.startupSpecificSessionPath ?? "Choose the show file that should open when the app launches.")
                                    .font(.caption)
                                    .foregroundStyle(StudioTheme.mutedText)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)

                                if viewModel.startupSpecificSessionURL != nil && !viewModel.startupSpecificSessionExists {
                                    Text("The selected startup show is no longer available at the saved path.")
                                        .font(.caption)
                                        .foregroundStyle(StudioTheme.warning)
                                }

                                if viewModel.opensStartupSpecificSessionAsTemplate {
                                    Text("The selected show will load at launch, but Save will use Save As so the original file is not overwritten.")
                                        .font(.caption)
                                        .foregroundStyle(StudioTheme.mutedText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else {
                    Text("Launches into a new untitled show.")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.mutedText)
                }

                Toggle(
                    "Open Perform tab at launch",
                    isOn: Binding(
                        get: { viewModel.launchesIntoPerformViewOnStartup },
                        set: { viewModel.setLaunchesIntoPerformViewOnStartup($0) }
                    )
                )
                .toggleStyle(.checkbox)

                Toggle(
                    "Start engine on launch",
                    isOn: Binding(
                        get: { viewModel.startsEngineOnLaunch },
                        set: { viewModel.setStartsEngineOnLaunch($0) }
                    )
                )
                .toggleStyle(.checkbox)
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

                Text(
                    "Companion can poll `GET /api/v1/state` and trigger POST actions under " +
                        "`/api/v1/actions/waves-tune/...`. The displayed endpoint uses 127.0.0.1, " +
                        "which is the intended address when Companion runs on the same Mac."
                )
                    .font(.caption)
                    .foregroundStyle(StudioTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setupDevicePicker(
        title: String,
        selection: Binding<AudioDeviceID?>,
        devices: [AudioDeviceInfo],
        onChange: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
}
