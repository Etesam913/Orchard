import Foundation

@MainActor @Observable
final class ProjectDiffModel {
    private(set) var state = ProjectDiff()

    func load(project: Project?, revision: String? = nil) {
        let requestedRevision = revision ?? state.revision
        guard let project else {
            state = ProjectDiff(revision: requestedRevision)
            return
        }

        state.projectID = project.id
        state.projectPath = project.path
        state.revision = requestedRevision
        state.errorMessage = nil
        state.isLoading = true

        Task { [project, requestedRevision] in
            let result = await ProjectDiffService.loadDiff(path: project.path, revision: requestedRevision)
            await MainActor.run {
                guard self.state.projectID == project.id, self.state.revision == requestedRevision else { return }
                self.state.summary = result.summary
                self.state.stats = result.stats
                self.state.diff = result.diff
                self.state.errorMessage = result.errorMessage
                self.state.isLoading = false
            }
        }
    }

    func updateRevision(_ revision: String, project: Project?) {
        let trimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        load(project: project, revision: trimmed.isEmpty ? "@" : trimmed)
    }

    /// Re-fetch the current project/revision diff without toggling
    /// `isLoading`. Used by the sidebar's polling loop so file edits surface
    /// without flashing the spinner; only mutates state when the diff or
    /// summary actually changed, so the diff view only re-parses on real
    /// changes.
    func refresh() async {
        guard let projectID = state.projectID, !state.projectPath.isEmpty else { return }
        let path = state.projectPath
        let revision = state.revision
        let result = await ProjectDiffService.loadDiff(path: path, revision: revision)
        guard state.projectID == projectID, state.revision == revision else { return }
        if state.diff != result.diff || state.summary != result.summary || state.stats != result.stats || state.errorMessage != result.errorMessage {
            state.summary = result.summary
            state.stats = result.stats
            state.diff = result.diff
            state.errorMessage = result.errorMessage
        }
    }
}
