import PRBarCore
import SwiftUI

/// El chat de la pestaña del PR, en el inspector de 300 pt (spec M.1 "Modo foco y chat"): Review y Details, el de la
/// review; Respond y Fix CI, el de su análisis; Merge, el de la sesión de merge.
struct ChatInspector: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue
    let prID: String
    let tab: PRTab

    init(model: AppModel, prID: String, tab: PRTab) {
        self.model = model
        reviews = model.reviews
        respond = model.respond
        self.prID = prID
        self.tab = tab
    }

    var body: some View {
        switch tab {
        case .review, .details:
            if let draft = reviewDraft {
                let chat = model.reviewChat(for: draft)
                ChatPanel(chat: chat, unavailableReason: model.chatUnavailableReason(for: chat),
                          notice: model.isOutdated(draft) ? "This review is for an older commit." : nil,
                          host: model.chatHost(chat), logURL: model.history.logURL(for: draft.id))
            } else {
                placeholder("Start a review to chat with Claude about this PR.")
            }
        case .respond, .fixCI:
            if let draft = respond.records[prID]?.draft {
                let chat = model.respondChat(for: draft)
                ChatPanel(chat: chat, unavailableReason: model.chatUnavailableReason(for: chat), notice: nil,
                          host: model.chatHost(chat), logURL: model.respondHistory.logURL(for: draft.id))
            } else {
                placeholder(tab == .fixCI ? "Start Fix CI to chat with Claude." : "Start Respond to chat with Claude.")
            }
        case .merge:
            if let item = model.currentItem(prID) {
                MergeChatPanel(model: model, session: model.mergeSession(for: item))
            } else {
                placeholder("The chat needs the PR in PRBar’s list.")
            }
        }
    }

    /// El draft listo o el último publicado.
    private var reviewDraft: ReviewDraft? {
        switch reviews.phases[prID] {
        case .ready(let draft)?: draft
        case .published?: model.publishedReviewRecord(prID: prID)?.draft
        default: nil
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
