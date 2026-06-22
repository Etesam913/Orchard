import Foundation

struct AssistantUpdateToastItem: Identifiable, Equatable {
    let id = UUID()
    let assistantName: String
    let paneID: UUID
    let projectID: UUID
    let tabID: UUID

    var title: String {
        "\(assistantName.capitalized) updated"
    }
}
