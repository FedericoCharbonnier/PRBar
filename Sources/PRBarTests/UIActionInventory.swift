import Foundation

/// A qué comando de `prbar` corresponde cada control de la UI (spec C.1/C.7). Revisada a mano: un control nuevo
/// necesita su entrada. `.cli` nombra rutas de `CLIRouter`; `.viewOnly` explica por qué no hay comando (solo cambia
/// la vista, o es un componente genérico cuyos usos están inventariados donde se usan).
enum UIMapping: Equatable {
    case cli([String])
    case viewOnly(String)
}

struct UIAction {
    let key: UIActionScanner.Key
    let count: Int
    let mapping: UIMapping

    init(_ file: String, _ kind: String, _ label: String, _ count: Int, _ mapping: UIMapping) {
        key = UIActionScanner.Key(file: file, kind: kind, label: label)
        self.count = count
        self.mapping = mapping
    }
}

enum UIActionInventory {
    static let generic = "generic component: each use is inventoried where it’s used"

    static let entries: [UIAction] = [
        // Menú de la app (AppKit, con una ventana abierta)
        .init("AppMenu.swift", "ClosureMenuItem", "Settings…", 1, .cli(["app settings"])),
        .init("AppMenu.swift", "MenuItem", "About PRBar", 1, .cli(["version"])),
        .init("AppMenu.swift", "ClosureMenuItem", "Check for Updates…", 1, .cli(["update"])),   // --check; "Update to PRBar x…"
        .init("AppMenu.swift", "MenuItem", "Quit PRBar", 1, .cli(["app quit"])),
        .init("AppMenu.swift", "MenuItem", "Hide PRBar", 1, .viewOnly("hides the app’s windows")),
        .init("AppMenu.swift", "MenuItem", "Hide Others", 1, .viewOnly("hides other apps")),
        .init("AppMenu.swift", "MenuItem", "Show All", 1, .viewOnly("shows other apps")),
        .init("AppMenu.swift", "MenuItem", "Undo", 1, .viewOnly("text editing")),   // también /undo del chat
        .init("AppMenu.swift", "MenuItem", "Redo", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Cut", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Copy", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Paste", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Select All", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Minimize", 1, .viewOnly("window management")),
        .init("AppMenu.swift", "MenuItem", "Close", 1, .viewOnly("window management")),
        .init("AppMenu.swift", "MenuItem", "Zoom", 1, .viewOnly("window management")),
        .init("AppMenu.swift", "MenuItem", "Bring All to Front", 1, .viewOnly("window management")),
        .init("AppMenu.swift", "MenuItem", "Enter Full Screen", 1, .viewOnly("window management")),
        .init("AppMenu.swift", "MenuItem", "Show Chat", 1, .cli(["chat"])),   // ⌥⌘I, the toolbar's Chat button
        .init("AppMenu.swift", "MenuItem", "Refresh", 1, .cli(["merge", "refresh"])),   // ⌘R: the Merge window (--preview) or the PR list
        // ⌘1–4 (To Review · My PRs · History · Activity, built in a loop) and Window › PRBar (⌘0).
        .init("AppMenu.swift", "ClosureMenuItem", "-", 1, .viewOnly("navigation in the main window")),
        .init("AppMenu.swift", "ClosureMenuItem", "PRBar", 1, .viewOnly("opens the main window")),
        .init("AppMenu.swift", "MenuItem", "Show Sidebar", 1, .viewOnly("navigation in the main window")),
        .init("AppMenu.swift", "MenuItem", "Back", 1, .viewOnly("navigation in the main window")),
        .init("AppMenu.swift", "MenuItem", "Find", 1, .viewOnly("filters the list")),
        .init("AppMenu.swift", "MenuItem", "Open in New Window", 1, .viewOnly("opens the PR in its own window")),
        .init("AppMenu.swift", "MenuItem", "Open on GitHub", 1, .cli(["open"])),
        .init("AppMenu.swift", "MenuItem", "Tab \\(index)", 1, .viewOnly("navigation in the main window")),   // ⌥⌘1–3
        .init("AppMenu.swift", "MenuItem", "Merge…", 1, .cli(["merge"])),
        .init("AppMenu.swift", "MenuItem", "Stop Claude", 1, .cli(["review cancel", "respond cancel", "ci cancel"])),
        .init("Main/PRDetailView.swift", "Component:TabCommand", "-", 3, .viewOnly("navigation in the main window")),   // ⌥⌘1–3
        .init("Main/PRDetailView.swift", "ConfirmAlert", "Cancel this review?", 1, .cli(["review cancel"])),   // ⌘.
        .init("Main/PRDetailView.swift", "ConfirmAlert", "Stop fixing the CI?", 1, .cli(["respond cancel", "ci cancel"])),   // or "Stop this response?"
        .init("AppMenu.swift", "ClosureMenuItem", "Keyboard Shortcuts", 1, .viewOnly("lists the shortcuts")),
        .init("AppMenu.swift", "ClosureMenuItem", "Show Log", 1, .cli(["app logs"])),
        .init("Components/WindowCommands.swift", "Component:WindowAccessor", "-", 1, .viewOnly("finds the window a View menu command acts on")),
        .init("Components/WindowCommands.swift", "Component:WindowCommandModifier", "-", 1, .viewOnly("registers a window’s View menu commands (Show Chat, Refresh)")),
        // PRBar Activity (plan 13, spec I)
        .init("Activity/ActivityPane.swift", "Button", "Stop", 2, .cli(["review cancel", "respond cancel", "ci cancel", "chat", "rules chat", "update"])),   // por tarea; el de update deshabilitado
        .init("Activity/ActivityPane.swift", "Button", "Clean Up Finished…", 1, .cli(["cleanup"])),   // only the worktrees of finished runs
        .init("Activity/ActivityPane.swift", "Button", "Clean Up", 1, .cli(["cleanup"])),   // one worktree: `prbar cleanup` has no --path, it cleans every finished one
        .init("Activity/ActivityPane.swift", "Button", " · ", 1, .viewOnly("navigation in the main window")),   // a ready task's status opens its tab
        .init("Activity/ActivityPane.swift", "Toggle", "Also delete history and logs older than", 1, .cli(["cleanup"])),   // --older-than
        .init("Activity/ActivityPane.swift", "Stepper", #"\(olderThanDays) days"#, 1, .cli(["cleanup"])),
        .init("Activity/ActivityPane.swift", "Button", "-", 1, .cli(["cleanup"])),   // Clean Up… (frees X)
        .init("Activity/ActivityPane.swift", "ConfirmAlert", "-", 2, .cli(["cleanup"])),   // --yes (Clean Up, and one worktree's Clean Up)
        .init("Activity/ActivityPane.swift", "Component:WindowAccessor", "-", 1, .viewOnly("tracks whether the window is on screen to sample")),
        // Ventana principal (plan 21, spec M.1)
        .init("Main/MainSidebar.swift", "ListSelection", "-", 1, .viewOnly("navigation in the main window")),   // To Review, My PRs, History, Activity
        .init("Main/MainSidebar.swift", "Button", "-", 1, .cli(["app settings"])),   // the iPhone row (--tab iphone); task rows are list selection
        .init("Main/MainSidebar.swift", "IconButton", "gearshape", 1, .cli(["app settings"])),
        .init("Main/MainWindow.swift", "Button", "Back", 1, .viewOnly("navigation in the main window")),
        .init("Main/MainWindow.swift", "Button", "Refresh", 2, .cli(["refresh", "resources"])),   // the PRs; in Activity, the disk
        .init("Main/MainWindow.swift", "Button", "Open in New Window", 1, .viewOnly("opens the PR in its own window")),
        .init("Main/MainWindow.swift", "Button", "Open on GitHub", 1, .cli(["open"])),   // only with a PR selected
        .init("Main/MainWindow.swift", "searchable", "-", 1, .viewOnly("filters the list")),   // Search PRs / Search History
        .init("Main/MainWindow.swift", "Component:WindowAccessor", "-", 1, .viewOnly("sets the search field's width")),
        .init("Main/EmptyDetailView.swift", "Component:MessageView", "No PR Selected", 1, .viewOnly("no PR selected, no action")),
        .init("Main/PRListPane.swift", "ListSelection", "-", 1, .viewOnly("navigation in the main window")),
        .init("Main/PRListRow.swift", "Button", "-", 1, .cli(["review start", "respond start", "ci fix", "open"])),   // VoiceOver's action = ↩
        .init("Main/PRListPane.swift", "onKeyPress", "-", 1, .cli(["review start", "respond start", "ci fix", "open"])),   // ↩: the pill's action
        .init("Main/PRListPane.swift", "primaryAction", "-", 1, .viewOnly("opens the PR in its own window")),   // double click
        .init("Main/PRListPane.swift", "Button", "Open on GitHub", 1, .cli(["open"])),
        .init("Main/PRListPane.swift", "Button", "Copy Link", 1, .cli(["open"])),
        .init("Main/PRListPane.swift", "Button", "-", 1, .viewOnly("folds a section of the list")),   // the section header
        .init("Main/PRListPane.swift", "Button", #"\(drafts == 1 ? "#, 1, .viewOnly("navigation in the main window")),   // N drafts hidden · Show
        .init("Main/PRListPane.swift", "Component:MessageView", "-", 3, .cli(["app settings", "refresh"])),   // Open Settings, Try Again
        .init("Main/PRListPane.swift", "Component:MessageView", "checkmark.seal", 1, .viewOnly("the list’s empty state, no action")),
        .init("Main/PRDetailView.swift", "Component:PRTabBar", "-", 1, .viewOnly("navigation in the main window")),
        .init("Main/PRTabBar.swift", "Button", "-", 1, .viewOnly("navigation in the main window")),   // a PR tab
        .init("Main/PRTabBar.swift", "Picker", "Show", 1, .viewOnly("filters History (`prbar history --kind`)")),
        .init("Main/PRDetailView.swift", "Button", "-", 1, .cli(["chat"])),   // Chat (toggles the inspector)
        .init("Main/PRDetailView.swift", "Button", "Open on GitHub", 1, .cli(["open"])),   // a PR that's no longer in the list
        .init("Main/PRDetailView.swift", "Component:MessageView", "questionmark.folder", 1, .viewOnly("a message; its action is a Button in this file")),
        // Pestaña Review (plan 21, spec M.1): Review/ReviewEditor.swift (antes ReviewWindow.swift) y ReviewPane.swift
        .init("Review/ReviewEditor.swift", "Button", "-", 2, .cli(["review publish", "review show"])),   // discarded / hidden sections
        .init("Review/ReviewEditor.swift", "Button", "All", 1, .cli(["review include"])),
        .init("Review/ReviewEditor.swift", "Button", "None", 1, .cli(["review exclude"])),
        .init("Review/ReviewEditor.swift", "Button", "Post Everything in the Review Body", 1, .cli(["review publish"])),
        .init("Review/ReviewEditor.swift", "Button", "Approve Without Comments…", 1, .cli(["review publish"])),
        .init("Review/ReviewEditor.swift", "Button", "Post Review", 1, .cli(["review publish"])),   // ⌘↩, with the decision
        .init("Review/ReviewEditor.swift", "Picker", "Decision", 1, .cli(["review publish"])),   // --approve / --request-changes
        .init("Review/ReviewEditor.swift", "Button", "Review Again", 1, .cli(["review start"])),
        .init("Review/ReviewEditor.swift", "TextField", "General comment (optional)", 1, .cli(["review comment"])),
        .init("Review/ReviewEditor.swift", "Component:OutdatedReviewBanner", "-", 1, .cli(["review start"])),
        .init("Review/ReviewEditor.swift", "Component:ReviewPublishedView", "-", 1, .viewOnly("closes the window")),
        .init("Review/ReviewEditor.swift", "ConfirmAlert", "Approve this PR?", 1, .cli(["review publish"])),
        .init("Review/ReviewPane.swift", "Button", "Start Review", 1, .cli(["review start"])),
        .init("Review/ReviewPane.swift", "Button", "Cancel", 1, .cli(["review cancel"])),
        .init("Review/ReviewPane.swift", "Button", "Show Log", 1, .cli(["app logs"])),
        .init("Review/ReviewPane.swift", "Component:ReviewEditor", "-", 2, .viewOnly("the Review tab's editor (its controls are in ReviewEditor.swift)")),
        .init("Review/ReviewPane.swift", "Component:MessageView", "questionmark.folder", 1, .viewOnly("a message without an action")),
        .init("Merge/MergeDetailPane.swift", "Button", #"Show \(detail.checks.count - Self.limit) more"#, 1, .viewOnly("shows the rest of the checks")),
        // Componentes genéricos
        .init("Components/Chips.swift", "Button", "-", 1, .cli(["repo set"])),   // RemovableChip: quitar una rama base
        .init("Components/PointingHandCursor.swift", "Button", "-", 1, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "Button", "-", 4, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "Button", "Reload", 1, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "Button", "Try Again", 1, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "IconButton", "xmark.circle.fill", 1, .viewOnly("clears the search field")),
        .init("Components/SearchablePickerPopover.swift", "TextField", "-", 1, .viewOnly("search field")),
        .init("Components/SearchablePickerPopover.swift", "freeform", "-", 2, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "onPick", "-", 2, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "onReload", "-", 2, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "onRetry", "-", 2, .viewOnly(generic)),
        // Notificaciones
        .init("NotificationDelivery.swift", "NotificationAction", "Open", 1, .cli(["open", "history show"])),
        // Popover
        .init("Popover/Components.swift", "Button", "-", 2, .cli(["app settings", "refresh"])),   // colapsar sección (vista) y la acción de MessageView
        .init("Popover/Components.swift", "IconButton", "checkmark", 1, .viewOnly("copies `gh auth login --hostname github.com`; `prbar doctor` prints it")),
        .init("Popover/PopoverView.swift", "IconButton", "macwindow", 1, .viewOnly("opens the main window")),
        // El menú ⚙︎ y sus atajos repetidos en botones invisibles (⌘0, ⌘, y ⌘Q con el menú cerrado).
        .init("Popover/PopoverView.swift", "Button", "Open PRBar", 2, .viewOnly("opens the main window")),
        .init("Popover/PopoverView.swift", "Button", "Settings…", 2, .cli(["app settings"])),
        .init("Popover/PopoverView.swift", "Button", "Quit PRBar", 2, .cli(["app quit"])),
        // La franja de Claude.
        .init("Popover/PopoverView.swift", "Button", "-", 1, .viewOnly("navigation in the main window")),
        .init("Popover/PopoverView.swift", "Component:UpdateNotice", "-", 1, .cli(["update"])),
        .init("Popover/PopoverView.swift", "IconButton", "-", 1, .cli(["refresh"])),
        .init("Popover/PopoverView.swift", "Picker", "Tab", 1, .cli(["app popover", "prs"])),   // --tab
        .init("Popover/PopoverView.swift", "Button", "To Review", 1, .cli(["app popover"])),   // ⌘1
        .init("Popover/PopoverView.swift", "Button", "My PRs", 1, .cli(["app popover"])),   // ⌘2
        .init("Popover/PopoverView.swift", "Component:ResourceFooter", "-", 1, .cli(["resources"])),
        .init("Popover/ResourceFooter.swift", "Button", "-", 1, .cli(["resources"])),   // abre PRBar Activity
        .init("Popover/PRRowView.swift", "Button", "-", 1, .cli(["open"])),   // la fila
        .init("Popover/PRRowView.swift", "Button", "Merge…", 1, .cli(["open", "merge"])),   // abre la ventana de Merge (open --merge)
        .init("Popover/PRRowView.swift", "Button", "Open on GitHub", 1, .cli(["open"])),
        .init("Popover/PRRowView.swift", "Button", "Copy Link", 1, .cli(["open"])),
        .init("Popover/PRRowView.swift", "Button", "Review with Claude", 2, .cli(["review start"])),
        .init("Popover/PRRowView.swift", "Button", "Cancel Review", 1, .cli(["review cancel"])),
        .init("Popover/PRRowView.swift", "Button", "View Review", 1, .cli(["open", "review show"])),
        .init("Popover/PRRowView.swift", "Button", "Cancel", 1, .cli(["respond cancel"])),
        .init("Popover/PRRowView.swift", "Button", "Respond with Claude", 1, .cli(["respond start"])),
        // Fix CI (spec K): mis PRs con el CI fallido
        .init("Popover/PRRowView.swift", "Button", "Fix CI with Claude", 1, .cli(["ci fix"])),
        .init("Popover/PRRowView.swift", "Button", "Cancel Fix CI", 1, .cli(["ci cancel"])),
        .init("Popover/PRRowView.swift", "Button", "View Fix CI", 1, .cli(["open", "ci show"])),   // open --respond
        .init("Popover/PRRowAccessory.swift", "Component:FixCIButton", "-", 2, .cli(["ci fix"])),
        .init("Popover/PRRowView.swift", "Button", "View Response", 1, .cli(["open", "respond show"])),
        // Ready to Merge (plan 10) y la ventana de Merge (plan 11)
        .init("Popover/MergeButton.swift", "Button", "Merge…", 1, .cli(["open", "merge"])),   // la ventana (open --merge)
        .init("Popover/MergeButton.swift", "Button", "-", 1, .cli(["merge"])),   // la pastilla de error
        .init("Popover/MergeButton.swift", "ClosureMenuItem", "Merge…", 1, .cli(["open", "merge"])),
        // Refresh (⌘R: el resumen de nuevo), Chat y "Squash and Merge"… (--yes)
        .init("Merge/MergeDetailPane.swift", "Button", "-", 1, .cli(["merge"])),   // Squash and Merge (⇧⌘M); ⌘R and the chat are the main window’s
        .init("Merge/MergeDetailPane.swift", "Picker", "Method", 1, .cli(["merge"])),   // --method
        .init("Merge/MergeDetailPane.swift", "Button", "Retry", 1, .cli(["merge"])),
        .init("Merge/MergeDetailPane.swift", "Button", "Dismiss", 1, .cli(["merge"])),   // --dismiss
        .init("Merge/MergeDetailPane.swift", "Button", "Reload", 1, .cli(["merge"])),   // --preview shows the new head
        .init("Merge/MergeDetailPane.swift", "Button", "Try Again", 1, .cli(["merge"])),   // --preview
        .init("Merge/MergeDetailPane.swift", "Button", "Show Less", 1, .viewOnly("expands the description; `prbar merge --preview` prints it")),
        .init("Merge/MergeDetailPane.swift", "Link", "-", 1, .viewOnly("a check’s page on the CI; `prbar merge --preview --json` has its URL")),
        .init("Merge/MergeDetailPane.swift", "ExternalLink", "View on GitHub", 1, .cli(["open"])),
        .init("Merge/MergeDetailPane.swift", "ExternalLink", #"and \(detail.moreChecks) more on GitHub"#, 1, .cli(["open"])),
        .init("Merge/MergeDetailPane.swift", "ExternalLink", #"and \(detail.moreFiles) more on GitHub"#, 1, .cli(["open"])),
        .init("Merge/MergeDetailPane.swift", "Component:StaleHeadBanner", "-", 1, .cli(["merge"])),   // Reload
        // Actualizaciones (plan 8)
        .init("Popover/UpdateButton.swift", "Button", "-", 1, .cli(["update"])),   // the header's "Update" capsule
        .init("Settings/UpdatesSection.swift", "Toggle", "Check automatically", 1, .cli(["config set"])),   // update-interval 0
        .init("Settings/UpdatesSection.swift", "Picker", "Frequency", 1, .cli(["config set"])),   // update-interval N
        .init("Settings/UpdatesSection.swift", "Button", "Check for Updates", 1, .cli(["update"])),   // --check
        .init("Settings/UpdatesSection.swift", "Button", "Update…", 1, .cli(["update"])),
        .init("Update/UpdateSheet.swift", "Button", "Try Again", 1, .cli(["update"])),   // "Update" / "Try Again"
        .init("Update/UpdateSheet.swift", "Button", "Update When Done", 1, .cli(["update"])),
        .init("Update/UpdateSheet.swift", "Button", "Cancel Jobs and Update", 1, .cli(["update"])),   // --cancel-jobs
        .init("Update/UpdateSheet.swift", "Button", "Skip This Version", 1, .cli(["update"])),   // --skip
        .init("Update/UpdateSheet.swift", "Button", "Cancel", 1, .cli(["update"])),   // --cancel
        .init("Update/UpdateSheet.swift", "Button", "Show Log", 2, .cli(["app logs"])),   // --update
        .init("Update/UpdateSheet.swift", "Button", "Later", 1, .viewOnly("closes the window")),
        .init("Update/UpdateSheet.swift", "Button", "Hide", 1, .viewOnly("closes the window; the update keeps going")),
        .init("Update/UpdateSheet.swift", "Button", "OK", 1, .viewOnly("closes the window")),
        // Chat (plan 6) e instrucciones (plan 9) en el chat del PR
        .init("Chat/ChatPanel.swift", "TextField", "-", 1, .cli(["chat"])),   // el mensaje
        .init("Chat/ChatPanel.swift", "Button", "-", 1, .cli(["chat"])),   // enviar
        .init("Chat/ChatPanel.swift", "Button", "Stop", 1, .cli(["chat"])),   // --stop
        .init("Chat/ChatPanel.swift", "Button", "Undo", 1, .cli(["chat", "rules chat"])),   // --undo (también en el chat de instrucciones)
        .init("Chat/ChatPanel.swift", "Button", "Show Log", 1, .cli(["history show", "app logs"])),   // el log del review/análisis, o `app logs --instructions`
        .init("Chat/ChatPanel.swift", "DisclosureGroup", "-", 1, .cli(["history show", "chat"])),   // la conversación en el historial
        .init("Chat/ChatPanel.swift", "TextField", "Rule", 1, .cli(["rules proposal save"])),   // tarjeta "Save as rule" (--text)
        .init("Chat/ChatPanel.swift", "Picker", "Scope", 1, .cli(["rules proposal save"])),   // --global / --this-repo
        .init("Chat/ChatPanel.swift", "Button", "Save", 1, .cli(["rules proposal save"])),
        .init("Chat/ChatPanel.swift", "Button", "Dismiss", 1, .cli(["rules proposal dismiss"])),
        .init("Chat/ChatPanel.swift", "Component:ChatWorkingRow", "working", 1, .viewOnly("Claude's streamed text while it answers, no action")),
        // Botones Review / Respond de la fila
        .init("Review/ReviewButton.swift", "Button", "Review", 1, .cli(["review start"])),
        .init("Review/ReviewButton.swift", "Button", "-", 4, .cli(["open", "review cancel", "history show"])),
        // FailureMenu (el menú del error de review, respond y merge): Show Log y Dismiss
        .init("Review/ReviewButton.swift", "ClosureMenuItem", "Show Log", 1, .cli(["history show", "app logs"])),
        .init("Review/ReviewButton.swift", "ClosureMenuItem", "Retry", 1, .cli(["review start"])),
        .init("Review/ReviewButton.swift", "ClosureMenuItem", "Dismiss", 1, .cli(["review dismiss", "respond dismiss", "merge"])),
        .init("Review/ReviewButton.swift", "Component:CancellablePill", "review", 1, .cli(["review cancel"])),   // asks first
        .init("Review/ReviewButton.swift", "Button", "Keep Running", 1, .viewOnly("closes the cancel confirmation")),
        .init("Review/ReviewButton.swift", "Button", #"Cancel \(job.capitalized)"#, 1, .cli(["review cancel", "respond cancel"])),
        .init("Respond/RespondButton.swift", "Button", "Respond", 1, .cli(["respond start"])),
        .init("Respond/RespondButton.swift", "Button", "-", 4, .cli(["open", "respond cancel", "history show"])),
        .init("Respond/RespondButton.swift", "ClosureMenuItem", "Open", 1, .cli(["open"])),
        .init("Respond/RespondButton.swift", "ClosureMenuItem", "Retry", 1, .cli(["respond start", "respond push"])),
        .init("Respond/RespondButton.swift", "Component:CancellablePill", "CI fix", 1, .cli(["respond cancel", "ci cancel"])),   // asks first; "response" or "CI fix"
        .init("Respond/RespondButton.swift", "Button", "Fix CI", 1, .cli(["ci fix"])),   // FixCIButton
        // Ventana de Review
        // Discarded y "Hidden by your settings" (vista; `review show` los lista), "Approve with N comments" y el botón Chat
        .init("Review/FindingCard.swift", "Toggle", "-", 2, .cli(["review include", "review exclude"])),
        .init("Review/FindingCard.swift", "Button", "-", 1, .viewOnly("expands the comment; `prbar review show --full` prints it")),
        .init("Review/FindingCard.swift", "Button", "Remove", 1, .cli(["review include", "review exclude"])),
        .init("Review/FindingCard.swift", "TextEditor", "-", 1, .cli(["review edit"])),
        .init("Review/ReviewPublishedView.swift", "Button", "Close", 1, .viewOnly("closes the window")),
        .init("Review/ReviewPublishedView.swift", "ExternalLink", "View on GitHub", 1, .cli(["open"])),
        .init("Review/ReviewStyle.swift", "ExternalLink", "-", 1, .cli(["open"])),
        .init("Review/ReviewStyle.swift", "Link", "-", 1, .viewOnly(generic)),
        // Ventana de Respond
        // carpeta, Push/Post, la acción de un mensaje ("Open New Analysis"…) y el botón Chat
        .init("Respond/RespondPane.swift", "Button", "-", 5, .cli(["respond push", "ci push", "respond diff", "chat", "open"])),   // Push & Reply / Push, file chips (diff), Undo (chat /undo), Show Worktree in Finder, a message's action
        .init("Respond/RespondPane.swift", "Button", "Push Anyway…", 2, .cli(["respond push", "ci push"])),   // --anyway (tests failed / CI passes now)
        .init("Respond/RespondPane.swift", "Button", "Fix CI", 1, .cli(["ci fix"])),   // or "Fix CI Again"
        .init("Respond/RespondPane.swift", "Button", "Start Fix CI", 1, .cli(["ci fix", "respond start"])),   // or "Start Respond"
        .init("Respond/RespondPane.swift", "ExternalLink", "Details", 1, .cli(["ci show"])),   // the check's details URL
        .init("Respond/RespondPane.swift", "Component:CIPassingBanner", "-", 1, .cli(["ci push"])),   // --anyway
        .init("Respond/RespondPane.swift", "Button", "Reset to Claude’s Suggestions", 1, .cli(["respond select"])),
        .init("Respond/RespondPane.swift", "Button", "Implement 1 Fix", 1, .cli(["respond implement"])),
        .init("Respond/RespondPane.swift", "Button", "Analyze Again", 1, .cli(["respond start"])),
        .init("Respond/RespondPane.swift", "Button", "Retry Pending Replies", 1, .cli(["respond reply-only"])),
        .init("Respond/RespondPane.swift", "Button", "Cancel", 1, .cli(["respond cancel"])),   // the tests
        .init("Respond/RespondPane.swift", "Button", "Stop", 2, .cli(["respond cancel", "ci cancel"])),
        .init("Respond/RespondPane.swift", "Button", "Discard", 1, .cli(["respond dismiss", "ci dismiss"])),
        .init("Respond/RespondPane.swift", "Button", "Run Tests", 1, .cli(["respond test"])),
        .init("Respond/RespondPane.swift", "Button", "Close", 2, .viewOnly("closes a PR window; hidden in the main window's tab")),
        .init("Respond/RespondPane.swift", "Button", "Go to Respond", 1, .viewOnly("navigation in the main window")),   // or "Go to Fix CI"
        .init("Respond/RespondPane.swift", "Button", "Open Log", 1, .viewOnly("opens Claude's log of the run")),
        .init("Respond/RespondPane.swift", "Button", "Show Log", 1, .viewOnly("opens Claude's log of the failed run")),
        .init("Respond/RespondPane.swift", "Picker", "Show", 1, .viewOnly("Diff · Tests · Log; `prbar respond|ci diff` and `test` print them")),
        .init("Respond/RespondPane.swift", "DisclosureGroup", "-", 2, .viewOnly("test output and what Claude saw of a failing check; `prbar respond|ci show --full` prints them")),
        .init("Respond/RespondPane.swift", "ExternalLink", "View Reply", 1, .cli(["respond show"])),
        .init("Respond/RespondPane.swift", "ExternalLink", "View on GitHub", 1, .cli(["open"])),
        .init("Respond/RespondPane.swift", "Link", "-", 1, .cli(["respond show"])),   // links a los commits
        .init("Respond/RespondPane.swift", "Component:MessageView", "-", 1, .viewOnly("a message; its action is a Button in this file")),
        .init("Respond/RespondPane.swift", "Component:MessageView", "arrow.left.arrow.right", 1, .viewOnly("a message; its action is a Button in this file")),
        .init("Respond/RespondPane.swift", "Component:MessageView", "questionmark.folder", 1, .viewOnly("a message")),
        .init("Respond/RespondPane.swift", "Component:RespondDoneView", "-", 1, .viewOnly("the pushed run; its links are in this file")),
        .init("Respond/RespondPane.swift", "Component:RespondOtherRunView", "-", 1, .viewOnly("navigation in the main window")),
        .init("Respond/RespondPane.swift", "Component:RespondRunView", "-", 1, .viewOnly("the run's view inside the pane; its controls are in this file")),
        .init("Respond/RespondPane.swift", "Component:TestsBlockedPushBanner", "-", 1, .cli(["respond push"])),   // --anyway
        .init("Respond/RespondPane.swift", "Component:TestsSection", "-", 1, .cli(["respond test", "respond cancel"])),
        .init("Respond/RespondPane.swift", "ConfirmAlert", "-", 5, .cli(["respond push", "respond reply-only", "ci push", "chat"])),   // Push & Reply / Push, Push Anyway (tests, CI), Post, Undo (/undo)
        .init("Respond/RespondPane.swift", "ConfirmAlert", "Stop fixing the CI?", 1, .cli(["respond cancel", "ci cancel"])),   // or "Stop this response?"
        .init("Main/PRDetailView.swift", "Component:RespondPane", "-", 1, .viewOnly("navigation in the main window")),
        .init("Respond/RespondItemCard.swift", "Toggle", "Implement fix", 1, .cli(["respond select"])),
        .init("Respond/RespondItemCard.swift", "Toggle", "Reply", 1, .cli(["respond select"])),
        .init("Respond/RespondItemCard.swift", "TextEditor", "-", 1, .cli(["respond select"])),
        .init("Respond/RespondItemCard.swift", "Button", "-", 1, .viewOnly("expands the thread; `prbar respond show --full` prints it")),
        .init("Respond/RespondItemCard.swift", "ExternalLink", "View on GitHub", 1, .cli(["respond show"])),
        // Historial
        .init("Review/HistoryPane.swift", "ListSelection", "-", 1, .cli(["history show"])),
        .init("Review/HistoryPane.swift", "Button", "-", 1, .cli(["history show"])),   // View Claude Log (the detail's bar; GitHub is the header's link)
        .init("Review/HistoryPane.swift", "Button", "Open PR on GitHub", 3, .cli(["open"])),
        .init("Review/HistoryPane.swift", "Button", "Copy PR Link", 3, .cli(["open"])),
        .init("Review/HistoryPane.swift", "Button", "View Review on GitHub", 1, .cli(["open"])),
        .init("Review/HistoryPane.swift", "Button", "Show Claude Log in Finder", 1, .cli(["history show"])),
        .init("Review/HistoryPane.swift", "Button", "Show Log in Finder", 2, .cli(["history show"])),
        .init("Review/HistoryPane.swift", "Button", "Open to Post", 1, .cli(["history reopen"])),
        .init("Review/HistoryPane.swift", "Button", "Show Response", 1, .cli(["open"])),
        .init("Review/HistoryDetailView.swift", "Button", "Open to Post", 1, .cli(["history reopen"])),
        .init("Review/HistoryDetailView.swift", "ExternalLink", "View Review", 1, .cli(["open"])),
        .init("Respond/RespondHistoryDetailView.swift", "Button", "Show Fix CI", 1, .cli(["open"])),   // or "Show Response"
        // Settings › General
        .init("Settings/GeneralTab.swift", "Picker", "Refresh every", 1, .cli(["config set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "Open at login", 1, .cli(["config set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "Always show in Dock", 1, .cli(["config set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "-", 1, .cli(["notify enable", "notify disable"])),   // Show notifications
        .init("Settings/GeneralTab.swift", "Toggle", "New PR to review", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "A PR I reviewed has new commits", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR got change requests or comments", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "Claude finished a review or a response", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR was approved or CI failed", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR is ready to merge", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Button", "Open System Settings…", 1, .cli(["notify system-settings"])),
        .init("Settings/GeneralTab.swift", "Toggle", "Warn when PRBar uses more than", 1, .cli(["config set"])),   // disk-warning
        .init("Settings/GeneralTab.swift", "Stepper", #"\(limit ?? 5) GB"#, 1, .cli(["config set"])),
        .init("Settings/PathRow.swift", "Button", "-", 1, .cli(["tools reset", "repo set"])),
        .init("Settings/PathRow.swift", "Button", "Choose…", 1, .cli(["tools set", "repo set"])),
        // Settings › Claude
        // el selector de skill, "None", una fila de la lista de skills y los chips de categoría (Task 28)
        .init("Settings/ClaudeTab.swift", "Button", "-", 3, .cli(["claude stage", "claude set", "claude skills"])),
        .init("Settings/ClaudeTab.swift", "Component:CapsuleToggle", "-", 1, .cli(["claude review set"])),   // CategoryChip: Report
        .init("Settings/ClaudeTab.swift", "Toggle", "Filter findings", 1, .cli(["claude set"])),
        .init("Settings/ClaudeTab.swift", "Picker", "Model", 2, .cli(["claude set"])),   // --model y --chat-model
        .init("Settings/ClaudeTab.swift", "Toggle", "Chat with Claude in the Review, Respond and Merge tabs", 1, .cli(["claude set"])),   // --chat
        .init("Settings/ClaudeTab.swift", "Picker", "-", 1, .cli(["claude stage", "claude prompt edit"])),   // Skill / Custom Prompt por etapa
        .init("Settings/ClaudeTab.swift", "Button", "Edit Prompt…", 1, .cli(["claude prompt edit", "claude prompt show"])),
        .init("Settings/ClaudeTab.swift", "Button", "Edit…", 1, .cli(["claude prompt edit", "claude prompt show"])),   // Prompts
        .init("Settings/ClaudeTab.swift", "Picker", "Minimum severity", 1, .cli(["claude review set"])),
        .init("Settings/ClaudeTab.swift", "Toggle", "Limit", 1, .cli(["claude review set"])),   // --max-findings N|none
        .init("Settings/ClaudeTab.swift", "Stepper", #"\(limit)"#, 1, .cli(["claude review set"])),
        .init("Settings/ClaudeTab.swift", "Picker", "Tone", 1, .cli(["claude review set"])),
        .init("Settings/ClaudeTab.swift", "Toggle", "Run tests before pushing", 1, .cli(["claude respond set"])),
        .init("Settings/ClaudeTab.swift", "Picker", "Commits", 1, .cli(["claude respond set"])),
        .init("Settings/ClaudeTab.swift", "Toggle", "Allow new tests", 1, .cli(["claude respond set"])),
        .init("Settings/ClaudeTab.swift", "Toggle", "Allow new dependencies", 1, .cli(["claude respond set"])),
        .init("Settings/FixTemplateEditor.swift", "TextField", "-", 1, .cli(["claude respond set"])),   // --commit-template / --reply-template
        .init("Settings/FixTemplateEditor.swift", "Button", #"\(variable.token)  \(variable.summary)"#, 1, .cli(["claude respond set"])),   // Insert Variable
        .init("Settings/FixTemplateEditor.swift", "Button", "Reset to Default", 1, .cli(["claude respond set"])),   // … default
        .init("Settings/PatternListField.swift", "TextField", "e.g. generated/**, *.lock", 1, .cli(["claude review set", "repo set"])),   // --ignore / --unignore (global y por repo)
        .init("Settings/PromptEditorSheet.swift", "TextEditor", "-", 1, .cli(["claude prompt edit"])),
        .init("Settings/PromptEditorSheet.swift", "Button", #"\(variable.token)  \(variable.summary)"#, 1, .cli(["claude prompt edit"])),   // Insert Variable
        .init("Settings/PromptEditorSheet.swift", "Button", "Reset to Default", 1, .cli(["claude prompt reset"])),
        .init("Settings/PromptEditorSheet.swift", "Button", "Save", 1, .cli(["claude prompt edit"])),
        .init("Settings/PromptEditorSheet.swift", "Button", "Cancel", 1, .viewOnly("closes the editor without saving")),
        // Settings › Instructions (plan 9)
        .init("Settings/InstructionsTab.swift", "TextField", "Rule", 1, .cli(["rules edit"])),   // el texto de una regla
        .init("Settings/InstructionsTab.swift", "Toggle", "Enabled", 1, .cli(["rules enable", "rules disable"])),
        .init("Settings/InstructionsTab.swift", "Button", "-", 2, .cli(["rules remove", "rules chat"])),   // borrar la regla y enviar en el chat
        .init("Settings/InstructionsTab.swift", "TextField", "New Rule", 1, .cli(["rules add"])),
        .init("Settings/InstructionsTab.swift", "Button", "Add", 1, .cli(["rules add"])),
        .init("Settings/InstructionsTab.swift", "TextField", "-", 1, .cli(["rules chat"])),   // el mensaje del chat de instrucciones
        .init("Settings/InstructionsTab.swift", "Button", "Stop", 1, .cli(["rules chat"])),   // --stop
        .init("Settings/RuleViews.swift", "Button", "-", 1, .viewOnly(generic)),   // CapsuleToggle
        .init("Settings/RuleViews.swift", "Component:CapsuleToggle", "-", 1, .cli(["rules edit", "rules add", "rules proposal save"])),   // StageChip: Review / Fixes
        .init("Settings/RuleViews.swift", "TextField", "Rule", 1, .cli(["rules suggestions accept"])),   // la regla sugerida (--text)
        .init("Settings/RuleViews.swift", "Button", "Create Rule", 1, .cli(["rules suggestions accept"])),
        .init("Settings/RuleViews.swift", "Button", "Not Now", 1, .cli(["rules suggestions dismiss"])),
        .init("Settings/RuleViews.swift", "Button", "Never", 1, .cli(["rules suggestions never"])),
        .init("Settings/ClaudeTab.swift", "Button", "Reset to Defaults", 1, .cli(["claude reset"])),
        .init("Settings/ClaudeTab.swift", "Picker", "Section", 1, .viewOnly("switches between the tab's pages")),
        .init("Settings/ClaudeTab.swift", "TextField", "Search skills", 1, .cli(["claude skills"])),
        .init("Settings/ClaudeTab.swift", "Button", "Custom…", 1, .cli(["claude set"])),
        .init("Settings/ClaudeTab.swift", "TextField", "plugin:skill", 1, .cli(["claude set"])),
        .init("Settings/ClaudeTab.swift", "Button", "Use", 1, .cli(["claude set"])),
        // Settings › Accounts
        .init("Settings/AccountsTab.swift", "Toggle", "-", 1, .cli(["account enable", "account disable"])),
        .init("Settings/AccountsTab.swift", "Button", "Reload", 1, .cli(["account reload"])),
        .init("Settings/AccountsTab.swift", "Button", "Reload Accounts", 1, .cli(["account reload"])),
        // Settings › Repos
        .init("Settings/SettingsView.swift", "Picker", "Account", 1, .viewOnly("chooses which account’s repos are shown; commands take --account")),
        .init("Settings/ReposTab.swift", "ListSelection", "-", 1, .cli(["repo list"])),
        .init("Settings/ReposTab.swift", "onPick", "-", 2, .cli(["repo add", "repo set"])),
        .init("Settings/ReposTab.swift", "onRetry", "-", 2, .cli(["repo available", "repo branches"])),
        .init("Settings/ReposTab.swift", "onReload", "-", 1, .cli(["repo available"])),
        .init("Settings/ReposTab.swift", "Button", "Remove Repo…", 1, .cli(["repo remove"])),
        .init("Settings/ReposTab.swift", "Button", "Remove…", 1, .cli(["repo remove"])),
        .init("Settings/ReposTab.swift", "Button", "Remove", 1, .cli(["repo remove"])),
        .init("Settings/ReposTab.swift", "Button", "Cancel", 1, .viewOnly("cancels the confirmation")),
        .init("Settings/ReposTab.swift", "onDeleteCommand", "-", 1, .cli(["repo remove"])),
        .init("Settings/ReposTab.swift", "IconButton", "arrow.up.right.square", 1, .cli(["repo open"])),
        .init("Settings/ReposTab.swift", "IconButton", "arrow.clockwise", 1, .cli(["slack channels"])),
        .init("Settings/ReposTab.swift", "Picker", "Channel", 1, .cli(["repo set"])),
        .init("Settings/ReposTab.swift", "TextField", "Test command", 1, .cli(["repo set"])),
        .init("Settings/ReposTab.swift", "Picker", "Merge method", 1, .cli(["repo set"])),
        .init("Settings/WatchedUsersSection.swift", "onPick", "-", 1, .cli(["follow add"])),
        .init("Settings/WatchedUsersSection.swift", "freeform", #"Add “\($0)”"#, 1, .cli(["follow add"])),
        .init("Settings/WatchedUsersSection.swift", "onRetry", "-", 1, .cli(["follow suggestions"])),
        .init("Settings/WatchedUsersSection.swift", "IconButton", "xmark", 1, .cli(["follow remove"])),
        // Settings › Slack
        .init("Settings/SlackTab.swift", "Toggle", "Use Slack", 1, .cli(["slack enable", "slack disable"])),
        .init("Settings/SlackTab.swift", "Picker", "Connect with", 1, .cli(["slack provider"])),
        .init("Settings/SlackTab.swift", "Button", "Test Connection", 2, .cli(["slack check"])),
        .init("Settings/SlackTab.swift", "SecureField", "-", 1, .cli(["slack token set"])),
        .init("Settings/SlackTab.swift", "Button", "Save and Test", 1, .cli(["slack token set"])),
        .init("Settings/SlackTab.swift", "Button", "Delete Token…", 1, .cli(["slack token clear"])),
        .init("Settings/SlackTab.swift", "Button", "Delete", 1, .cli(["slack token clear"])),
        .init("Settings/SlackTab.swift", "Button", "Cancel", 2, .viewOnly("cancels a confirmation")),
        .init("Settings/SlackTab.swift", "Button", "Send Test to My DM…", 1, .cli(["slack test"])),
        .init("Settings/SlackTab.swift", "Button", "Send Test", 1, .cli(["slack test"])),
        .init("Settings/SlackTab.swift", "Button", "Show Log", 1, .cli(["app logs"])),
        .init("Settings/SlackTab.swift", "DisclosureGroup", "How to get a user token", 1, .viewOnly("setup guide; also in docs/cli.md")),
        .init("Settings/SlackTab.swift", "Link", "Open api.slack.com/apps", 1, .viewOnly("link to Slack’s website")),
        .init("Settings/SlackTab.swift", "Toggle", "-", 1, .cli(["slack set"])),
        .init("Settings/SlackTab.swift", "Toggle", "Announce new PRs in the channel", 1, .cli(["slack set"])),
        .init("Settings/SlackTab.swift", "Toggle", "Reply “Updated” in the thread after a review and a new push", 1, .cli(["slack set"])),
        .init("Settings/SlackTab.swift", "Toggle", "Reply in the thread on each new round of comments", 1, .cli(["slack set"])),
        .init("Settings/SlackTab.swift", "Toggle", "Reply “Merged” in the thread when I merge from PRBar", 1, .cli(["slack set"])),
        .init("Settings/SlackTab.swift", "TextField", "Emoji", 1, .cli(["slack emoji"])),
        .init("Settings/SlackTab.swift", "Stepper", "-", 1, .cli(["slack search-days"])),
        // Settings › iPhone (spec Q.2)
        .init("Settings/IPhoneTab.swift", "Toggle", "-", 3, .cli(["remote enable", "remote disable", "remote keep-awake", "remote mailbox"])),   // Allow…, Keep awake, mailbox
        .init("Settings/IPhoneTab.swift", "Button", "Pair iPhone…", 1, .cli(["remote pair"])),
        .init("Settings/IPhoneTab.swift", "Component:PairIPhoneSheet", "-", 1, .cli(["remote pair"])),
        .init("Settings/IPhoneTab.swift", "Component:EnableRemoteSheet", "-", 1, .cli(["remote enable"])),
        .init("Settings/IPhoneTab.swift", "Toggle", "Require Face ID", 1, .cli(["remote devices"])),   // --require-face-id
        .init("Settings/IPhoneTab.swift", "Button", "Revoke…", 1, .cli(["remote revoke"])),
        .init("Settings/IPhoneTab.swift", "Button", "Reset iPhone Access…", 1, .cli(["remote reset"])),
        .init("Settings/IPhoneTab.swift", "ConfirmAlert", "-", 2, .cli(["remote revoke", "remote reset"])),
        .init("Settings/PairIPhoneSheet.swift", "Button", "Codes Match", 1, .cli(["remote pair"])),   // y
        .init("Settings/PairIPhoneSheet.swift", "Button", "Cancel", 1, .cli(["remote pair"])),   // n closes the slot
        .init("Settings/EnableRemoteSheet.swift", "TextField", "Relay server", 1, .cli(["remote enable"])),   // --relay
        .init("Settings/EnableRemoteSheet.swift", "SecureField", "Enrollment token", 1, .cli(["remote enable"])),   // asked without echo
        .init("Settings/EnableRemoteSheet.swift", "Button", "Enable", 1, .cli(["remote enable"])),
        .init("Settings/EnableRemoteSheet.swift", "Button", "Cancel", 1, .viewOnly("closes the sheet")),
        .init("Settings/SlackTemplateEditor.swift", "TextField", "-", 1, .cli(["slack template set"])),
        .init("Settings/SlackTemplateEditor.swift", "Button", "-", 1, .cli(["slack template set"])),   // Insert Variable
        .init("Settings/SlackTemplateEditor.swift", "Button", "Reset to Default", 1, .cli(["slack template reset"])),

        // Usos de componentes que reciben acciones (los botones están en el archivo del componente), confirmaciones,
        // atajos de teclado y AppKit.
        .init("AppMenu.swift", "NSMenuItem", "", 1, .viewOnly("AppMenu.item: the menu items are inventoried as MenuItem")),
        .init("AppMenu.swift", "NSMenuItem", "-", 1, .viewOnly("a submenu title")),
        .init("Review/ReviewButton.swift", "NSMenuItem", "-", 1, .viewOnly("the error text at the top of the error menu (disabled)")),
        .init("Main/MainWindow.swift", "Component:UpdateSheet", "-", 1, .cli(["update"])),
        .init("Main/MainSidebar.swift", "Component:UpdateButton", "-", 1, .cli(["update"])),   // while installing
        .init("Main/MainSidebar.swift", "Button", "What’s New", 1, .cli(["update"])),   // opens the Update sheet
        .init("Main/MainSidebar.swift", "Button", "Install", 1, .cli(["update"])),   // opens the Update sheet (decision 9)
        // Descartar trabajo sin pushear (Dismiss, Analyze Again / Fix CI Again): la CLI pregunta lo mismo.
        .init("AppModel.swift", "ConfirmAlert", "-", 1, .cli(["respond dismiss", "ci dismiss"])),   // --yes
        // AppModel.rowActions: los pills de las filas (popover y ventana principal).
        .init("AppModel+Popover.swift", "Component:ReviewButtonActions", "-", 1,
              .cli(["review start", "review cancel", "open", "review dismiss"])),
        .init("AppModel+Popover.swift", "Component:RespondButtonActions", "-", 2,
              .cli(["respond start", "respond cancel", "open", "respond dismiss", "ci fix", "ci cancel", "ci dismiss"])),   // Respond and Fix CI
        .init("AppModel+Popover.swift", "Component:MergeButtonActions", "-", 1, .cli(["merge"])),   // merge, retry, --dismiss
        .init("Popover/PopoverView.swift", "Component:MessageView", "-", 3, .cli(["app settings", "refresh"])),   // Open Settings, Try Again
        .init("Popover/PopoverView.swift", "Component:MessageView", "checkmark.seal", 1, .viewOnly("a tab’s empty state, no action")),
        .init("Popover/StatusItemController.swift", "Component:PopoverPanelContent", "-", 1, .viewOnly("hosts the popover in the menu bar panel")),
        .init("Popover/PopoverView.swift", "Component:SectionHeader", "-", 1, .viewOnly("collapses a section")),
        .init("Popover/PopoverView.swift", "Component:UpdateButton", "-", 1, .cli(["update"])),
        .init("Chat/ChatPanel.swift", "Component:ChatMessageRow", "-", 2, .cli(["chat", "rules chat"])),   // Undo (--undo)
        .init("Chat/ChatPanel.swift", "Component:RuleProposalActions", "-", 1, .cli(["rules proposal save", "rules proposal dismiss"])),
        .init("Chat/ChatPanel.swift", "Component:StageChip", "-", 1, .cli(["rules proposal save"])),   // --applies-to
        .init("Chat/ChatPanel.swift", "ConfirmAlert", "Undo Claude’s changes?", 1, .cli(["chat"])),   // --undo --yes
        .init("Chat/ChatPanel.swift", "onKeyPress", "-", 1, .cli(["chat"])),   // ↩ sends
        .init("Components/SearchablePickerPopover.swift", "Component:PickerContent", "-", 1, .viewOnly(generic)),
        .init("Review/HistoryPane.swift", "Component:HistoryDetailView", "-", 1, .cli(["history reopen"])),
        .init("Review/HistoryPane.swift", "Component:RespondHistoryDetailView", "-", 1, .cli(["open"])),
        .init("Review/HistoryPane.swift", "Component:MessageView", "-", 1, .viewOnly("an empty-state message without an action")),
        .init("Review/HistoryPane.swift", "Component:MessageView", "clock.arrow.circlepath", 1, .viewOnly("an empty-state message without an action")),
        .init("Settings/ClaudeTab.swift", "Component:CategoryChip", "-", 1, .cli(["claude review set"])),   // --category
        .init("Settings/ClaudeTab.swift", "Component:ClaudeStageRow", "Review", 1, .cli(["claude stage", "claude prompt edit"])),
        .init("Settings/ClaudeTab.swift", "Component:ClaudeStageRow", "Filter", 1, .cli(["claude stage", "claude prompt edit"])),
        .init("Settings/ClaudeTab.swift", "Component:ClaudeStageRow", "Analysis", 1, .cli(["claude stage", "claude prompt edit"])),
        .init("Settings/ClaudeTab.swift", "Component:ClaudeStageRow", "Implementation", 1, .cli(["claude stage", "claude prompt edit"])),
        .init("Settings/ClaudeTab.swift", "Component:FixTemplateEditor", "Commit message", 1, .cli(["claude respond set"])),
        .init("Settings/ClaudeTab.swift", "Component:FixTemplateEditor", "Reply to fixed comments", 1, .cli(["claude respond set"])),
        .init("Settings/ClaudeTab.swift", "Component:PatternListField", "Ignore paths", 1, .cli(["claude review set"])),
        .init("Settings/ClaudeTab.swift", "Component:PromptEditorSheet", "-", 1, .cli(["claude prompt edit", "claude prompt reset"])),
        .init("Settings/ClaudeTab.swift", "Component:SkillList", "-", 1, .cli(["claude stage"])),
        .init("Settings/ClaudeTab.swift", "Component:SkillPicker", "Skill", 1, .cli(["claude stage"])),
        .init("Settings/ClaudeTab.swift", "onSubmit", "-", 1, .cli(["claude set"])),   // Use (custom skill)
        .init("Settings/GeneralTab.swift", "OpenPanel", "-", 1, .cli(["tools set"])),
        .init("Settings/InstructionsTab.swift", "Component:ChatMessageRow", "-", 1, .cli(["rules chat"])),   // --undo
        .init("Settings/InstructionsTab.swift", "Component:StageChip", "-", 2, .cli(["rules add", "rules edit"])),   // --applies-to
        .init("Settings/InstructionsTab.swift", "ConfirmAlert", "Undo Claude’s changes?", 1, .cli(["rules chat"])),   // --undo --yes
        .init("Settings/InstructionsTab.swift", "onKeyPress", "-", 1, .cli(["rules chat"])),   // ↩ sends
        .init("Settings/InstructionsTab.swift", "onSubmit", "-", 2, .cli(["rules edit", "rules add"])),
        .init("Settings/PatternListField.swift", "onSubmit", "-", 1, .cli(["claude review set", "repo set"])),
        .init("Settings/ReposTab.swift", "Component:PatternListField", "Ignore paths", 1, .cli(["repo set"])),
        .init("Settings/ReposTab.swift", "Component:RemovableChip", "arrow.triangle.branch", 1, .cli(["repo set"])),   // --remove-branch
        .init("Settings/ReposTab.swift", "OpenPanel", "-", 2, .cli(["repo set"])),   // --path, --worktrees
        .init("Settings/ReposTab.swift", "onSubmit", "-", 1, .cli(["repo set"])),   // --test-command
        .init("Settings/ReposTab.swift", "Picker", "Run Claude on", 1, .cli(["repo set"])),   // --run-on local|<host>|default
        // Settings › Claude › Run On (plan 14, spec J.4)
        .init("Settings/RunOnSection.swift", "Picker", "-", 1, .cli(["runners default"])),   // Default
        .init("Settings/RunOnSection.swift", "Component:RunOnTable", "-", 1, .cli(["runners list"])),
        .init("Settings/RunOnSection.swift", "onDeleteCommand", "-", 1, .cli(["runners remove"])),   // ⌫, asks first
        .init("Settings/RunOnSection.swift", "Toggle", "Fall back to this Mac", 1, .cli(["runners set"])),   // --fallback on|off
        .init("Settings/RunOnSection.swift", "Button", "Add SSH Host…", 1, .cli(["runners add"])),
        .init("Settings/RunOnSection.swift", "Button", "Test Connection", 1, .cli(["runners test"])),
        .init("Settings/RunOnSection.swift", "Button", "-", 1, .cli(["runners remove"])),   // Remove (red label)
        .init("Settings/RunOnSection.swift", "ConfirmAlert", "-", 1, .cli(["runners remove"])),
        .init("Update/UpdateSheet.swift", "ConfirmAlert", "Update while fixes aren’t pushed?", 1, .cli(["update"])),   // la pregunta lo dice
        .init("Settings/RunOnSection.swift", "Component:AddRunnerSheet", "-", 1, .cli(["runners add"])),
        .init("Settings/RunOnSection.swift", "Picker", "From ~/.ssh/config", 1, .cli(["runners add"])),
        .init("Settings/RunOnSection.swift", "TextField", "Host", 1, .cli(["runners add"])),
        .init("Settings/RunOnSection.swift", "TextField", "Name", 1, .cli(["runners add"])),   // --name
        .init("Settings/RunOnSection.swift", "TextField", "Folder on the host", 1, .cli(["runners add"])),   // --dir
        .init("Settings/RunOnSection.swift", "Toggle", "Fall back to this Mac if it’s unreachable", 1, .cli(["runners add"])),   // --no-fallback
        .init("Settings/RunOnSection.swift", "Button", "Cancel", 1, .viewOnly("closes the sheet")),
        .init("Settings/RunOnSection.swift", "Button", "Add", 1, .cli(["runners add"])),
        .init("Settings/SlackTab.swift", "Component:SlackTemplateEditor", "-", 1, .cli(["slack template set", "slack template reset"])),
    ]
}
