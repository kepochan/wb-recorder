import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preferences").font(.headline)

            Form {
                HStack {
                    SecureField("API key", text: $model.apiKey)
                    Button("Test") { Task { await model.test() } }
                }
                Text("Whiteboard → Settings → API keys. Scopes: recordings:read and recordings:write to upload, plus notes:read so the app can offer the workspace's tags.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("API URL", text: $model.apiBaseURL)

                // The workspace list only exists once a key has actually been
                // accepted by the server, so the picker stays disabled until
                // then rather than offering an empty choice.
                Picker("Default workspace", selection: $model.defaultWorkspaceID) {
                    Text("—").tag("")
                    ForEach(model.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                .disabled(model.workspaces.isEmpty)

                if model.workspaces.isEmpty {
                    Text("Paste your API key and click Test to load your workspaces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Advanced") {
                    TextField("Status light server (empty = off)", text: $model.esp32Host)
                }

                HStack {
                    Text("Save folder")
                    Spacer()
                    Text(model.saveFolder.lastPathComponent).foregroundStyle(.secondary)
                    Button("Choose…") { model.chooseSaveFolder() }
                }
            }

            if let result = model.testResult {
                Label(result, systemImage: model.testSucceeded == true
                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(model.testSucceeded == true ? Color.green : Color.red)
            }
            if let error = model.saveError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Save") {
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
        // minWidth, not width: a hard width clamps the content to a size
        // smaller than it needs and clips it on both sides.
        .frame(minWidth: 480)
        .task { await model.test() }
    }
}
