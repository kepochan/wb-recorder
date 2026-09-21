import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Préférences").font(.headline)

            Form {
                SecureField("Clé API", text: $model.apiKey)
                Text("Whiteboard → Settings → API keys, scopes recordings:read et recordings:write.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("URL de l'API", text: $model.apiBaseURL)

                // The workspace list only exists once a key has actually been
                // accepted by the server, so the picker stays disabled until
                // then rather than offering an empty choice.
                Picker("Workspace par défaut", selection: $model.defaultWorkspaceID) {
                    Text("—").tag("")
                    ForEach(model.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                .disabled(model.workspaces.isEmpty)

                if model.workspaces.isEmpty {
                    Text("Colle ta clé API et clique sur Tester pour charger tes workspaces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("IP de l'ESP32 (vide = désactivé)", text: $model.esp32Host)

                HStack {
                    Text("Dossier de sauvegarde")
                    Spacer()
                    Text(model.saveFolder.lastPathComponent).foregroundStyle(.secondary)
                    Button("Choisir…") { model.chooseSaveFolder() }
                }
            }

            if let result = model.testResult {
                Text(result).font(.caption)
            }
            if let error = model.saveError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Tester") { Task { await model.test() } }
                Spacer()
                Button("Enregistrer") {
                    model.save()
                    // A rejected URL or a failed Keychain write must stay
                    // visible so the user can fix it — closing here would
                    // hide the one place that error is shown.
                    if model.saveError == nil {
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await model.test() }
    }
}
