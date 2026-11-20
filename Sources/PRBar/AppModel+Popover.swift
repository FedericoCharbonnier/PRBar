import AppKit
import PRBarCore

// MARK: - Pestañas del popover (spec H)

extension AppModel {
    /// `prbar app popover [--tab]`. Provisorio: la pestaña y la apertura del popover llegan en la Task 5 del Plan 12.
    func openPopover(tab: PopoverTab?) -> PopoverInfo {
        PopoverInfo(tab: tab ?? .toReview, shown: false)
    }
}
