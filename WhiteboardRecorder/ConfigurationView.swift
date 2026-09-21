import SwiftUI

struct ConfigurationView: View {
    @ObservedObject var model: ConfigurationModel
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

    private var sending: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Envoi en cours…").font(.headline)
            ProgressView().progressViewStyle(.linear)
            Text("Envoi de « \(model.title) » vers \(model.selectedWorkspaceName).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Ne quitte pas l'app avant la fin.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Envoyé", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(.green)
            Text("« \(model.title) » est parti dans \(model.selectedWorkspaceName).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("La transcription est en cours ; la note y apparaîtra d'ici une minute ou deux.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Fermer", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enregistrement en cours").font(.headline)

            if !model.systemAudioAvailable {
                Label("Audio système non capté : seul le micro est enregistré.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !model.deviceWatchArmed {
                // Without that watcher a mid-meeting device or sample-rate
                // change goes unnoticed, and a truncated recording would be
                // uploaded as sound before the local copy is deleted.
                Label("Surveillance du matériel audio impossible : si le micro change pendant la réunion, l'app ne le verra pas. Garde le même micro jusqu'à la fin.",
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
                        Text("Chargement…").tag(model.workspaceID)
                    }
                    ForEach(model.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                .disabled(model.workspaces.isEmpty)
                .onChange(of: model.workspaceID) { _, _ in
                    Task { await model.loadTags() }
                }

                TextField("Titre", text: $model.title)

                // Two fields on one line: the day and the time are edited
                // separately but write the same instant, and each keeps the
                // other's value untouched.
                HStack {
                    // .field rather than the default stepper style: measured
                    // and rendered offscreen, the stepper leaves the digits
                    // flush against the right edge of the box, while the plain
                    // field pads them on both sides.
                    DatePicker("Date de réunion", selection: $model.recordedAt,
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
                Picker("Langue", selection: $model.language) {
                    ForEach(Preferences.languages, id: \.self) {
                        Text(Preferences.languageName($0)).tag($0)
                    }
                }

                Picker("Visibilité", selection: $model.sharingMode) {
                    ForEach(Preferences.sharingModes, id: \.self) {
                        Text(Preferences.sharingModeName($0)).tag($0)
                    }
                }
            }

            tagsSection

            HStack {
                Button("Annuler", role: .destructive, action: onCancel)
                // The upload deletes the local file on success, so keeping a
                // copy has to be offered here, while the file still exists.
                Button("Enregistrer une copie…", action: onSaveCopy)
                Spacer()
                Button("OK", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConfirm)
            }
        }
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

            TextField("Filtrer les tags existants…", text: $model.tagQuery)
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

            Text("Le tag « meeting » est ajouté automatiquement.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
