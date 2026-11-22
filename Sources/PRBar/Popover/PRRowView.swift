import AppKit
import PRBarCore
import SwiftUI

struct PRRowView: View {
    let item: ClassifiedPR
    /// Fila de "Otros": el título va en gris en vez de bajar la opacidad de toda la fila.
    var dimmed = false
    /// Where the PR's last job ran (spec J): "on devbox" or the fallback; nil = this Mac.
    var placement: String? = nil
    /// Selected with ↑/↓ in the popover: highlighted like the row under the mouse.
    var isSelected = false
    let model: AppModel
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue
    @ObservedObject var merges: MergeQueue
    /// While an update installs, Review, Respond and Merge are disabled (`AppModel.jobsBlockedReason`).
    @ObservedObject var updateSession: UpdateInstallSession
    @State private var hovering = false

    private var pr: PullRequest { item.pr }
    private var hasReviewButton: Bool { item.category == .toReview || item.category == .updatedSinceMyReview }
    /// "on devbox" only while the PR has a review or an analysis to show (in progress or done).
    private var shownPlacement: String? {
        reviews.phases[item.id] != nil || respond.phases[item.id] != nil ? placement : nil
    }

    var body: some View {
        // La fila es un `Button` real que abre el PR. Los botones Review y Responder no pueden ir adentro (serían
        // botones anidados): se dibujan encima, en el lugar que les reserva una copia oculta dentro de la fila.
        Button { NSWorkspace.shared.open(pr.url) } label: { rowContent }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isLink, .isSelected] : .isLink)
            .accessibilityHint("Opens the PR on GitHub")
            .overlayPreferenceValue(AccessoryAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor {
                        let rect = proxy[anchor]
                        trailingAccessory
                            .font(.subheadline.weight(.medium))
                            .fixedSize()
                            .frame(width: rect.maxX, height: rect.height, alignment: .trailing)
                            .offset(y: rect.minY)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row)
                    .fill(hovering || isSelected ? Color.primary.opacity(0.07) : .clear)
                    .padding(.horizontal, 6)
            )
            .onHover { hovering = $0 }
            .contextMenu { contextMenu }
            .help("\(pr.repo.fullName)#\(pr.number) · \(pr.title)")
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            rowMain
            // Its own line, as wide as the row (not squeezed by the buttons on the right): the fallback text is long.
            if let shownPlacement {
                PlacementLabel(text: shownPlacement)
                    .font(.caption)
                    .padding(.leading, 22 + 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var rowMain: some View {
        HStack(alignment: .center, spacing: 8) {
            AvatarView(login: pr.author, url: pr.authorAvatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(pr.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Si falta espacio se corta primero la rama; `repo#número` y la antigüedad quedan completos.
                HStack(spacing: 4) {
                    (Text(pr.repo.name).foregroundColor(.secondary) + Text("#\(pr.number)").foregroundColor(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(2)
                    Text("·")
                    Image(systemName: "arrow.triangle.branch").font(.caption2.weight(.semibold))
                    Text(pr.baseRef)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("·")
                    Text(RelativeAge.short(from: pr.updatedAt))
                        .fixedSize()
                        .layoutPriority(3)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // En mis PRs el feedback va en su propia línea: compartir la línea con repo, rama y antigüedad
                // (más el botón Respond a la derecha) dejaba todo cortado.
                if item.category == .myFeedback {
                    FeedbackLabel(summary: ActionClassifier.newFeedback(pr, me: item.account))
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if item.category == .readyToMerge {
                    MergeStatusLabel(availability: model.mergeOptions(item).availability)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                trailingAccessory
                    .font(.subheadline.weight(.medium))
                    .hidden()
                    .anchorPreference(key: AccessoryAnchorKey.self, value: .bounds) { $0 }
                HStack(spacing: 6) {
                    CIIcon(state: pr.ciState).font(.caption2.weight(.bold))
                    Text("+\(pr.additions)").foregroundStyle(Theme.greenText)
                    Text("−\(pr.deletions)").foregroundStyle(Theme.redText)
                }
                .font(.system(.caption, design: .monospaced))
            }
        }
    }

    /// The PR's Respond slot holds a Fix CI (spec K).
    private var hasCIFix: Bool { respond.modes[item.id] == .ciFix && respond.phases[item.id] != nil }
    /// "Fix CI" goes on the row: a PR of mine whose CI failed, with nothing in its Respond slot.
    private var offersFixCI: Bool { model.isCIFixCandidate(item) && respond.phases[item.id] == nil }

    @ViewBuilder
    private var trailingAccessory: some View {
        if hasCIFix {
            RespondButton(
                phase: respond.phases[item.id], runningTests: respond.runningTests.contains(item.id),
                unavailableReason: model.ciFixUnavailableReason(item), hasRecord: respond.records[item.id] != nil,
                actions: ciFixActions, isCI: true
            )
        } else {
            categoryAccessory
        }
    }

    @ViewBuilder
    private var categoryAccessory: some View {
        switch item.category {
        case .myFeedback:
            HStack(spacing: 6) {
                if offersFixCI {
                    FixCIButton(unavailableReason: model.ciFixUnavailableReason(item)) { model.startCIFix(item) }
                }
                RespondButton(
                    phase: respond.phases[item.id], runningTests: respond.runningTests.contains(item.id),
                    unavailableReason: model.respondUnavailableReason(item), hasRecord: respond.records[item.id] != nil,
                    actions: respondActions
                )
            }
        case .toReview, .updatedSinceMyReview:
            ReviewButton(phase: reviews.phases[item.id], unavailableReason: model.jobsBlockedReason, actions: reviewActions)
        case .readyToMerge:
            MergeButton(phase: merges.phases[item.id], availability: model.mergeOptions(item).availability, actions: mergeActions)
        default:
            if offersFixCI {
                FixCIButton(unavailableReason: model.ciFixUnavailableReason(item)) { model.startCIFix(item) }
            } else {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open on GitHub") { NSWorkspace.shared.open(pr.url) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
        }
        if hasReviewButton {
            Divider()
            let actions = reviewActions
            switch reviews.phases[item.id] {
            case nil:
                Button("Review with Claude", action: actions.start)
            case .failed?:
                Button("Review with Claude", action: actions.retry)
            case let phase? where phase.isActive:
                // Pregunta lo mismo que la pastilla (`CancellablePill`).
                Button("Cancel Review") { confirmCancel("review", "Cancel Review", actions.cancel) }
            case .ready?, .published?:
                Button("View Review", action: actions.open)
            default:
                EmptyView()
            }
        }
        if model.isCIFixCandidate(item) || hasCIFix {
            Divider()
            if hasCIFix {
                if respond.phases[item.id]?.isActive == true {
                    Button("Cancel Fix CI") { confirmCancel("CI fix", "Cancel CI Fix", ciFixActions.cancel) }
                        .disabled(respond.phases[item.id] == .pushing)
                }
                Button("View Fix CI", action: ciFixActions.open).disabled(respond.records[item.id] == nil)
            } else {
                Button("Fix CI with Claude") { model.startCIFix(item) }
                    .disabled(model.ciFixUnavailableReason(item) != nil)
            }
        }
        if item.category == .myFeedback && !hasCIFix {
            Divider()
            let actions = respondActions
            let phase = respond.phases[item.id]
            if phase?.isActive == true {
                Button("Cancel") { confirmCancel("response", "Cancel Response", actions.cancel) }
                    .disabled(phase == .pushing)
            } else {
                Button("Respond with Claude", action: actions.retry)
                    .disabled(model.respondUnavailableReason(item) != nil || isLockedForRespond(phase))
            }
            if respond.records[item.id] != nil {
                Button("View Response", action: actions.open)
            }
        }
        if item.category == .readyToMerge {
            Divider()
            // Spec G.1: el método se elige en la ventana (no hay "Merge With…").
            Button("Merge…") { model.requestMerge(item) }
                .disabled(MergeFlow.request(phase: merges.phases[item.id]) == .ignore)
        }
    }

    /// Con fixes sin pushear (o tests corriendo) no se vuelve a analizar: primero hay que pushear o descartar.
    private func isLockedForRespond(_ phase: RespondPhase?) -> Bool {
        if respond.runningTests.contains(item.id) { return true }
        if case .readyToPush? = phase { return true }
        return false
    }

    /// Todo lo que muestra la fila, en una sola frase para VoiceOver.
    private var accessibilityLabel: String {
        let updated = Date().timeIntervalSince(pr.updatedAt) < 60
            ? "updated just now" : "updated \(RelativeAge.short(from: pr.updatedAt)) ago"
        var parts = [pr.title, "\(pr.repo.name) number \(pr.number)", "by \(pr.author)", "into \(pr.baseRef)", updated]
        if let ci = CIIcon.label(for: pr.ciState) { parts.append(ci) }
        parts.append("\(pr.additions) \(pr.additions == 1 ? "line" : "lines") added, \(pr.deletions) removed")
        if item.category == .myFeedback {
            let feedback = ActionClassifier.newFeedback(pr, me: item.account)
            parts.append(FeedbackLabel.text(for: feedback))
        }
        if item.category == .readyToMerge {
            parts.append(MergeStatusLabel.text(for: model.mergeOptions(item).availability))
        }
        if let shownPlacement { parts.append(shownPlacement) }
        return parts.joined(separator: ", ")
    }

    /// Lo mismo que pregunta la pastilla al cancelar (`CancellablePill`), desde el menú contextual (L10).
    private func confirmCancel(_ job: String, _ action: String, _ cancel: @escaping () -> Void) {
        if model.confirmFromPopover(title: "Cancel this \(job)?", message: "Claude stops and what it did so far is lost.",
                                    action: action) {
            cancel()
        }
    }

    private var respondActions: RespondButtonActions {
        let model = self.model
        let item = self.item
        let respond = self.respond
        return RespondButtonActions(
            start: { model.startRespond(item) },
            cancel: { model.cancelRespond(prID: item.id) },
            open: { model.openRespond(prID: item.id) },
            retry: {
                // Con fixes hechos (o commits que dejó una implementación) no se vuelve a analizar: la ventana reintenta
                // la publicación, o pregunta antes de descartarlos.
                if respond.records[item.id]?.result != nil || respond.unpushedWork.contains(item.id) {
                    model.openRespond(prID: item.id)
                } else {
                    model.startRespond(item)
                }
            },
            dismiss: { model.confirmDismissRespond(prID: item.id) }
        )
    }

    private var ciFixActions: RespondButtonActions {
        let model = self.model
        let item = self.item
        let respond = self.respond
        return RespondButtonActions(
            start: { model.startCIFix(item) },
            cancel: { model.cancelRespond(prID: item.id) },
            open: { model.openRespond(prID: item.id) },
            retry: {
                // With a fix already made (or commits a canceled fix left), the window retries the push or asks before
                // discarding it.
                if respond.records[item.id]?.result != nil || respond.unpushedWork.contains(item.id) {
                    model.openRespond(prID: item.id)
                } else {
                    model.startCIFix(item)
                }
            },
            dismiss: { model.confirmDismissRespond(prID: item.id) }
        )
    }

    private var reviewActions: ReviewButtonActions {
        let model = self.model
        let item = self.item
        return ReviewButtonActions(
            start: { model.startReview(item) },
            cancel: { model.cancelReview(prID: item.id) },
            open: { model.openReview(prID: item.id) },
            retry: { model.startReview(item) },
            dismiss: { model.dismissReview(prID: item.id) }
        )
    }

    private var mergeActions: MergeButtonActions {
        let model = self.model
        let item = self.item
        return MergeButtonActions(
            open: { model.requestMerge(item) },
            dismiss: { model.dismissMergeError(prID: item.id) }
        )
    }
}

/// Dónde va el botón Review dentro de la fila (ver `PRRowView.body`).
private struct AccessoryAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
