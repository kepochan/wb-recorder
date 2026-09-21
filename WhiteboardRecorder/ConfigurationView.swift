import SwiftUI

struct ConfigurationView: View {
    @ObservedObject var model: ConfigurationModel
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

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
            Text("L'enregistrement part vers Whiteboard. Ne quitte pas l'app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Envoyé", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(.green)
            Text("La transcription est en cours côté Whiteboard. La note apparaîtra dans le workspace choisi d'ici une minute ou deux.")
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
                Picker("Workspace", selection: $model.workspaceID) {
                    ForEach(model.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                .onChange(of: model.workspaceID) { _, _ in
                    Task { await model.loadTags() }
                }

                TextField("Titre", text: $model.title)

                DatePicker("Date de réunion", selection: $model.recordedAt,
                           in: ...Date(), displayedComponents: [.date, .hourAndMinute])

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
                Spacer()
                Button("OK", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConfirm)
            }
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
                        Button(tag.label) { model.select(tag) }
                            .buttonStyle(.link)
                    }
                }
            }

            Text("Le tag « meeting » est ajouté automatiquement.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
