import SwiftUI

struct MultiTrackView: View {
    @StateObject private var viewModel = MultiTrackViewModel()
    let onBackToModeSelection: (() -> Void)?

    init(onBackToModeSelection: (() -> Void)? = nil) {
        self.onBackToModeSelection = onBackToModeSelection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section("Global I/O") {
                    Picker("Input interface", selection: $viewModel.selectedInputDeviceID) {
                        ForEach(viewModel.inputDevices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }
                    .onChange(of: viewModel.selectedInputDeviceID) { _, _ in
                        viewModel.handleDeviceSelectionChange()
                    }

                    Picker("Output interface", selection: $viewModel.selectedOutputDeviceID) {
                        ForEach(viewModel.outputDevices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }
                    .onChange(of: viewModel.selectedOutputDeviceID) { _, _ in
                        viewModel.handleDeviceSelectionChange()
                    }

                    Picker("Hardware buffer size", selection: $viewModel.selectedBufferSize) {
                        ForEach(viewModel.availableBufferSizes, id: \.self) { size in
                            Text("\(size) frames").tag(size)
                        }
                    }
                    .onChange(of: viewModel.selectedBufferSize) { _, newValue in
                        viewModel.customBufferSizeText = String(newValue)
                    }

                    HStack {
                        Text("Custom buffer")
                        TextField("Frames", text: $viewModel.customBufferSizeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                            .onSubmit {
                                viewModel.applyCustomBufferSize()
                            }

                        Button("Apply") {
                            viewModel.applyCustomBufferSize()
                        }
                        .disabled(viewModel.isBusy || viewModel.isRunning)
                    }

                    Text(viewModel.bufferSizeHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Latency class internal buffering") {
                    HStack {
                        Text("Realtime")
                        Spacer()
                        Text("\(viewModel.selectedBufferSize) frames")
                            .foregroundStyle(.secondary)
                    }

                    Text("Realtime tracks run directly on the hardware callback cadence, so their internal buffer follows the hardware buffer size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Buffered")
                        TextField("Frames", text: $viewModel.bufferedInternalBufferText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                            .onSubmit {
                                viewModel.applyBufferedInternalBufferSize()
                            }
                        Button("Apply") {
                            viewModel.applyBufferedInternalBufferSize()
                        }
                        .disabled(viewModel.isBusy || viewModel.isRunning)
                    }

                    HStack {
                        Text("Broadcast/Post")
                        TextField("Frames", text: $viewModel.broadcastInternalBufferText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                            .onSubmit {
                                viewModel.applyBroadcastInternalBufferSize()
                            }
                        Button("Apply") {
                            viewModel.applyBroadcastInternalBufferSize()
                        }
                        .disabled(viewModel.isBusy || viewModel.isRunning)
                    }

                    Text("Buffered and Broadcast/Post internal buffers must be whole multiples of the hardware buffer size and at least as large.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Button("Add mono track") {
                            viewModel.addMonoTrack()
                        }
                        .disabled(viewModel.isRunning)

                        Button("Add stereo track") {
                            viewModel.addStereoTrack()
                        }
                        .disabled(viewModel.isRunning)
                    }
                } header: {
                    Text("Tracks")
                }

                ForEach($viewModel.tracks) { $track in
                    Section(track.name.isEmpty ? "Track" : track.name) {
                        TextField("Track name", text: $track.name)
                            .disabled(viewModel.isRunning)

                        Toggle("Enabled", isOn: $track.isEnabled)
                            .disabled(viewModel.isRunning)

                        Picker("Layout", selection: $track.layout) {
                            ForEach(TrackChannelLayout.allCases) { layout in
                                Text(layout.title).tag(layout)
                            }
                        }
                        .disabled(viewModel.isRunning)
                        .onChange(of: track.layout) { _, _ in
                            viewModel.sanitizeTrack(id: track.id)
                        }

                        Picker("Latency class", selection: $track.latencyClass) {
                            ForEach(TrackLatencyClass.allCases) { latencyClass in
                                Text(latencyClass.title).tag(latencyClass)
                            }
                        }
                        .disabled(viewModel.isRunning)

                        Picker("Input start channel", selection: $track.inputStartChannel) {
                            ForEach(viewModel.availableInputStartChannels(for: track), id: \.self) { channel in
                                Text("Channel \(channel)").tag(channel)
                            }
                        }
                        .disabled(viewModel.isRunning || viewModel.availableInputStartChannels(for: track).isEmpty)

                        Picker("Output start channel", selection: $track.outputStartChannel) {
                            ForEach(viewModel.availableOutputStartChannels(for: track), id: \.self) { channel in
                                Text("Channel \(channel)").tag(channel)
                            }
                        }
                        .disabled(viewModel.isRunning || viewModel.availableOutputStartChannels(for: track).isEmpty)

                        Picker("Plugin", selection: $track.pluginID) {
                            Text("Bypass").tag(String?.none)
                            ForEach(viewModel.plugins) { plugin in
                                Text(plugin.name).tag(Optional(plugin.id))
                            }
                        }
                        .disabled(viewModel.isRunning)

                        Text(track.latencyClass.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(viewModel.internalBufferDescription(for: track))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Spacer()
                            Button("Remove track", role: .destructive) {
                                viewModel.removeTrack(id: track.id)
                            }
                            .disabled(viewModel.isRunning)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(viewModel.isBusy)

            HStack(spacing: 12) {
                if let onBackToModeSelection {
                    Button("Change mode") {
                        onBackToModeSelection()
                    }
                    .disabled(viewModel.isRunning)
                }

                Button("Refresh") {
                    viewModel.load()
                }
                .disabled(viewModel.isRunning)

                Button(viewModel.isRunning ? "Stop" : "Start") {
                    viewModel.toggleStartStop()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canStart && !viewModel.isRunning)

                Button("Reset counters") {
                    viewModel.resetDropoutCounters()
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(viewModel.latencyBufferValidationMessages, id: \.self) { message in
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(viewModel.invalidTrackMessages, id: \.self) { message in
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Audio dropout count: \(viewModel.audioDropoutCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Dropped frames: \(viewModel.droppedFrameCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(viewModel.statusMessage)
                        .foregroundStyle(viewModel.statusMessage.lowercased().contains("error") ? .red : .secondary)
                }
            }
        }
        .padding(20)
        .task {
            viewModel.load()
        }
    }
}
