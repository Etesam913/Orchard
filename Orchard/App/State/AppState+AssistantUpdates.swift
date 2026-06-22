import Foundation

extension AppState {
    func recordAssistantUpdate(assistant: String, paneID: UUID, projectID: UUID, tabID: UUID) {
        guard !assistant.isEmpty else { return }
        guard shouldShowAssistantUpdateToast(paneID: paneID, projectID: projectID, tabID: tabID) else { return }

        let now = Date()
        if let lastShown = assistantToastLastShownAt[paneID], now.timeIntervalSince(lastShown) < 3 {
            return
        }
        assistantToastLastShownAt[paneID] = now

        assistantUpdateToast = AssistantUpdateToastItem(
            assistantName: assistant,
            paneID: paneID,
            projectID: projectID,
            tabID: tabID
        )
        scheduleAssistantUpdateToastDismissal(id: assistantUpdateToast?.id)
    }

    private func shouldShowAssistantUpdateToast(paneID: UUID, projectID: UUID, tabID: UUID) -> Bool {
        guard activeProjectID == projectID,
              let activeTab = workspaces[projectID]?.activeTab,
              activeTab.id == tabID
        else { return true }

        return activeTab.focusedPaneID != paneID
    }

    private func scheduleAssistantUpdateToastDismissal(id: UUID?) {
        assistantToastDismissTask?.cancel()
        assistantToastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.assistantUpdateToast?.id == id else { return }
                self?.assistantUpdateToast = nil
            }
        }
    }
}
