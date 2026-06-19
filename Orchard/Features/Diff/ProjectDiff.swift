import Foundation

struct ProjectDiff: Equatable {
    var projectID: UUID?
    var projectPath: String = ""
    var revision: String = "@"
    var summary: String = ""
    var stats = ProjectDiffStats()
    var diff: String = ""
    var errorMessage: String?
    var isLoading = false
}

struct ProjectDiffStats: Equatable, Sendable {
    var additions = 0
    var deletions = 0
}
