import AppKit
import PRBarCore

/// La ventana principal (spec M.1, M.4): `navigate(to:)` es la única entrada.
extension AppModel {
    static let mainWindowID = "main"

    /// La abre o enfoca, cierra el popover, elige sección, PR y pestaña, y empuja el lugar anterior a Back. Lo que pide
    /// un iPhone nunca navega ni roba el foco.
    func navigate(to destination: MainDestination) {
        guard !CommandOrigin.current.isPhone else {
            AppLog.write("Ignored a navigation requested from an iPhone.")
            return
        }
        main.go(to: destination, snapshot: prStore.snapshot)
        openMainWindow()
    }

    /// ⌘0, "Open PRBar", el Dock: abre o enfoca la ventana sin moverse.
    func openMainWindow() {
        closePopover?()
        WindowPresenter.shared.show(
            id: Self.mainWindowID, title: "PRBar", size: Theme.MainLayout.defaultSize,
            options: WindowOptions(autosaveName: "MainWindow", allowsTabbing: false, kind: .document, bridgesToolbar: true,
                                   toolbarStyle: .unified, minContentSize: Theme.MainLayout.minSize),
            contentID: "main"
        ) {
            MainWindow(model: self)
        }
    }

    /// Las pestañas del PR; nil si no hay nada que mostrar (ni en la lista, ni review, ni Respond).
    func tabContext(prID: String) -> PRTabContext? {
        let task: RespondMode? = respond.phases[prID] != nil || respond.records[prID] != nil ? respond.mode(of: prID) : nil
        if let item = currentItem(prID) { return PRTabContext(item: item, respondTask: task) }
        if reviews.phases[prID] != nil { return PRTabContext(isMine: false, hasFeedback: false, ciFailing: false, respondTask: nil) }
        if task != nil { return PRTabContext(isMine: true, hasFeedback: false, ciFailing: false, respondTask: task) }
        return nil
    }

    /// Las filas del grupo Claude y de la franja del popover.
    func claudeTaskInputs() -> [ClaudeTaskInput] {
        Set(reviews.phases.keys).union(respond.phases.keys).sorted().map { prID in
            ClaudeTaskInput(
                prID: prID, review: reviews.phases[prID], reviewStartedAt: reviewRuns[prID]?.startedAt,
                respond: respond.phases[prID], respondMode: respond.mode(of: prID),
                runningTests: respond.runningTests.contains(prID), respondStartedAt: respond.runs[prID]?.startedAt,
                fromPhone: reviewRuns[prID]?.requestedOnPhone == true || respond.runs[prID]?.requestedOnPhone == true
            )
        }
    }

    func claudeTaskRows(now: Date = Date()) -> [ClaudeTaskRow] {
        ClaudeTasksSidebar.rows(claudeTaskInputs(), now: now)
    }

    /// ↩ en la lista y el pill: la acción de `PRPrimaryAction` y la pestaña que le corresponde.
    func performPrimaryAction(prID: String) {
        guard let item = currentItem(prID) else { return }
        let action = PRPrimaryAction.of(item, review: reviews.phases[prID], respond: respond.phases[prID],
                                        respondMode: respond.phases[prID] == nil ? nil : respond.mode(of: prID))
        switch action {
        case .startReview: startReview(item)
        case .startRespond: rowActions(item).respond.retry()   // misma regla que el pill (Retry con fixes → abre)
        case .startCIFix: startCIFix(item)
        case .openReview, .openRespond, .openCIFix, .openMerge, .none: break
        }
        if let tab = action.tab { navigate(to: .pr(prID: prID, tab: tab)) }
    }

    /// Clic en una notificación (spec M.4): cada una abre el PR en la pestaña de su acción.
    func openNotificationTarget(_ target: NotificationTarget) {
        switch target {
        case .updateSheet:
            openUpdateWindow()
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .destination(.pr(let prID, let tab)) where currentItem(prID) == nil:
            // El PR ya no está (se mergeó o cerró): Respond / Fix CI → su registro en History; Merge → GitHub; una
            // review lista → la pestaña igual (la review sigue en la cola).
            if tab == .respond || tab == .fixCI, respond.records[prID] == nil {
                openHistory(selecting: respondHistory.all().first { $0.draft.prID == prID }?.id)
            } else if tab == .merge, let url = PRReference.githubURL(prID: prID) {
                NSWorkspace.shared.open(url)
            } else {
                navigate(to: .pr(prID: prID, tab: tab))
            }
        case .destination(let destination):
            navigate(to: destination)
        }
    }
}
