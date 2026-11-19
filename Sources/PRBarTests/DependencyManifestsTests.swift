import Foundation
import PRBarCore

private func json(_ text: String) -> Data { Data(text.utf8) }

enum DependencyManifestsTests {
    static let cases: [TestCase] = [
        TestCase("dependency manifests: nombres en cualquier carpeta, sin distinguir mayúsculas") {
            for path in ["package.json", "web/package-lock.json", "Package.swift", "Package.resolved", "Gemfile.lock",
                         "requirements-dev.txt", "go.mod", "svc/Cargo.toml", "android/app/build.gradle.kts", "Podfile.lock"] {
                try expect(DependencyManifests.isManifest(path), path)
            }
            for path in ["src/package.ts", "README.md", "go.modules.md", "requirements.md"] {
                try expect(!DependencyManifests.isManifest(path), path)
            }
        },
        TestCase("dependency manifests: en package.json solo cuentan las secciones de dependencias") {
            let base = json(#"{"name":"x","scripts":{"test":"jest"},"dependencies":{"a":"1.0.0"}}"#)
            try expect(!DependencyManifests.packageJSONDependenciesChanged(
                before: base, after: json(#"{"name":"x","scripts":{"test":"vitest"},"dependencies":{"a":"1.0.0"}}"#)))
            try expect(DependencyManifests.packageJSONDependenciesChanged(
                before: base, after: json(#"{"name":"x","scripts":{"test":"jest"},"dependencies":{"a":"1.0.0","b":"2.0.0"}}"#)))
            try expect(DependencyManifests.packageJSONDependenciesChanged(
                before: base, after: json(#"{"name":"x","devDependencies":{"c":"1"},"dependencies":{"a":"1.0.0"},"scripts":{"test":"jest"}}"#)))
            try expect(DependencyManifests.packageJSONDependenciesChanged(before: nil, after: base))
            try expect(DependencyManifests.packageJSONDependenciesChanged(before: base, after: json("{ broken")))
        },
    ]
}
