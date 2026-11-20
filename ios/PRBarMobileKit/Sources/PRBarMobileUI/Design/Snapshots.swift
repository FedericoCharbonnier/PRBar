import SwiftUI
import PRBarMobileCore

/// The screens the snapshot tool renders (`swift run PRBarMobileSnapshots`), with the design's sample data.
@MainActor
public enum Snapshots {
    public static func all() -> [(String, AnyView, CGFloat?)] {
        [
            ("styleguide", AnyView(StyleGuideView()), nil),
        ]
    }
}
