import Foundation

/// A qué comando de `prbar` corresponde cada control de la UI (spec C.1/C.7). Revisada a mano: un control nuevo
/// necesita su entrada. `.cli` nombra rutas de `CLIRouter`; `.viewOnly` explica por qué no hay comando (solo cambia
/// la vista, o es un componente genérico cuyos usos están inventariados donde se usan).
enum UIMapping: Equatable {
    case cli([String])
    case viewOnly(String)
    /// Controles de los planes 6/8/9 cuyo comando agregan las Tasks 26–28. La Task 28 borra este caso.
    case deferred(String)
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
        .init("AppMenu.swift", "MenuItem", "Quit PRBar", 1, .cli(["app quit"])),
        .init("AppMenu.swift", "MenuItem", "Hide PRBar", 1, .viewOnly("hides the app’s windows")),
        .init("AppMenu.swift", "MenuItem", "Hide Others", 1, .viewOnly("hides other apps")),
        .init("AppMenu.swift", "MenuItem", "Show All", 1, .viewOnly("shows other apps")),
        .init("AppMenu.swift", "MenuItem", "Undo", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Redo", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Cut", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Copy", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Paste", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Select All", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Minimize", 1, .viewOnly("window management")),
        .init("AppMenu.swift", "MenuItem", "Close", 1, .viewOnly("window management")),
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
        .init("Popover/PopoverView.swift", "Button", "History…", 2, .cli(["app history"])),
        .init("Popover/PopoverView.swift", "Button", "Settings…", 2, .cli(["app settings"])),
        .init("Popover/PopoverView.swift", "Button", "Quit PRBar", 2, .cli(["app quit"])),
        .init("Popover/PopoverView.swift", "IconButton", "-", 1, .cli(["refresh"])),
        .init("Popover/PRRowView.swift", "Button", "-", 2, .cli(["open", "merge"])),   // la fila y los métodos de "Merge With…"
        .init("Popover/PRRowView.swift", "Button", "Merge", 1, .cli(["merge"])),
        .init("Popover/PRRowView.swift", "Button", "Open on GitHub", 1, .cli(["open"])),
        .init("Popover/PRRowView.swift", "Button", "Copy Link", 1, .cli(["open"])),
        .init("Popover/PRRowView.swift", "Button", "Review with Claude", 2, .cli(["review start"])),
        .init("Popover/PRRowView.swift", "Button", "Cancel Review", 1, .cli(["review cancel"])),
        .init("Popover/PRRowView.swift", "Button", "View Review", 1, .cli(["open", "review show"])),
        .init("Popover/PRRowView.swift", "Button", "Cancel", 1, .cli(["respond cancel"])),
        .init("Popover/PRRowView.swift", "Button", "Respond with Claude", 1, .cli(["respond start"])),
        .init("Popover/PRRowView.swift", "Button", "View Response", 1, .cli(["open", "respond show"])),
        // Ready to Merge (plan 10)
        .init("Popover/MergeButton.swift", "Button", "Merge", 1, .cli(["merge"])),
        .init("Popover/MergeButton.swift", "Button", "-", 2, .cli(["merge"])),   // chevron (Merge With…) y la pastilla de error
        .init("Popover/MergeButton.swift", "ClosureMenuItem", "-", 1, .cli(["merge"])),   // un método del chevron (--method)
        .init("Popover/MergeButton.swift", "ClosureMenuItem", "Retry", 1, .cli(["merge"])),
        .init("Popover/MergeConfirmView.swift", "Button", "-", 1, .cli(["merge"])),   // "Squash and Merge"… (--yes)
        .init("Popover/MergeConfirmView.swift", "Button", "Cancel", 1, .viewOnly("cancels the confirmation")),
        .init("Popover/MergeConfirmView.swift", "Picker", "Method", 1, .cli(["merge"])),   // --method
        // Actualizaciones (plan 8)
        .init("Popover/UpdateRow.swift", "Button", "-", 1, .deferred("Task 27")),   // "PRBar x is available — Update…"
        .init("Settings/UpdatesSection.swift", "Toggle", "Check automatically", 1, .deferred("Task 27")),
        .init("Settings/UpdatesSection.swift", "Picker", "Frequency", 1, .deferred("Task 27")),
        .init("Settings/UpdatesSection.swift", "Button", "Check for Updates", 1, .deferred("Task 27")),
        .init("Settings/UpdatesSection.swift", "Button", "Update…", 1, .deferred("Task 27")),
        .init("Update/UpdateWindow.swift", "Button", "Try Again", 1, .deferred("Task 27")),   // "Update" / "Try Again"
        .init("Update/UpdateWindow.swift", "Button", "Update When Done", 1, .deferred("Task 27")),
        .init("Update/UpdateWindow.swift", "Button", "Cancel Jobs and Update", 1, .deferred("Task 27")),
        .init("Update/UpdateWindow.swift", "Button", "Skip This Version", 1, .deferred("Task 27")),
        .init("Update/UpdateWindow.swift", "Button", "Cancel", 1, .deferred("Task 27")),
        .init("Update/UpdateWindow.swift", "Button", "Show Log", 2, .deferred("Task 27")),
        .init("Update/UpdateWindow.swift", "Button", "Later", 1, .viewOnly("closes the window")),
        .init("Update/UpdateWindow.swift", "Button", "Hide", 1, .viewOnly("closes the window; the update keeps going")),
        .init("Update/UpdateWindow.swift", "Button", "OK", 1, .viewOnly("closes the window")),
        // Chat (plan 6) e instrucciones (plan 9) en el chat del PR
        .init("Chat/ChatPanel.swift", "TextField", "-", 1, .cli(["chat"])),   // el mensaje
        .init("Chat/ChatPanel.swift", "Button", "-", 1, .cli(["chat"])),   // enviar
        .init("Chat/ChatPanel.swift", "Button", "Stop", 1, .cli(["chat"])),   // --stop
        .init("Chat/ChatPanel.swift", "Button", "Undo", 1, .cli(["chat"])),   // --undo (también en el chat de instrucciones)
        .init("Chat/ChatPanel.swift", "Button", "Show Log", 1, .cli(["history show"])),   // el log del review o del análisis
        .init("Chat/ChatPanel.swift", "DisclosureGroup", "-", 1, .cli(["history show", "chat"])),   // la conversación en el historial
        .init("Chat/ChatPanel.swift", "TextField", "Rule", 1, .deferred("Task 28")),   // tarjeta "Save as rule"
        .init("Chat/ChatPanel.swift", "Picker", "Scope", 1, .deferred("Task 28")),
        .init("Chat/ChatPanel.swift", "Button", "Save", 1, .deferred("Task 28")),
        .init("Chat/ChatPanel.swift", "Button", "Dismiss", 1, .deferred("Task 28")),
        // Botones Review / Respond de la fila
        .init("Review/ReviewButton.swift", "Button", "Review", 1, .cli(["review start"])),
        .init("Review/ReviewButton.swift", "Button", "-", 4, .cli(["open", "review cancel", "history show"])),
        // FailureMenu (el menú del error de review, respond y merge): Show Log y Dismiss
        .init("Review/ReviewButton.swift", "ClosureMenuItem", "Show Log", 1, .cli(["history show", "app logs"])),
        .init("Review/ReviewButton.swift", "ClosureMenuItem", "Retry", 1, .cli(["review start"])),
        .init("Review/ReviewButton.swift", "ClosureMenuItem", "Dismiss", 1, .cli(["review dismiss", "respond dismiss", "merge"])),
        .init("Review/ReviewButton.swift", "accessibilityAction", "Cancel Review", 1, .cli(["review cancel"])),
        .init("Respond/RespondButton.swift", "Button", "Respond", 1, .cli(["respond start"])),
        .init("Respond/RespondButton.swift", "Button", "-", 5, .cli(["open", "respond cancel", "history show"])),
        .init("Respond/RespondButton.swift", "ClosureMenuItem", "Open", 1, .cli(["open"])),
        .init("Respond/RespondButton.swift", "ClosureMenuItem", "Retry", 1, .cli(["respond start", "respond push"])),
        .init("Respond/RespondButton.swift", "accessibilityAction", "Cancel", 1, .cli(["respond cancel"])),
        // Ventana de Review
        // Discarded y "Hidden by your settings" (vista; `review show` los lista), "Approve with N comments" y el botón Chat
        .init("Review/ReviewWindow.swift", "Button", "-", 4, .cli(["review publish", "review show", "chat"])),
        .init("Review/ReviewWindow.swift", "Button", "Select All", 1, .cli(["review include"])),
        .init("Review/ReviewWindow.swift", "Button", "Select None", 1, .cli(["review exclude"])),
        .init("Review/ReviewWindow.swift", "Button", "Post Everything in the Review Body", 1, .cli(["review publish"])),
        .init("Review/ReviewWindow.swift", "Button", "Request Changes", 1, .cli(["review publish"])),
        .init("Review/ReviewWindow.swift", "Button", "Approve Without Comments…", 1, .cli(["review publish"])),
        .init("Review/ReviewWindow.swift", "Button", "Comment", 1, .cli(["review publish"])),
        .init("Review/ReviewWindow.swift", "Button", "Review Again", 1, .cli(["review start"])),
        .init("Review/ReviewWindow.swift", "TextField", "General comment (optional)", 1, .cli(["review comment"])),
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
        .init("Respond/RespondWindow.swift", "Button", "-", 4, .cli(["open", "respond push", "chat"])),
        .init("Respond/RespondWindow.swift", "Button", "Push Anyway…", 1, .deferred("Task 28")),
        .init("Respond/RespondWindow.swift", "Button", "Reset to Claude’s Suggestions", 1, .cli(["respond select"])),
        .init("Respond/RespondWindow.swift", "Button", "Implement 1 Fix", 1, .cli(["respond implement"])),
        .init("Respond/RespondWindow.swift", "Button", "Analyze Again", 1, .cli(["respond start"])),
        .init("Respond/RespondWindow.swift", "Button", "Retry Pending Replies", 1, .cli(["respond reply-only"])),
        .init("Respond/RespondWindow.swift", "Button", "Cancel", 3, .cli(["respond cancel"])),
        .init("Respond/RespondWindow.swift", "Button", "Run Tests", 1, .cli(["respond test"])),
        .init("Respond/RespondWindow.swift", "Button", "Close", 2, .viewOnly("closes the window")),
        .init("Respond/RespondWindow.swift", "DisclosureGroup", "-", 1, .viewOnly("test output; `prbar respond show --full` prints it")),
        .init("Respond/RespondWindow.swift", "ExternalLink", "View Reply", 1, .cli(["respond show"])),
        .init("Respond/RespondWindow.swift", "ExternalLink", "View on GitHub", 1, .cli(["open"])),
        .init("Respond/RespondWindow.swift", "Link", "-", 1, .cli(["respond show"])),   // links a los commits
        .init("Respond/RespondItemCard.swift", "Toggle", "Implement fix", 1, .cli(["respond select"])),
        .init("Respond/RespondItemCard.swift", "Toggle", "Reply", 1, .cli(["respond select"])),
        .init("Respond/RespondItemCard.swift", "TextEditor", "-", 1, .cli(["respond select"])),
        .init("Respond/RespondItemCard.swift", "Button", "-", 1, .viewOnly("expands the thread; `prbar respond show --full` prints it")),
        .init("Respond/RespondItemCard.swift", "ExternalLink", "View on GitHub", 1, .cli(["respond show"])),
        // Historial
        .init("Review/HistoryWindow.swift", "ListSelection", "-", 1, .cli(["history show"])),
        .init("Review/HistoryWindow.swift", "Picker", "Repo", 1, .cli(["history list"])),
        .init("Review/HistoryWindow.swift", "searchable", "Search by title, repo, or number", 1, .cli(["history list"])),
        .init("Review/HistoryWindow.swift", "Button", "Open PR on GitHub", 2, .cli(["open"])),
        .init("Review/HistoryWindow.swift", "Button", "Copy PR Link", 2, .cli(["open"])),
        .init("Review/HistoryWindow.swift", "Button", "View Review on GitHub", 1, .cli(["open"])),
        .init("Review/HistoryWindow.swift", "Button", "Show Claude Log in Finder", 1, .cli(["history show"])),
        .init("Review/HistoryWindow.swift", "Button", "Show Log in Finder", 1, .cli(["history show"])),
        .init("Review/HistoryWindow.swift", "Button", "Open to Post", 1, .cli(["history reopen"])),
        .init("Review/HistoryWindow.swift", "Button", "Show Response", 1, .cli(["open"])),
        .init("Review/HistoryDetailView.swift", "Button", "-", 1, .cli(["history show"])),
        .init("Review/HistoryDetailView.swift", "Button", "Open to Post", 1, .cli(["history reopen"])),
        .init("Review/HistoryDetailView.swift", "ExternalLink", "View on GitHub", 1, .cli(["open"])),
        .init("Respond/RespondHistoryDetailView.swift", "Button", "-", 1, .cli(["history show"])),
        .init("Respond/RespondHistoryDetailView.swift", "Button", "Show Response", 1, .cli(["open"])),
        // Settings › General
        .init("Settings/GeneralTab.swift", "Picker", "Refresh every", 1, .cli(["config set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "Open at login", 1, .cli(["config set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "-", 2, .cli(["notify enable", "notify disable", "config set"])),   // Show notifications y Confirm before merging
        .init("Settings/GeneralTab.swift", "Toggle", "New PR to review", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "A PR I reviewed has new commits", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR got change requests or comments", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "Claude finished a review or a response", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR was approved or CI failed", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR is ready to merge", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Button", "Open System Settings…", 1, .cli(["notify system-settings"])),
        .init("Settings/PathRow.swift", "Button", "-", 1, .cli(["tools reset", "repo set"])),
        .init("Settings/PathRow.swift", "Button", "Choose…", 1, .cli(["tools set", "repo set"])),
        // Settings › Claude
        // el selector de skill, "None", una fila de la lista de skills y los chips de categoría (Task 28)
        .init("Settings/ClaudeTab.swift", "Button", "-", 4, .cli(["claude set", "claude skills"])),
        .init("Settings/ClaudeTab.swift", "Toggle", "Filter findings", 1, .cli(["claude set"])),
        .init("Settings/ClaudeTab.swift", "Picker", "Model", 2, .cli(["claude set"])),   // --model y --chat-model
        .init("Settings/ClaudeTab.swift", "Toggle", "Chat with Claude in Review and Respond windows", 1, .cli(["claude set"])),   // --chat
        .init("Settings/ClaudeTab.swift", "Picker", "-", 1, .deferred("Task 28")),   // Skill / Custom prompt por etapa
        .init("Settings/ClaudeTab.swift", "Button", "Edit Prompt…", 1, .deferred("Task 28")),
        .init("Settings/ClaudeTab.swift", "Button", "Edit…", 1, .deferred("Task 28")),
        .init("Settings/ClaudeTab.swift", "Picker", "Minimum severity", 1, .deferred("Task 28")),
        .init("Settings/ClaudeTab.swift", "Toggle", "Limit", 1, .deferred("Task 28")),
        .init("Settings/ClaudeTab.swift", "Stepper", #"\(limit)"#, 1, .deferred("Task 28")),
        .init("Settings/ClaudeTab.swift", "Picker", "Tone", 1, .deferred("Task 28")),
        .init("Settings/ClaudeTab.swift", "Toggle", "Run tests before pushing", 1, .deferred("Task 28")),
        .init("Settings/ClaudeTab.swift", "Picker", "Commits", 1, .deferred("Task 28")),
        .init("Settings/ClaudeTab.swift", "Toggle", "Allow new tests", 1, .deferred("Task 28")),
        .init("Settings/ClaudeTab.swift", "Toggle", "Allow new dependencies", 1, .deferred("Task 28")),
        .init("Settings/FixTemplateEditor.swift", "TextField", "-", 1, .deferred("Task 28")),
        .init("Settings/FixTemplateEditor.swift", "Button", #"\(variable.token)  \(variable.summary)"#, 1, .deferred("Task 28")),
        .init("Settings/FixTemplateEditor.swift", "Button", "Reset to Default", 1, .deferred("Task 28")),
        .init("Settings/PatternListField.swift", "TextField", "e.g. generated/**, *.lock", 1, .deferred("Task 28")),
        .init("Settings/PromptEditorSheet.swift", "TextEditor", "-", 1, .deferred("Task 28")),
        .init("Settings/PromptEditorSheet.swift", "Button", #"\(variable.token)  \(variable.summary)"#, 1, .deferred("Task 28")),
        .init("Settings/PromptEditorSheet.swift", "Button", "Reset to Default", 1, .deferred("Task 28")),
        .init("Settings/PromptEditorSheet.swift", "Button", "Save", 1, .deferred("Task 28")),
        .init("Settings/PromptEditorSheet.swift", "Button", "Cancel", 1, .viewOnly("closes the editor without saving")),
        // Settings › Instructions (plan 9)
        .init("Settings/InstructionsTab.swift", "TextField", "Rule", 1, .deferred("Task 28")),
        .init("Settings/InstructionsTab.swift", "Toggle", "Enabled", 1, .deferred("Task 28")),
        .init("Settings/InstructionsTab.swift", "Button", "-", 2, .deferred("Task 28")),   // borrar la regla y enviar en el chat
        .init("Settings/InstructionsTab.swift", "TextField", "New Rule", 1, .deferred("Task 28")),
        .init("Settings/InstructionsTab.swift", "Button", "Add", 1, .deferred("Task 28")),
        .init("Settings/InstructionsTab.swift", "TextField", "-", 1, .deferred("Task 28")),   // el mensaje del chat de instrucciones
        .init("Settings/InstructionsTab.swift", "Button", "Stop", 1, .deferred("Task 28")),
        .init("Settings/RuleViews.swift", "Button", "-", 1, .deferred("Task 28")),   // StageChip: Review / Fixes
        .init("Settings/RuleViews.swift", "TextField", "Rule", 1, .deferred("Task 28")),   // sugerencia
        .init("Settings/RuleViews.swift", "Button", "Create Rule", 1, .deferred("Task 28")),
        .init("Settings/RuleViews.swift", "Button", "Not Now", 1, .deferred("Task 28")),
        .init("Settings/RuleViews.swift", "Button", "Never", 1, .deferred("Task 28")),
        .init("Settings/ClaudeTab.swift", "Button", "Reset to Defaults", 1, .cli(["claude reset"])),
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
        .init("Settings/SlackTemplateEditor.swift", "TextField", "-", 1, .cli(["slack template set"])),
        .init("Settings/SlackTemplateEditor.swift", "Button", "-", 1, .cli(["slack template set"])),   // Insert Variable
        .init("Settings/SlackTemplateEditor.swift", "Button", "Reset to Default", 1, .cli(["slack template reset"])),
    ]
}
