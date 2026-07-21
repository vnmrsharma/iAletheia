import Foundation

/// Loads secrets from `.env.local` for local development.
/// Priority at runtime: Keychain -> `.env.local` -> process environment.
enum EnvLoader {
    private static var loadedValues: [String: String] = [:]
    private static var didLoad = false

    static func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        for url in candidateFileURLs() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            loadedValues.merge(parse(contents)) { _, new in new }
            break
        }
    }

    static func value(for key: String) -> String? {
        loadIfNeeded()
        if let value = loadedValues[key], !value.isEmpty { return value }
        return ProcessInfo.processInfo.environment[key]
    }

    private static func candidateFileURLs() -> [URL] {
        var urls: [URL] = []
        let fileName = ".env.local"

        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(fileName))

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(fileName))
            urls.append(resourceURL.deletingLastPathComponent().appendingPathComponent(fileName))
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        urls.append(sourceRoot.appendingPathComponent(fileName))

        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    private static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("export ") {
                trimmed = String(trimmed.dropFirst(7))
            }
            guard let index = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<index]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: index)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
