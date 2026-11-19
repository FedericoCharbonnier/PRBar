import Foundation

/// Files that declare or lock dependencies (spec E.5, `allowNewDependencies`).
public enum DependencyManifests {
    /// File names (globs, case-insensitive) at any level: monorepos have them in subfolders.
    public static let fileNames = [
        "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
        "Package.swift", "Package.resolved", "Gemfile", "Gemfile.lock", "*.gemspec",
        "requirements*.txt", "Pipfile", "Pipfile.lock", "pyproject.toml", "poetry.lock", "setup.py", "setup.cfg",
        "go.mod", "go.sum", "Cargo.toml", "Cargo.lock", "Podfile", "Podfile.lock", "Cartfile", "Cartfile.resolved",
        "*.gradle", "*.gradle.kts", "*.versions.toml", "gradle.lockfile", "*.csproj", "packages.config", "composer.json", "composer.lock",
        "mix.exs", "mix.lock", "pubspec.yaml", "pubspec.lock",
    ]
    /// The sections of `package.json` that are dependencies, or change which versions are installed (npm
    /// `overrides`, Yarn `resolutions`, pnpm's settings with its `overrides`).
    public static let packageSections = ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies",
                                         "bundledDependencies", "bundleDependencies", "overrides", "resolutions", "pnpm"]

    public static func isManifest(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return fileNames.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }

    public static func isPackageJSON(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.lowercased() == "package.json"
    }

    /// A dependency section changed. A missing or unreadable version counts as a change (it can't be checked).
    public static func packageJSONDependenciesChanged(before: Data?, after: Data?) -> Bool {
        guard let old = sections(before), let new = sections(after) else { return true }
        return old != new
    }

    private static func sections(_ data: Data?) -> [String: String]? {
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for key in packageSections {
            guard let value = object[key],
                  let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
            else { continue }
            result[key] = String(decoding: encoded, as: UTF8.self)
        }
        return result
    }
}
