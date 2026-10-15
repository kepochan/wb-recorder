import SwiftUI

struct ConfigurationView: View {
    @ObservedObject var model: ConfigurationModel
    @ObservedObject var uploads: UploadCoordinator
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void
    let onSaveCopy: () -> Void

    var body: some View {
        Group {
            switch model.phase {
            case .form: form
            case .uploading: sending
            case .sent: sent
            }
        }
        .padding(20)
        // minWidth, not width: a hard width clamps the content and clips it.
        .frame(minWidth: 460)
        .task { await model.load() }
    }

    private var uploadStatus: UploadCoordinator.ItemStatus {
        model.uploadID.map(uploads.status(of:)) ?? .waiting
    }

    private var sending: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch uploadStatus {
            case .waiting:
                Text("Waiting…").font(.headline)
                Text("Waiting for the previous upload to finish…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .uploading(sent, total):
                Text("Uploading…").font(.headline)
                ProgressView(value: Double(sent), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                Text("\(Self.megabytes(sent)) of \(Self.megabytes(total))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case let .paused(message):
                Label("Upload paused", systemImage: "pause.circle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .finished:
                Text("Finishing…").font(.headline)
            }
            Text("Sending “\(model.title)” to \(model.selectedWorkspaceName).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                // Closing is safe: the queue keeps going, and survives a quit.
                Text("The upload continues in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .paused = uploadStatus {
                    Button("Resume upload") { uploads.resume() }
                }
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var sent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sent", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(.green)
            Text("“\(model.title)” went to \(model.selectedWorkspaceName).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Transcription is running; the note will appear there in a minute or two.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Meeting details").font(.headline)

            if !model.systemAudioAvailable {
                Label("System audio not captured: only the microphone was recorded.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !model.deviceWatchArmed {
                // Without that watcher a mid-meeting device or sample-rate
                // change goes unnoticed, and a truncated recording would be
                // uploaded as sound before the local copy is deleted.
                Label("The audio hardware could not be watched: if the microphone changes mid-meeting the app will not notice. Keep the same microphone throughout.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = model.loadingError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Form {
                // The list arrives from the network, and until it does the
                // selection matches no row. A Picker in that state renders
                // blank and drops the choices the user then makes, so it keeps
                // a row matching the current value at all times and stays
                // disabled while there is nothing real to choose from.
                Picker("Workspace", selection: $model.workspaceID) {
                    if model.workspaces.isEmpty {
                        Text("Loading…").tag(model.workspaceID)
                    }
                    ForEach(model.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                .disabled(model.workspaces.isEmpty)
                .onChange(of: model.workspaceID) { _, _ in
                    Task { await model.loadTags() }
                }

                TextField("Title", text: $model.title)

                // Two fields on one line: the day and the time are edited
                // separately but write the same instant, and each keeps the
                // other's value untouched.
                HStack {
                    // .field rather than the default stepper style: measured
                    // and rendered offscreen, the stepper leaves the digits
                    // flush against the right edge of the box, while the plain
                    // field pads them on both sides.
                    DatePicker("Meeting date", selection: $model.recordedAt,
                               in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.field)
                        .fixedSize()
                    DatePicker("", selection: $model.recordedAt,
                               in: ...Date(), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .fixedSize()
                    Spacer()
                }

                // Raw API tokens are what travel; what the user reads says what
                // the choice does.
                Picker("Language", selection: $model.language) {
                    ForEach(Preferences.languages, id: \.self) {
                        Text(Preferences.languageName($0)).tag($0)
                    }
                }

                LabeledContent("Visibility") {
                    HStack(spacing: 6) {
                        // A mode picked from the chevron gets its own tab while
                        // it is selected, so the tabs always show the choice.
                        Picker("Visibility", selection: $model.sharingMode) {
                            ForEach(visibilityTabs, id: \.self) {
                                Text(Preferences.sharingModeShortName($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()

                        Menu {
                            Picker("Visibility", selection: $model.sharingMode) {
                                ForEach(Preferences.sharingModes, id: \.self) {
                                    Text(Preferences.sharingModeName($0)).tag($0)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("All visibility options")
                    }
                }
            }

            tagsSection

            HStack {
                Button("Discard", role: .destructive, action: onCancel)
                // The upload deletes the local file on success, so keeping a
                // copy has to be offered here, while the file still exists.
                Button("Save a copy…", action: onSaveCopy)
                Spacer()
                Button("OK", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConfirm)
            }
        }
    }

    private var visibilityTabs: [String] {
        Preferences.quickSharingModes.contains(model.sharingMode)
            ? Preferences.quickSharingModes
            : Preferences.quickSharingModes + [model.sharingMode]
    }

    /// The server's tag palette. Anything unknown falls back to the neutral
    /// colour rather than pretending to a colour the server never sent.
    private static func color(named name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "pink": return .pink
        case "yellow": return .yellow
        case "gray", "grey": return .gray
        default: return .secondary
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.subheadline)

            if !model.selectedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.selectedTags, id: \.label) { tag in
                            // The mandatory tag gets no ✕: the server adds it
                            // whatever the form says, so offering to take it
                            // off would be a lie.
                            if model.isMandatory(tag) {
                                Text(tag.label)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .foregroundStyle(Self.color(named: tag.color))
                                    .background(Self.color(named: tag.color).opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 5))
                                    .help("Always added — it cannot be removed.")
                            } else {
                                Button {
                                    model.remove(tag)
                                } label: {
                                    Text("\(tag.label) ✕")
                                }
                                .buttonStyle(.bordered)
                                .tint(Self.color(named: tag.color))
                            }
                        }
                    }
                }
            }

            TextField("Filter existing tags…", text: $model.tagQuery)
                .onSubmit {
                    if let first = model.tagSuggestions.first { model.select(first) }
                }

            if !model.tagSuggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.tagSuggestions, id: \.label) { tag in
                        Button {
                            model.select(tag)
                        } label: {
                            Text(tag.label).foregroundStyle(Self.color(named: tag.color))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("The “meeting” tag is always added and cannot be removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
