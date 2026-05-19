import Foundation

extension Notification.Name {
    static let toggleQuickTerminal = Notification.Name("OrchardToggleQuickTerminal")
    static let orchardConfigDidChange = Notification.Name("OrchardConfigDidChange")
    static let toggleSidebar = Notification.Name("OrchardToggleSidebar")
    static let autoTilingEnabledDidChange = Notification.Name("OrchardAutoTilingEnabledDidChange")
    static let refreshDiff = Notification.Name("OrchardRefreshDiff")
    static let toggleDiffSidebar = Notification.Name("OrchardToggleDiffSidebar")
}
