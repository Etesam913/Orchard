import SwiftUI

struct AssistantUpdateToast: View {
    let item: AssistantUpdateToastItem

    var body: some View {
        Label {
            Text(item.title)
                .lineLimit(1)
        } icon: {
            Image(systemName: "sparkles")
                .imageScale(.medium)
                .accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(OrchardTheme.fg)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 6)
        .accessibilityLabel(item.title)
    }
}
