import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = HostViewModel()
    let onBackToModeSelection: (() -> Void)?

    init(onBackToModeSelection: (() -> Void)? = nil) {
        self.onBackToModeSelection = onBackToModeSelection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section("Input") {
                    Picker("Input interface", selection: $viewModel.selectedInputDeviceID) {
                        ForEach(viewModel.inputDevices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }
                    .onChange(of: viewModel.selectedInputDeviceID) { _, _ in
                        viewModel.handleDeviceSelectionChange()
                    }

                    Picker("Input channel", selection: $viewModel.selectedInputChannel) {
                        ForEach(viewModel.availableInputChannels, id: \.self) { channel in
                            Text("Channel \(channel)").tag(channel)
                        }
                    }
                    .disabled(viewModel.availableInputChannels.isEmpty)
                }

                Section("Output") {
                    Picker("Output interface", selection: $viewModel.selectedOutputDeviceID) {
                        ForEach(viewModel.outputDevices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }
                    .onChange(of: viewModel.selectedOutputDeviceID) { _, _ in
                        viewModel.handleDeviceSelectionChange()
                    }

                    Picker("Output channel", selection: $viewModel.selectedOutputChannel) {
                        ForEach(viewModel.availableOutputChannels, id: \.self) { channel in
                            Text("Channel \(channel)").tag(channel)
                        }
                    }
                    .disabled(viewModel.availableOutputChannels.isEmpty)
                }

                Section("Processing") {
                    Picker("Buffer size", selection: $viewModel.selectedBufferSize) {
                        ForEach(viewModel.availableBufferSizes, id: \.self) { size in
                            Text("\(size) frames").tag(size)
                        }
                    }
                    .disabled(viewModel.availableBufferSizes.isEmpty)
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

                    Picker("Plugin", selection: $viewModel.selectedPluginID) {
                        Text("Bypass").tag(String?.none)
                        ForEach(viewModel.plugins) { plugin in
                            Text(plugin.name).tag(Optional(plugin.id))
                        }
                    }

                    Toggle("Run plugin on worker thread", isOn: $viewModel.threadedProcessingEnabled)

                    if viewModel.threadedProcessingEnabled {
                        HStack {
                            Text("Threaded plugin buffer")
                            TextField("Frames", text: $viewModel.threadedProcessingBufferSizeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 140)
                                .onSubmit {
                                    viewModel.applyThreadedProcessingBufferSize()
                                }

                            Button("Apply") {
                                viewModel.applyThreadedProcessingBufferSize()
                            }
                            .disabled(viewModel.isBusy || viewModel.isRunning)
                        }

                        Text(viewModel.threadedProcessingHelpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(viewModel.isBusy || viewModel.isRunning)

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
                .disabled(viewModel.isBusy || viewModel.isRunning)

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
                    if let validationMessage = viewModel.threadedProcessingValidationMessage {
                        Text(validationMessage)
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
                        .foregroundStyle(viewModel.statusColor)
                }
            }
        }
        .padding(20)
        .task {
            viewModel.load()
        }
    }
}
