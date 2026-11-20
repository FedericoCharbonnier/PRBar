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
        .init("AppMenu.swift", "MenuItem", "Zoom", 1, .viewOnly("window management")),
        .init("AppMenu.swift", "MenuItem", "Bring All to Front", 1, .viewOnly("window management")),
        .init("AppMenu.swift", "MenuItem", "Enter Full Screen", 1, .viewOnly("window management")),
        .init("AppMenu.swift", "MenuItem", "Show Chat", 1, .cli(["chat"])),   // ⇧⌘C, the toolbar's Chat button
        .init("AppMenu.swift", "MenuItem", "Refresh", 1, .cli(["merge", "refresh"])),   // ⌘R: the Merge window (--preview) or the PR list
        .init("AppMenu.swift", "ClosureMenuItem", "History", 1, .cli(["app history"])),   // ⌘Y
        .init("AppMenu.swift", "ClosureMenuItem", "PRBar Activity", 1, .cli(["resources"])),
        .init("AppMenu.swift", "ClosureMenuItem", "Keyboard Shortcuts", 1, .viewOnly("lists the shortcuts")),
        .init("AppMenu.swift", "ClosureMenuItem", "Show Log", 1, .cli(["app logs"])),
        .init("Components/WindowCommands.swift", "Component:WindowAccessor", "-", 1, .viewOnly("finds the window a View menu command acts on")),
        .init("Components/WindowCommands.swift", "Component:WindowCommandModifier", "-", 1, .viewOnly("registers a window’s View menu commands (Show Chat, Refresh)")),
        // PRBar Activity (plan 13, spec I)
        .init("Activity/ActivityWindow.swift", "Button", "Stop", 2, .cli(["review cancel", "respond cancel", "chat", "rules chat", "update"])),   // por tarea; el de update deshabilitado
        .init("Activity/ActivityWindow.swift", "Button", "Refresh", 1, .cli(["resources"])),
        .init("Activity/ActivityWindow.swift", "Toggle", "Also delete history and logs older than", 1, .cli(["cleanup"])),   // --older-than
        .init("Activity/ActivityWindow.swift", "Stepper", #"\(olderThanDays) days"#, 1, .cli(["cleanup"])),
        .init("Activity/ActivityWindow.swift", "Button", "-", 1, .cli(["cleanup"])),   // Clean Up… (frees X)
        .init("Activity/ActivityWindow.swift", "ConfirmAlert", "-", 1, .cli(["cleanup"])),   // --yes
        .init("Activity/ActivityWindow.swift", "Component:WindowAccessor", "-", 1, .viewOnly("tracks whether the window is on screen to sample")),
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
        .init("Popover/PRRowView.swift", "Button", "View Response", 1, .cli(["open", "respond show"])),
        // Ready to Merge (plan 10) y la ventana de Merge (plan 11)
        .init("Popover/MergeButton.swift", "Button", "Merge…", 1, .cli(["open", "merge"])),   // la ventana (open --merge)
        .init("Popover/MergeButton.swift", "Button", "-", 1, .cli(["merge"])),   // la pastilla de error
        .init("Popover/MergeButton.swift", "ClosureMenuItem", "Merge…", 1, .cli(["open", "merge"])),
        // Refresh (⌘R: el resumen de nuevo), Chat y "Squash and Merge"… (--yes)
        .init("Merge/MergeWindow.swift", "Button", "-", 3, .cli(["merge", "refresh", "chat"])),
        .init("Merge/MergeWindow.swift", "Picker", "Method", 1, .cli(["merge"])),   // --method
        .init("Merge/MergeWindow.swift", "Button", "Retry", 1, .cli(["merge"])),
        .init("Merge/MergeWindow.swift", "Button", "Dismiss", 1, .cli(["merge"])),   // --dismiss
        .init("Merge/MergeWindow.swift", "Button", "Reload", 1, .cli(["merge"])),   // --preview shows the new head
        .init("Merge/MergeWindow.swift", "Button", "Try Again", 1, .cli(["merge"])),   // --preview
        .init("Merge/MergeWindow.swift", "Button", "Show Less", 1, .viewOnly("expands the description; `prbar merge --preview` prints it")),
        .init("Merge/MergeWindow.swift", "Link", "-", 1, .viewOnly("a check’s page on the CI; `prbar merge --preview --json` has its URL")),
        .init("Merge/MergeWindow.swift", "ExternalLink", "View on GitHub", 1, .cli(["open"])),
        .init("Merge/MergeWindow.swift", "ExternalLink", #"and \(detail.moreChecks) more on GitHub"#, 1, .cli(["open"])),
        .init("Merge/MergeWindow.swift", "ExternalLink", #"and \(detail.moreFiles) more on GitHub"#, 1, .cli(["open"])),
        .init("Merge/MergeWindow.swift", "Component:StaleHeadBanner", "-", 1, .cli(["merge"])),   // Reload
        // Actualizaciones (plan 8)
        .init("Popover/UpdateRow.swift", "Button", "-", 1, .cli(["update"])),   // "PRBar x is available — Update…"
        .init("Settings/UpdatesSection.swift", "Toggle", "Check automatically", 1, .cli(["config set"])),   // update-interval 0
        .init("Settings/UpdatesSection.swift", "Picker", "Frequency", 1, .cli(["config set"])),   // update-interval N
        .init("Settings/UpdatesSection.swift", "Button", "Check for Updates", 1, .cli(["update"])),   // --check
        .init("Settings/UpdatesSection.swift", "Button", "Update…", 1, .cli(["update"])),
        .init("Update/UpdateWindow.swift", "Button", "Try Again", 1, .cli(["update"])),   // "Update" / "Try Again"
        .init("Update/UpdateWindow.swift", "Button", "Update When Done", 1, .cli(["update"])),
        .init("Update/UpdateWindow.swift", "Button", "Cancel Jobs and Update", 1, .cli(["update"])),   // --cancel-jobs
        .init("Update/UpdateWindow.swift", "Button", "Skip This Version", 1, .cli(["update"])),   // --skip
        .init("Update/UpdateWindow.swift", "Button", "Cancel", 1, .cli(["update"])),   // --cancel
        .init("Update/UpdateWindow.swift", "Button", "Show Log", 2, .cli(["app logs"])),   // --update
        .init("Update/UpdateWindow.swift", "Button", "Later", 1, .viewOnly("closes the window")),
        .init("Update/UpdateWindow.swift", "Button", "Hide", 1, .viewOnly("closes the window; the update keeps going")),
        .init("Update/UpdateWindow.swift", "Button", "OK", 1, .viewOnly("closes the window")),
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
        .init("Respond/RespondWindow.swift", "Button", "Push Anyway…", 1, .cli(["respond push"])),   // --anyway
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
        .init("Review/HistoryWindow.swift", "Button", "Open PR on GitHub", 3, .cli(["open"])),
        .init("Review/HistoryWindow.swift", "Button", "Copy PR Link", 3, .cli(["open"])),
        .init("Review/HistoryWindow.swift", "Button", "View Review on GitHub", 1, .cli(["open"])),
        .init("Review/HistoryWindow.swift", "Button", "Show Claude Log in Finder", 1, .cli(["history show"])),
        .init("Review/HistoryWindow.swift", "Button", "Show Log in Finder", 2, .cli(["history show"])),
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
        .init("Settings/GeneralTab.swift", "Toggle", "-", 1, .cli(["notify enable", "notify disable"])),   // Show notifications
        .init("Settings/GeneralTab.swift", "Toggle", "New PR to review", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "A PR I reviewed has new commits", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR got change requests or comments", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "Claude finished a review or a response", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR was approved or CI failed", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR is ready to merge", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Button", "Open System Settings…", 1, .cli(["notify system-settings"])),
        .init("Settings/GeneralTab.swift", "Toggle", "Warn when PRBar uses more than", 1, .cli(["config set"])),   // disk-warning
        .init("Settings/GeneralTab.swift", "Stepper", #"\(limit) GB"#, 1, .cli(["config set"])),
        .init("Settings/PathRow.swift", "Button", "-", 1, .cli(["tools reset", "repo set"])),
        .init("Settings/PathRow.swift", "Button", "Choose…", 1, .cli(["tools set", "repo set"])),
        // Settings › Claude
        // el selector de skill, "None", una fila de la lista de skills y los chips de categoría (Task 28)
        .init("Settings/ClaudeTab.swift", "Button", "-", 4, .cli(["claude stage", "claude set", "claude skills", "claude review set"])),
        .init("Settings/ClaudeTab.swift", "Toggle", "Filter findings", 1, .cli(["claude set"])),
        .init("Settings/ClaudeTab.swift", "Picker", "Model", 2, .cli(["claude set"])),   // --model y --chat-model
        .init("Settings/ClaudeTab.swift", "Toggle", "Chat with Claude in Review, Respond and Merge windows", 1, .cli(["claude set"])),   // --chat
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
        .init("Settings/RuleViews.swift", "Button", "-", 1, .cli(["rules edit", "rules add", "rules proposal save"])),   // StageChip: Review / Fixes
        .init("Settings/RuleViews.swift", "TextField", "Rule", 1, .cli(["rules suggestions accept"])),   // la regla sugerida (--text)
        .init("Settings/RuleViews.swift", "Button", "Create Rule", 1, .cli(["rules suggestions accept"])),
        .init("Settings/RuleViews.swift", "Button", "Not Now", 1, .cli(["rules suggestions dismiss"])),
        .init("Settings/RuleViews.swift", "Button", "Never", 1, .cli(["rules suggestions never"])),
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

        // Usos de componentes que reciben acciones (los botones están en el archivo del componente), confirmaciones,
        // atajos de teclado y AppKit.
        .init("AppMenu.swift", "NSMenuItem", "", 1, .viewOnly("AppMenu.item: the menu items are inventoried as MenuItem")),
        .init("AppMenu.swift", "NSMenuItem", "-", 1, .viewOnly("a submenu title")),
        .init("Review/ReviewButton.swift", "NSMenuItem", "-", 1, .viewOnly("the error text at the top of the error menu (disabled)")),
        .init("WindowPresenter.swift", "NSAlertButton", "Replace", 1, .viewOnly("replaces a window’s unsaved contents with the new ones")),
        .init("WindowPresenter.swift", "NSAlertButton", "Keep Previous", 1, .viewOnly("keeps the window’s unsaved contents")),
        .init("WindowPresenter.swift", "NSAlertButton", "Close", 1, .viewOnly("closes a window with unsaved edits")),
        .init("WindowPresenter.swift", "NSAlertButton", "Cancel", 1, .viewOnly("keeps the window open")),
        .init("AppModel+Updates.swift", "Component:UpdateWindow", "-", 1, .cli(["update"])),
        .init("AppModel.swift", "Component:ReviewWindow", "-", 1, .viewOnly("window plumbing (unsaved state, close)")),
        .init("AppModel.swift", "Component:RespondWindow", "-", 1, .viewOnly("window plumbing (unsaved state, close)")),
        .init("Popover/PRRowView.swift", "Component:ReviewButtonActions", "-", 2,
              .cli(["review start", "review cancel", "open", "review dismiss"])),
        .init("Popover/PRRowView.swift", "Component:RespondButtonActions", "-", 2,
              .cli(["respond start", "respond cancel", "open", "respond dismiss"])),
        .init("Popover/PRRowView.swift", "Component:MergeButtonActions", "-", 2, .cli(["merge"])),   // merge, retry, --dismiss
        .init("Popover/PopoverView.swift", "Component:MessageView", "-", 3, .cli(["app settings", "refresh"])),   // Open Settings, Try Again
        .init("Popover/PopoverView.swift", "Component:MessageView", "checkmark.seal", 1, .viewOnly("a tab’s empty state, no action")),
        .init("Popover/StatusItemController.swift", "Component:PopoverPanelContent", "-", 1, .viewOnly("hosts the popover in the menu bar panel")),
        .init("Popover/PopoverView.swift", "Component:SectionHeader", "-", 1, .viewOnly("collapses a section")),
        .init("Popover/PopoverView.swift", "Component:UpdateRow", "-", 1, .cli(["update"])),
        .init("Chat/ChatPanel.swift", "Component:ChatMessageRow", "-", 2, .cli(["chat", "rules chat"])),   // Undo (--undo)
        .init("Chat/ChatPanel.swift", "Component:RuleProposalActions", "-", 1, .cli(["rules proposal save", "rules proposal dismiss"])),
        .init("Chat/ChatPanel.swift", "Component:StageChip", "-", 1, .cli(["rules proposal save"])),   // --applies-to
        .init("Chat/ChatPanel.swift", "ConfirmAlert", "Undo Claude’s changes?", 1, .cli(["chat"])),   // --undo --yes
        .init("Chat/ChatPanel.swift", "onKeyPress", "-", 1, .cli(["chat"])),   // ↩ sends
        .init("Components/SearchablePickerPopover.swift", "Component:PickerContent", "-", 1, .viewOnly(generic)),
        .init("Respond/RespondWindow.swift", "Component:MessageView", "-", 1, .viewOnly("a message; its action is a Button in this file")),
        .init("Respond/RespondWindow.swift", "Component:RespondDoneView", "-", 1, .viewOnly("closes the window")),
        .init("Respond/RespondWindow.swift", "Component:TestsBlockedPushBanner", "-", 1, .cli(["respond push"])),   // --anyway
        .init("Respond/RespondWindow.swift", "Component:TestsSection", "-", 1, .cli(["respond test", "respond cancel"])),
        .init("Respond/RespondWindow.swift", "ConfirmAlert", "-", 3, .cli(["respond push", "respond reply-only"])),   // Push and Reply, Push Anyway, Post
        .init("Review/HistoryWindow.swift", "Component:HistoryDetailView", "-", 1, .cli(["history reopen"])),
        .init("Review/HistoryWindow.swift", "Component:RespondHistoryDetailView", "-", 1, .cli(["open"])),
        .init("Review/HistoryWindow.swift", "Component:MessageView", "-", 1, .viewOnly("an empty-state message without an action")),
        .init("Review/ReviewWindow.swift", "Component:OutdatedReviewBanner", "-", 1, .cli(["review start"])),
        .init("Review/ReviewWindow.swift", "Component:ReviewPublishedView", "-", 1, .viewOnly("closes the window")),
        .init("Review/ReviewWindow.swift", "ConfirmAlert", "Approve this PR?", 1, .cli(["review publish"])),
        .init("Review/ReviewWindow.swift", "primaryAction", "-", 1, .cli(["review publish"])),   // Approve with N comments
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
        .init("Settings/RunOnSection.swift", "onTapGesture", "-", 1, .viewOnly("selects the host the buttons act on")),
        .init("Settings/RunOnSection.swift", "Toggle", "Fall back to this Mac", 1, .cli(["runners set"])),   // --fallback on|off
        .init("Settings/RunOnSection.swift", "Button", "Add SSH Host…", 1, .cli(["runners add"])),
        .init("Settings/RunOnSection.swift", "Button", "Test Connection", 1, .cli(["runners test"])),
        .init("Settings/RunOnSection.swift", "Button", "-", 1, .cli(["runners remove"])),   // Remove (red label)
        .init("Settings/RunOnSection.swift", "ConfirmAlert", "-", 1, .cli(["runners remove"])),
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
