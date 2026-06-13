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

enum ProjectDiffService {
    struct Result {
        var summary: String
        var stats: ProjectDiffStats
        var diff: String
        var errorMessage: String?
    }

    static func loadDiff(path: String, revision: String) async -> Result {
        let jjRoot = await run("/usr/bin/env", arguments: ["jj", "root"], currentDirectory: path)
        let jjSummary = await run("/usr/bin/env", arguments: ["jj", "log", "-r", revision, "--no-graph", "-T", "change_id.short() ++ \" \" ++ description.first_line()"], currentDirectory: path)
        let jjDiff = await run("/usr/bin/env", arguments: ["jj", "diff", "--git", "-r", revision], currentDirectory: path)
        if jjDiff.exitCode == 0 {
            let root = jjRoot.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let change = jjSummary.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(
                summary: [root.isEmpty ? nil : "jj workspace: \(root)", change.isEmpty ? nil : change]
                    .compactMap(\.self)
                    .joined(separator: "\n"),
                stats: summarize(diff: jjDiff.output),
                diff: jjDiff.output,
                errorMessage: nil
            )
        }

        let gitSummary = await run("/usr/bin/env", arguments: ["git", "status", "--short"], currentDirectory: path)
        // `git diff HEAD` covers both staged and unstaged tracked changes
        // (including new-file diffs for `git add`-ed files). It misses
        // untracked files, which we append below via `git diff --no-index`.
        // Falls back to `git diff` when HEAD is missing (fresh repo with no
        // commits).
        var gitDiff = await run("/usr/bin/env", arguments: ["git", "diff", "HEAD", "--"], currentDirectory: path)
        if gitDiff.exitCode != 0 {
            gitDiff = await run("/usr/bin/env", arguments: ["git", "diff", "--"], currentDirectory: path)
        }
        if gitDiff.exitCode == 0 {
            var combined = gitDiff.output
            let untracked = await run("/usr/bin/env", arguments: ["git", "ls-files", "--others", "--exclude-standard", "-z"], currentDirectory: path)
            if untracked.exitCode == 0 {
                let files = untracked.output
                    .split(separator: "\0", omittingEmptySubsequences: true)
                    .map(String.init)
                for file in files {
                    // `git diff --no-index` exits 1 when files differ (the
                    // expected case here); accept any output it emits.
                    let untrackedDiff = await run("/usr/bin/env", arguments: ["git", "diff", "--no-index", "--", "/dev/null", file], currentDirectory: path)
                    if !untrackedDiff.output.isEmpty {
                        if !combined.isEmpty, !combined.hasSuffix("\n") { combined.append("\n") }
                        combined.append(untrackedDiff.output)
                    }
                }
            }
            return Result(
                summary: gitSummary.output.trimmingCharacters(in: .whitespacesAndNewlines),
                stats: summarize(diff: combined),
                diff: combined,
                errorMessage: "jj diff unavailable for \(revision); showing Git working tree diff."
            )
        }

        return Result(
            summary: "",
            stats: ProjectDiffStats(),
            diff: "",
            errorMessage: jjDiff.output.isEmpty ? gitDiff.output : jjDiff.output
        )
    }

    private static func summarize(diff: String) -> ProjectDiffStats {
        var stats = ProjectDiffStats()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                continue
            }
            if line.hasPrefix("+") {
                stats.additions += 1
            } else if line.hasPrefix("-") {
                stats.deletions += 1
            }
        }
        return stats
    }

    private static func run(_ executable: String, arguments: [String], currentDirectory: String) async -> (exitCode: Int32, output: String) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (127, error.localizedDescription))
                    return
                }

                // Drain the pipe on a separate thread. macOS pipe buffers are
                // ~64KB; a large `jj diff --git` blows through that, the child
                // blocks mid-write, and waitUntilExit never returns — which
                // left the diff sidebar spinner stuck forever on big diffs.
                let collector = OutputCollector()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    readGroup.leave()
                }

                process.waitUntilExit()
                readGroup.wait()
                let output = String(data: collector.snapshot(), encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, output))
            }
        }
    }
}

private nonisolated final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
