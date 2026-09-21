import SwiftUI

struct ConfigurationView: View {
    @ObservedObject var model: ConfigurationModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enregistrement en cours").font(.headline)

            if !model.systemAudioAvailable {
                Label("Audio système non capté : seul le micro est enregistré.",
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
        .padding(20)
        .frame(width: 460)
        .task { await model.load() }
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
