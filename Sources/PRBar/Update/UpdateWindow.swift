import AppKit
import PRBarCore
import SwiftUI

/// Lo que muestra la ventana de actualización.
enum UpdateWindowMode: Equatable {
    /// Hay una versión nueva: notas, Update / Skip This Version / Later, y el progreso.
    case available(ReleaseInfo)
    /// La versión nueva acaba de arrancar después de actualizarse.
    case installed(PendingUpdate)

    var id: String {
        switch self {
        case .available(let release): "available-\(release.version)"
        case .installed(let update): "installed-\(update.version)"
        }
    }

    var title: String {
        switch self {
        case .available: "Update PRBar"
        case .installed: "PRBar Updated"
        }
    }
}

struct UpdateWindow: View {
    static let size = NSSize(width: 540, height: 460)

    @ObservedObject var updates: UpdateController
    let mode: UpdateWindowMode
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            notesView
            if case .available = mode { progress }
            HStack(spacing: 8) { buttons }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    // MARK: Encabezado y notas

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.title3.weight(.semibold))
                Text(subheadline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        switch mode {
        case .available(let release): "PRBar \(release.version) is available"
        case .installed(let update): "Updated to PRBar \(update.version)"
        }
    }

    private var subheadline: String {
        switch mode {
        case .available:
            "You have \(updates.currentVersion). PRBar builds the new version from its source on GitHub, which takes a minute or two, and then restarts."
        case .installed:
            "Here’s what’s new."
        }
    }

    private var notes: String {
        switch mode {
        case .available(let release): release.notes
        case .installed(let update): update.notes
        }
    }

    private var notesView: some View {
        ScrollView {
            Text(Self.markdown(notes.isEmpty ? "No release notes." : notes))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
    }

    /// Markdown en línea (negrita, código, links) respetando los saltos de línea de las notas.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: Progreso

    @ViewBuilder
    private var progress: some View {
        switch updates.installState {
        case .idle:
            if updates.installedApp == nil {
                Label("PRBar isn’t running as PRBar.app, so it can’t update itself. Install it with Scripts/bundle.sh --install.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .running(let phase):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase == .waitingForJobs ? Self.waitingText(updates.waitingJobs) : phase.title).font(.callout)
                }
                logView
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.redText)
                    .fixedSize(horizontal: false, vertical: true)
                logView
            }
        }
    }

    static func waitingText(_ count: Int) -> String {
        count == 1 ? "Waiting for 1 running job to finish…" : "Waiting for \(count) running jobs to finish…"
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(updates.log.suffix(200).enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(item.offset)
                    }
                }
                .padding(6)
            }
            .frame(height: 90)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
            .onChange(of: updates.log.count) {
                proxy.scrollTo(min(updates.log.count, 200) - 1, anchor: .bottom)
            }
        }
    }

    // MARK: Botones

    @ViewBuilder
    private var buttons: some View {
        switch mode {
        case .installed:
            Spacer()
            Button("OK", action: close).keyboardShortcut(.defaultAction)
        case .available(let release):
            switch updates.installState {
            case .running(let phase):
                Button("Show Log") { UpdateController.openLog() }
                Spacer()
                Button("Hide", action: close)
                Button("Cancel") { updates.cancelInstall() }
                    .disabled(phase == .installing || phase == .relaunching)
            case .idle, .failed:
                Button("Skip This Version") {
                    updates.skip(release)
                    close()
                }
                if case .failed = updates.installState {
                    Button("Show Log") { UpdateController.openLog() }
                }
                Spacer()
                Button("Later", action: close).keyboardShortcut(.cancelAction)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    installButtons(release, jobs: updates.runningJobs)
                }
            }
        }
    }

    /// Sin trabajos: "Update". Con trabajos: esperar o cancelarlos (spec D.3, paso 1).
    @ViewBuilder
    private func installButtons(_ release: ReleaseInfo, jobs: Int) -> some View {
        let retry = updates.installState != .idle
        HStack(spacing: 8) {
            if jobs == 0 {
                Button(retry ? "Try Again" : "Update") { install(release, whenBusy: .wait) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel Jobs and Update") { install(release, whenBusy: .cancelJobs) }
                    .help("Cancels running reviews, analyses and fixes. Posting and pushing finish first.")
                Button("Update When Done") { install(release, whenBusy: .wait) }
                    .keyboardShortcut(.defaultAction)
                    .help("\(jobs) job\(jobs == 1 ? " is" : "s are") running.")
            }
        }
        .disabled(updates.installedApp == nil)
    }

    /// With Respond fixes that aren't pushed it asks first: the restart forgets them (their worktrees stay).
    private func install(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy) {
        let unpushed = updates.unpushedFixes()
        guard unpushed > 0 else { return updates.startInstall(release, whenBusy: whenBusy) }
        ConfirmAlert.present(title: "Update while fixes aren’t pushed?", message: QuitConfirmation.unpushedMessage(unpushed),
                             action: "Update") {
            updates.startInstall(release, whenBusy: whenBusy)
        }
    }
}
