import CryptoKit
import Foundation
import PRBarWire

/// The offline cache (spec R.3): JSON in the App Group container, `Cache/home.json` and `Cache/pr/<sha256>.json`
/// (at most 50 PRs, least recently written first out), protected until first unlock. Wiped on unpair.
public struct Cache: Sendable {
    public struct Entry<Value: Codable & Sendable>: Codable, Sendable {
        public var rev: Int
        public var savedAt: Date
        public var value: Value
    }

    public let directory: URL
    public let maxPRs: Int

    public init(directory: URL, maxPRs: Int = 50) {
        self.directory = directory
        self.maxPRs = maxPRs
    }

    /// Data protection: readable after the first unlock since boot (the app may wake for a push), never before.
    public static var writingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    var homeURL: URL { directory.appendingPathComponent("home.json") }
    var prDirectory: URL { directory.appendingPathComponent("pr", isDirectory: true) }

    public static func fileName(forPR id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    public func saveHome(_ home: RemoteHome, rev: Int, at date: Date) throws {
        try write(Entry(rev: rev, savedAt: date, value: home), to: homeURL)
    }

    public func loadHome() -> Entry<RemoteHome>? { read(homeURL) }

    public func savePR(_ detail: RemotePRDetail, id: String, rev: Int, at date: Date) throws {
        let url = prDirectory.appendingPathComponent(Self.fileName(forPR: id))
        try write(Entry(rev: rev, savedAt: date, value: detail), to: url)
        try trimPRs()
    }

    public func loadPR(_ id: String) -> Entry<RemotePRDetail>? {
        read(prDirectory.appendingPathComponent(Self.fileName(forPR: id)))
    }

    var mailboxURL: URL { directory.appendingPathComponent("mailbox.json") }

    public func wipe() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public var cachedPRCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: prDirectory.path).count) ?? 0
    }

    private func write<Value: Codable & Sendable>(_ entry: Entry<Value>, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CommandProtocol.encoder.encode(entry).write(to: url, options: Self.writingOptions)
    }

    private func read<Value: Codable & Sendable>(_ url: URL) -> Entry<Value>? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CommandProtocol.decoder.decode(Entry<Value>.self, from: data)
    }

    /// Least recently saved out first. `savedAt` inside the file decides (file dates are too coarse to order writes).
    private func trimPRs() throws {
        let files = try FileManager.default.contentsOfDirectory(at: prDirectory, includingPropertiesForKeys: nil)
        guard files.count > maxPRs else { return }
        let dated: [(URL, Date)] = files.map { url in
            let entry: Entry<JSONValue>? = read(url)
            return (url, entry?.savedAt ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxPRs) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// The last mailbox revision per slot (`mailbox.json`, wiped with the rest of the cache).
extension Cache: MailboxRevisionStore {
    public func loadMailboxRevisions() -> [String: Int] {
        guard let data = try? Data(contentsOf: mailboxURL),
              let revisions = try? CommandProtocol.decoder.decode([String: Int].self, from: data) else { return [:] }
        return revisions
    }

    public func saveMailboxRevisions(_ revisions: [String: Int]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? CommandProtocol.encoder.encode(revisions).write(to: mailboxURL, options: Self.writingOptions)
    }
}
