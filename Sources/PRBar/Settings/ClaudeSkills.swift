import Foundation
import PRBarCore

/// The skills that Settings → Claude offers: the installed plugins' skills and commands, plus the user skills
/// (`~/.claude/skills`), which are only enabled if a read-only probe shows that they load in PRBar's isolated
/// runs. The probe (`ClaudeSkillProbe`, a short Haiku run) runs at most once per app session, and only if there
/// are user skills.
@MainActor
final class ClaudeSkills: ObservableObject {
    @Published private(set) var entries: [ClaudeSkillEntry] = []
    /// The first scan finished.
    @Published private(set) var loaded = false
    /// The probe is running.
    @Published private(set) var probing = false

    private var scanned: [ClaudeSkillEntry] = []
    /// What loaded in the isolated probe; `nil` = not probed yet.
    private var probed: Set<String>?
    private let runner = SystemProcessRunner(killGracePeriod: 5)
    /// Fixed list (snapshot mode): `refresh` neither scans the disk nor runs the probe.
    private let isFixed: Bool

    init() {
        isFixed = false
    }

    /// Snapshot mode: these entries, already loaded.
    init(fixedEntries: [ClaudeSkillEntry]) {
        isFixed = true
        entries = fixedEntries
        loaded = true
    }

    func entry(_ id: String) -> ClaudeSkillEntry? { entries.first { $0.id == id } }

    /// Rescans the plugins and the user skills (cheap: only files). `claudePath`: `nil` while the tools aren't
    /// resolved; `toolsResolved` with no path means claude wasn't found, so user skills can't load.
    func refresh(claudePath: String?, toolsResolved: Bool, settings: ClaudeSettings) async {
        guard !isFixed else { return }
        scanned = await Task.detached(priority: .userInitiated) { ClaudeSkillCatalog.scan() }.value
        publish()
        loaded = true
        guard probed == nil, !probing, ClaudeSkillCatalog.hasUserSkills(scanned) else { return }
        guard let claudePath else {
            if toolsResolved {
                probed = []
                publish()
            }
            return
        }
        probing = true
        defer { probing = false }
        let pluginDirs = (try? ClaudePlugins.locate(skills: settings.reviewSkills + settings.respondSkills)) ?? []
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-skill-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            probed = try await ClaudeSkillProbe.run(runner: runner, claudePath: claudePath, pluginDirs: pluginDirs,
                                                    directory: directory)
        } catch {
            AppLog.write("Couldn't check which user skills load in isolated runs: \(error.localizedDescription)")
            probed = []
        }
        publish()
    }

    private func publish() {
        entries = probed.map { ClaudeSkillCatalog.applying(probe: $0, to: scanned) } ?? scanned
    }
}
