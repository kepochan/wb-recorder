import Foundation
import SwiftUI

@MainActor
final class ConfigurationModel: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var workspaceID: String = ""
    @Published var title: String = ""
    @Published var recordedAt: Date
    @Published var language: String
    @Published var sharingMode: String
    @Published var availableTags: [Tag] = []
    @Published var selectedTags: [Tag] = []
    @Published var tagQuery: String = ""
    @Published var loadingError: String?

    /// What the window is showing: the form, the upload in flight, or the
    /// confirmation. The window stays up through all three so the user learns
    /// whether the meeting actually left the machine.
    enum Phase: Equatable { case form, uploading, sent }
    @Published var phase: Phase = .form

    let systemAudioAvailable: Bool
    let deviceWatchArmed: Bool
    private let preferences: Preferences
    private let client: WhiteboardClient
    /// Bumped on every `loadTags()` call so a stale response — from a workspace
    /// switch that has since been superseded — can never overwrite a newer one.
    private var tagLoadGeneration = 0

    init(startedAt: Date, preferences: Preferences, client: WhiteboardClient,
         systemAudioAvailable: Bool, deviceWatchArmed: Bool) {
        self.recordedAt = startedAt
        self.preferences = preferences
        self.client = client
        self.systemAudioAvailable = systemAudioAvailable
        self.deviceWatchArmed = deviceWatchArmed
        self.language = preferences.lastLanguage
        self.sharingMode = preferences.lastSharingMode
        self.workspaceID = preferences.effectiveWorkspaceID ?? ""
    }

    /// The workspace as the user would name it, for the confirmation screen.
    var selectedWorkspaceName: String {
        workspaces.first { $0.id == workspaceID }?.name ?? "—"
    }

    var canConfirm: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workspaceID.isEmpty
            && recordedAt <= Date()
    }

    /// Existing tags only — the app never invents one.
    var tagSuggestions: [Tag] {
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return availableTags
            .filter { tag in
                !selectedTags.contains(tag)
                    && (query.isEmpty || tag.label.lowercased().contains(query))
            }
            .prefix(6)
            .map { $0 }
    }

    func load() async {
        do {
            let workspaces = try await client.listWorkspaces()
            self.workspaces = workspaces
            if !workspaces.contains(where: { $0.id == workspaceID }) {
                workspaceID = workspaces.first?.id ?? ""
            }
            await loadTags()
        } catch let error as APIError {
            loadingError = error.message
        } catch {
            loadingError = error.localizedDescription
        }
    }

    func loadTags() async {
        guard !workspaceID.isEmpty else { return }
        selectedTags = []

        tagLoadGeneration += 1
        let generation = tagLoadGeneration
        let requestedWorkspaceID = workspaceID

        do {
            let tags = try await client.listTags(workspaceID: requestedWorkspaceID)
                .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
            guard generation == tagLoadGeneration, workspaceID == requestedWorkspaceID else { return }
            availableTags = tags
        } catch {
            // A key scoped to recordings only may be refused here; the field
            // simply stays empty rather than blocking the recording.
            guard generation == tagLoadGeneration, workspaceID == requestedWorkspaceID else { return }
            availableTags = []
        }
    }

    func select(_ tag: Tag) {
        guard !selectedTags.contains(tag) else { return }
        selectedTags.append(tag)
        tagQuery = ""
    }

    func remove(_ tag: Tag) {
        selectedTags.removeAll { $0 == tag }
    }

    func makeConfiguration() -> RecordingConfiguration {
        preferences.lastWorkspaceID = workspaceID
        preferences.lastLanguage = language
        preferences.lastSharingMode = sharingMode
        return RecordingConfiguration(
            workspaceID: workspaceID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            recordedAt: recordedAt,
            language: language,
            sharingMode: sharingMode,
            tags: selectedTags
        )
    }
}
