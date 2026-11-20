import CryptoKit
import Foundation

/// Lo que el guardián de integridad lee o toca del disco donde vive el worktree (§14.6, decisión J.7.8). Las rutas son
/// absolutas en esa máquina. La lógica (qué es un cambio y qué corta) está en `FixImplementer`/`WorktreeIntegrity`,
/// igual para las dos implementaciones.
public protocol WorkspaceFS: Sendable {
    /// El `HOME` de esa máquina (para `~/` en los `include.path` de git).
    var home: String { get }
    func snapshot(_ root: String) async throws -> WorktreeIntegrity.Snapshot
    func nestedGitEntries(_ root: String) async throws -> [String]
    /// `GitPaths.describe` de cada ruta.
    func describe(_ paths: [String]) async throws -> [String: String]
    /// Cada raíz y todo lo de adentro (sin seguir symlinks ni mirar metadatos de macOS), descriptos.
    func describeTrees(_ roots: [String]) async throws -> [String: String]
    /// `GitPaths.addModules`: lo descripto y los `config` encontrados.
    func modules(_ root: String) async throws -> (entries: [String: String], configs: [String])
    /// El texto de un archivo regular de hasta `limit` bytes (sigue symlinks, como `FileManager.contents`), o nil.
    func readText(_ path: String, limit: Int) async throws -> String?
    func removeCreatedFile(_ relative: String, in root: String) async throws
    func neutralizeSymlinks(_ relatives: [String], in root: String) async throws
    /// Una ruta nueva para un archivo temporal en esa máquina (el índice de git de un snapshot del chat).
    func temporaryFilePath(_ prefix: String) throws -> String
    /// Borra un archivo de `temporaryFilePath`. Nunca lanza.
    func removeTemporaryFile(_ path: String) async
}

public struct LocalWorkspaceFS: WorkspaceFS {
    public init() {}

    public var home: String { NSHomeDirectory() }

    public func snapshot(_ root: String) async throws -> WorktreeIntegrity.Snapshot {
        .take(URL(fileURLWithPath: root, isDirectory: true))
    }

    public func nestedGitEntries(_ root: String) async throws -> [String] {
        WorktreeIntegrity.nestedGitEntries(in: URL(fileURLWithPath: root, isDirectory: true))
    }

    public func describe(_ paths: [String]) async throws -> [String: String] {
        Dictionary(paths.map { ($0, FixImplementer.GitPaths.describe($0)) }, uniquingKeysWith: { first, _ in first })
    }

    public func describeTrees(_ roots: [String]) async throws -> [String: String] {
        var entries: [String: String] = [:]
        for root in roots { FixImplementer.GitPaths.addTree(root, to: &entries) }
        return entries
    }

    public func modules(_ root: String) async throws -> (entries: [String: String], configs: [String]) {
        var entries: [String: String] = [:]
        var configs: [String] = []
        FixImplementer.GitPaths.addModules(root, to: &entries, configs: &configs)
        return (entries, configs)
    }

    public func readText(_ path: String, limit: Int) async throws -> String? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= limit,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func removeCreatedFile(_ relative: String, in root: String) async throws {
        try FixImplementer.removeCreatedFile(relative, in: URL(fileURLWithPath: root, isDirectory: true))
    }

    public func neutralizeSymlinks(_ relatives: [String], in root: String) async throws {
        for path in relatives { try WorktreeManager.neutralizeSymlink(at: path, in: URL(fileURLWithPath: root, isDirectory: true)) }
    }

    public func temporaryFilePath(_ prefix: String) throws -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)").path
    }

    public func removeTemporaryFile(_ path: String) async { try? FileManager.default.removeItem(atPath: path) }
}

/// El guardián en otra máquina: el script Perl de `RemoteGuard` recolecta y este tipo arma los mismos valores que
/// `LocalWorkspaceFS`. Cada registro de la salida son tres campos terminados en NUL: `tipo`, `a`, `b`.
public struct RemoteWorkspaceFS: WorkspaceFS {
    public typealias GuardRunner = @Sendable (_ arguments: [String]) async throws -> ProcessResult

    public let home: String
    let label: String
    /// Donde van los archivos temporales en esa máquina (en un host, `<raíz>/tmp`).
    let temporaryDirectory: String
    let removeTemporary: @Sendable (String) async -> Void
    let runGuard: GuardRunner

    public init(home: String, label: String, temporaryDirectory: String = FileManager.default.temporaryDirectory.path,
                removeTemporary: @escaping @Sendable (String) async -> Void = { try? FileManager.default.removeItem(atPath: $0) },
                runGuard: @escaping GuardRunner) {
        self.home = home
        self.label = label
        self.temporaryDirectory = temporaryDirectory
        self.removeTemporary = removeTemporary
        self.runGuard = runGuard
    }

    /// Por ssh: `perl - <args>` con el guardián por stdin y `env -i` (sin `PERL5OPT`). Los temporales, en `<raíz>/tmp`.
    public static func ssh(host: SSHHost, home: String, root: RemoteRoot) -> RemoteWorkspaceFS {
        RemoteWorkspaceFS(home: home, label: host.name, temporaryDirectory: root.tmp,
                          removeTemporary: { path in await host.removeFiles([path], root: root) }) { arguments in
            let script = try RemoteGuard.localScriptFile()
            return try await host.run(RemoteExec(argv: ["perl", "-"] + arguments, environment: RemoteEnvironment.perl(),
                                                 standardInput: .passThrough), timeout: 300, standardInput: script)
        }
    }

    /// El mismo script corrido en la Mac (tests de paridad).
    public static func local(perl: String = "/usr/bin/perl",
                             temporaryDirectory: String = FileManager.default.temporaryDirectory.path) -> RemoteWorkspaceFS {
        RemoteWorkspaceFS(home: NSHomeDirectory(), label: "this Mac", temporaryDirectory: temporaryDirectory) { arguments in
            try await SystemProcessRunner().runWithFiles(perl, ["-"] + arguments, environment: ["PERL5OPT": ""], currentDirectory: nil,
                                                         timeout: 300, standardInput: try RemoteGuard.localScriptFile(),
                                                         standardOutput: nil, onStdoutLine: nil)
        }
    }

    func records(_ arguments: [String]) async throws -> [(String, String, String)] {
        let result = try await runGuard(arguments)
        guard result.status == 0 else {
            throw RemoteRunnerError.guardFailed(host: label, detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var fields = result.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if fields.last == "" { fields.removeLast() }
        // Empieza con el encabezado y solo trae tipos conocidos: algo que imprime el rc del shell de login antes del
        // script (o cualquier otra cosa) corta en vez de leerse como registros.
        guard fields.count % 3 == 0, fields.count >= 3, Array(fields[0..<3]) == RemoteGuard.header else {
            throw RemoteRunnerError.malformedOutput(host: label, what: "integrity check output (does the login shell print something?)")
        }
        let records = stride(from: 3, to: fields.count, by: 3).map { (fields[$0], fields[$0 + 1], fields[$0 + 2]) }
        guard records.allSatisfy({ RemoteGuard.recordKinds.contains($0.0) }) else {
            throw RemoteRunnerError.malformedOutput(host: label, what: "integrity check output")
        }
        return records
    }

    /// Las rutas vienen en hex (los bytes tal cual, sin pasar por la decodificación de la salida): UTF-8 estricto.
    func path(_ hex: String) throws -> String {
        guard let data = Data(hex: hex), let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else {
            throw RemoteRunnerError.malformedOutput(host: label, what: "file name")
        }
        return text
    }

    /// Las claves en NFC (como las de git en la Mac) y el nombre real aparte. Dos nombres que solo difieren en la
    /// normalización (posible en Linux) no se pueden distinguir después: se corta.
    public func snapshot(_ root: String) async throws -> WorktreeIntegrity.Snapshot {
        var entries: [String: WorktreeIntegrity.Snapshot.Entry] = [:]
        var raw: [String: String] = [:]
        for (kind, hex, value) in try await records(["snapshot", root]) where kind == "S" {
            let parts = value.split(separator: " ")
            guard parts.count == 4, let type = UInt16(parts[0]), let size = Int64(parts[1]), let modified = Int64(parts[2]),
                  let inode = UInt64(parts[3]) else { throw RemoteRunnerError.malformedOutput(host: label, what: "file snapshot") }
            let path = try path(hex)
            let key = path.precomposedStringWithCanonicalMapping
            guard entries[key] == nil else {
                throw RemoteRunnerError.guardFailed(host: label, detail: "two files are named \(key.debugDescription) with different Unicode forms.")
            }
            entries[key] = .init(type: type, size: size, modified: modified, inode: inode)
            if !Array(key.utf8).elementsEqual(path.utf8) { raw[key] = path }
        }
        return WorktreeIntegrity.Snapshot(entries: entries, rawPaths: raw)
    }

    public func nestedGitEntries(_ root: String) async throws -> [String] {
        try await records(["nested", root]).filter { $0.0 == "N" }.map { try path($0.1).precomposedStringWithCanonicalMapping }.sorted()
    }

    private func pairs(_ arguments: [String]) async throws -> [String: String] {
        var result: [String: String] = [:]
        for (kind, hex, value) in try await records(arguments) where kind == "E" { result[try path(hex)] = value }
        return result
    }

    public func describe(_ paths: [String]) async throws -> [String: String] {
        paths.isEmpty ? [:] : try await pairs(["describe"] + paths)
    }

    public func describeTrees(_ roots: [String]) async throws -> [String: String] {
        roots.isEmpty ? [:] : try await pairs(["tree"] + roots)
    }

    public func modules(_ root: String) async throws -> (entries: [String: String], configs: [String]) {
        var entries: [String: String] = [:]
        var configs: [String] = []
        for (kind, hex, value) in try await records(["modules", root]) {
            if kind == "E" { entries[try path(hex)] = value }
            if kind == "C" { configs.append(try path(hex)) }
        }
        return (entries, configs)
    }

    public func readText(_ path: String, limit: Int) async throws -> String? {
        guard let record = try await records(["read", path, String(limit)]).first(where: { $0.0 == "R" }), record.1 == "ok" else { return nil }
        guard let data = Data(hex: record.2) else { throw RemoteRunnerError.malformedOutput(host: label, what: "file contents") }
        return String(decoding: data, as: UTF8.self)
    }

    public func removeCreatedFile(_ relative: String, in root: String) async throws {
        _ = try await records(["rmcreated", root, relative])
    }

    public func temporaryFilePath(_ prefix: String) throws -> String {
        temporaryDirectory + "/" + prefix + "-" + UUID().uuidString.lowercased()
    }

    public func removeTemporaryFile(_ path: String) async { await removeTemporary(path) }

    public func neutralizeSymlinks(_ relatives: [String], in root: String) async throws {
        guard !relatives.isEmpty else { return }
        _ = try await records(["neutralize", root, WorktreeManager.symlinkPlaceholder(target: "{target}")] + relatives)
    }
}

extension Data {
    /// Hex en minúscula o mayúscula; `nil` si no es hex.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

/// El guardián en Perl (decisión J.7.8). Solo recolecta; no decide nada. Se manda entero por stdin en cada llamada.
public enum RemoteGuard {
    /// El primer registro de toda salida.
    static let header = ["V", "prbar-guard", "1"]
    static let recordKinds: Set<String> = ["S", "N", "E", "C", "R", "X"]

    public static let script = #"""
    use strict;
    use warnings;
    use Fcntl qw(:mode O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);
    use Digest::SHA ();
    use Time::HiRes ();
    use Cwd ();
    binmode(STDOUT);

    sub out { print join("\0", $_[0], $_[1], defined $_[2] ? $_[2] : ''), "\0"; }
    # Las rutas salen en hex: los bytes exactos, sin normalizar ni decodificar.
    sub hx { return unpack('H*', $_[0]); }
    sub mac_meta { my ($n) = @_; return $n eq '.DS_Store' || substr($n, 0, 2) eq '._' || $n eq "Icon\r"; }
    sub utf8_ok { my ($s) = @_; my $c = $s; return utf8::decode($c); }
    # Todos los nombres, también `._*` (como `WorktreeIntegrity.directoryNames` en la Mac).
    sub entries {
        my ($dir) = @_;
        opendir(my $h, $dir) or return ();
        my @names = grep { $_ ne '.' && $_ ne '..' } readdir($h);
        closedir($h);
        return @names;
    }
    sub bad_relative {
        my ($rel) = @_;
        return 1 if $rel eq '' || substr($rel, 0, 1) eq '/';
        return scalar(grep { $_ eq '' || $_ eq '.' || $_ eq '..' } split(m{/}, $rel, -1));
    }
    sub describe {
        my ($p) = @_;
        my @st = lstat($p);
        return 'none' unless @st;
        my $mode = sprintf('%o', $st[2] & 07777);
        if (S_ISLNK($st[2])) { my $t = readlink($p); return 'link:' . (defined $t ? $t : '?'); }
        return "dir:$mode" if S_ISDIR($st[2]);
        if (S_ISREG($st[2])) {
            open(my $fh, '<:raw', $p) or return "file:$mode:unreadable:$st[7]";
            my $sha = Digest::SHA->new(256);
            $sha->addfile($fh);
            close($fh);
            return "file:$mode:" . $sha->hexdigest;
        }
        return 'other:' . $st[2];
    }
    sub tree {
        my ($root) = @_;
        out('E', hx($root), describe($root));
        my @stack = ($root);
        while (@stack) {
            my $dir = pop @stack;
            for my $name (entries($dir)) {
                my $path = "$dir/$name";
                my @st = lstat($path) or next;
                next if !S_ISDIR($st[2]) && mac_meta($name);
                out('E', hx($path), describe($path));
                push @stack, $path if S_ISDIR($st[2]);
            }
        }
    }
    sub walk_worktree {
        my ($mode, $root) = @_;
        my @stack = ('');
        while (@stack) {
            my $rel = pop @stack;
            my $dir = $rel eq '' ? $root : "$root/$rel";
            for my $name (entries($dir)) {
                next if $rel eq '' && $name eq '.git';
                my $child = $rel eq '' ? $name : "$rel/$name";
                die "a file name isn't valid UTF-8\n" unless utf8_ok($child);
                my @st = Time::HiRes::lstat("$root/$child");
                next unless @st;
                my $is_dir = S_ISDIR($st[2]);
                if ($mode eq 'nested') { out('N', hx($child), '') if $name eq '.git'; }
                elsif (!$is_dir) { out('S', hx($child), join(' ', $st[2] & S_IFMT, $st[7], sprintf('%.0f', $st[9] * 1e9), $st[1])); }
                push @stack, $child if $is_dir;
            }
        }
    }
    sub modules {
        my ($root) = @_;
        my %skip = map { $_ => 1 } qw(objects refs logs lfs rr-cache worktrees);
        my @stack = ($root);
        while (@stack) {
            my $dir = pop @stack;
            for my $name (entries($dir)) {
                my $path = "$dir/$name";
                my @st = lstat($path) or next;
                next if !S_ISDIR($st[2]) && mac_meta($name);
                if (S_ISDIR($st[2])) {
                    if ($name eq 'hooks') { tree($path); next; }
                    push @stack, $path unless $skip{$name};
                    next;
                }
                if ($name eq 'config' || $name eq 'config.worktree') { out('E', hx($path), describe($path)); out('C', hx($path), ''); }
            }
        }
    }
    sub read_text {
        my ($path, $limit) = @_;
        my @st = stat($path);
        if (!@st || !S_ISREG($st[2]) || $st[7] > $limit) { out('R', 'none', ''); return; }
        open(my $fh, '<:raw', $path) or do { out('R', 'none', ''); return; };
        local $/;
        my $data = <$fh>;
        close($fh);
        out('R', 'ok', unpack('H*', defined $data ? $data : ''));
    }
    sub inside {
        my ($real_root, $rel, $root) = @_;
        my ($parent, $name) = $rel =~ m{^(?:(.*)/)?([^/]+)$} or return ();
        my $real_parent = Cwd::realpath(defined $parent ? "$root/$parent" : $root);
        return ('missing', $name) unless defined $real_parent;
        return () unless $real_parent eq $real_root || index($real_parent, "$real_root/") == 0;
        return ($real_parent, $name);
    }
    sub rm_created {
        my ($root, $rel) = @_;
        die "Invalid path in the worktree: $rel\n" if bad_relative($rel);
        my $real_root = Cwd::realpath($root) // die "can't resolve the worktree\n";
        my ($parent, $name) = inside($real_root, $rel, $root);
        die "$rel is outside the worktree: not deleting it.\n" unless defined $parent;
        # Estaba en el snapshot: si ya no está, el árbol no es el que se inspeccionó.
        die "Couldn't delete $rel, which Claude created: it's gone\n" if $parent eq 'missing';
        unlink("$parent/$name") or die "Couldn't delete $rel, which Claude created: $!\n";
    }
    sub neutralize {
        my ($root, $template, @rels) = @_;
        my $real_root = Cwd::realpath($root) // die "can't resolve the worktree\n";
        for my $rel (@rels) {
            die "invalid path in the PR: $rel\n" if bad_relative($rel);
            my ($parent, $name) = inside($real_root, $rel, $root);
            die "the symlink $rel is outside the worktree\n" unless defined $parent;
            next if $parent eq 'missing' && utf8_ok($rel);
            my $full = "$parent/$name";
            my @st = lstat($full);
            unless (@st) { next if $!{ENOENT} && utf8_ok($rel); die "couldn't read $rel: $!\n"; }
            next unless S_ISLNK($st[2]);
            my $target = readlink($full);
            $target = '?' unless defined $target;
            unlink($full) or die "couldn't delete the symlink $rel: $!\n";
            sysopen(my $fh, $full, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644) or die "couldn't replace the symlink $rel: $!\n";
            my $text = $template;
            my $at = index($text, '{target}');
            substr($text, $at, 8) = $target if $at >= 0;
            binmode($fh);
            print {$fh} $text or die "couldn't write the replacement for $rel\n";
            close($fh) or die "couldn't write the replacement for $rel\n";
            out('X', hx($rel), '');
        }
    }

    out('V', 'prbar-guard', '1');
    my $cmd = shift(@ARGV) // '';
    my $ok = eval {
        if ($cmd eq 'snapshot' || $cmd eq 'nested') { walk_worktree($cmd, $ARGV[0]); }
        elsif ($cmd eq 'describe') { out('E', hx($_), describe($_)) for @ARGV; }
        elsif ($cmd eq 'tree') { tree($_) for @ARGV; }
        elsif ($cmd eq 'modules') { modules($ARGV[0]); }
        elsif ($cmd eq 'read') { read_text(@ARGV); }
        elsif ($cmd eq 'rmcreated') { rm_created(@ARGV); }
        elsif ($cmd eq 'neutralize') { neutralize(@ARGV); }
        else { die "unknown command\n"; }
        1;
    };
    unless ($ok) { print STDERR $@; exit 3; }
    exit 0;
    """#

    /// El script en un archivo local 0600 (nombre por su SHA-256), para mandarlo por stdin.
    public static func localScriptFile() throws -> URL {
        let digest = SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = LocalScratch.directory.appendingPathComponent("guard-\(digest.prefix(16)).pl")
        if let existing = FileManager.default.contents(atPath: url.path), existing == Data(script.utf8) { return url }
        let temp = try LocalScratch.file(with: Data(script.utf8))
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }
}
