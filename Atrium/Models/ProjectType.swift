import Foundation

enum ProjectType: String, Codable, CaseIterable {
    case swiftPackage
    case nextjs
    case expo
    case reactNative
    case react
    case typescript
    case nodejs
    case python
    case rust
    case go
    case flutter
    case docker
    case ruby
    case android
    case git
    case unknown

    var displayName: String {
        switch self {
        case .swiftPackage: "Swift"
        case .nextjs:       "Next.js"
        case .expo:         "Expo"
        case .reactNative:  "React Native"
        case .react:        "React"
        case .typescript:   "TypeScript"
        case .nodejs:       "Node.js"
        case .python:       "Python"
        case .rust:         "Rust"
        case .go:           "Go"
        case .flutter:      "Flutter"
        case .docker:       "Docker"
        case .ruby:         "Ruby"
        case .android:      "Android"
        case .git:          "Git"
        case .unknown:      "Unknown"
        }
    }

    var iconName: String {
        switch self {
        case .swiftPackage: "swift"
        case .nextjs:       "nextdotjs"
        case .expo:         "expo"
        case .reactNative:  "react"
        case .react:        "react"
        case .typescript:   "typescript"
        case .nodejs:       "nodedotjs"
        case .python:       "python"
        case .rust:         "rust"
        case .go:           "go"
        case .flutter:      "flutter"
        case .docker:       "docker"
        case .ruby:         "ruby"
        case .android:      "android"
        case .git:          "git"
        case .unknown:      ""
        }
    }

    /// Detect the project type by scanning for marker files at the given URL.
    /// Checks are ordered by specificity — more specific markers win.
    static func detect(at url: URL) -> ProjectType {
        let fm = FileManager.default
        let path = url.path

        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: (path as NSString).appendingPathComponent(name))
        }

        func hasExtension(_ ext: String) -> Bool {
            guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return false }
            return contents.contains { ($0 as NSString).pathExtension == ext }
        }

        // Swift (Xcode project, workspace, or standalone Swift package)
        if hasExtension("xcodeproj") || hasExtension("xcworkspace") || exists("Package.swift") {
            return .swiftPackage
        }

        // Next.js (check before generic React)
        if exists("next.config.js") || exists("next.config.mjs") || exists("next.config.ts") {
            return .nextjs
        }

        // Expo / React Native
        if exists("app.json") || exists("app.config.js") || exists("app.config.ts") {
            // Distinguish Expo from plain React Native
            if exists("expo") || exists(".expo") {
                return .expo
            }
            // Check package.json for expo dependency
            if let data = fm.contents(atPath: (path as NSString).appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let deps = json["dependencies"] as? [String: Any],
               deps["expo"] != nil {
                return .expo
            }
        }

        // React Native (has react-native in deps but not Expo)
        if exists("package.json"),
           let data = fm.contents(atPath: (path as NSString).appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let deps = json["dependencies"] as? [String: Any] {
            if deps["react-native"] != nil {
                return .reactNative
            }
        }

        // Flutter
        if exists("pubspec.yaml") {
            return .flutter
        }

        // Rust
        if exists("Cargo.toml") {
            return .rust
        }

        // Go
        if exists("go.mod") {
            return .go
        }

        // Android (Gradle-based)
        if exists("build.gradle") || exists("build.gradle.kts") {
            if exists("app/src/main/AndroidManifest.xml") {
                return .android
            }
        }

        // Ruby
        if exists("Gemfile") {
            return .ruby
        }

        // Python
        if exists("pyproject.toml") || exists("requirements.txt") || exists("setup.py") || exists("Pipfile") {
            return .python
        }

        // Docker (standalone)
        if exists("Dockerfile") || exists("docker-compose.yml") || exists("docker-compose.yaml") || exists("compose.yml") {
            return .docker
        }

        // TypeScript (check before generic Node)
        if exists("tsconfig.json") {
            // Check for React in deps
            if exists("package.json"),
               let data = fm.contents(atPath: (path as NSString).appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let deps = json["dependencies"] as? [String: Any],
               deps["react"] != nil {
                return .react
            }
            return .typescript
        }

        // Node.js / generic JS with React check
        if exists("package.json") {
            if let data = fm.contents(atPath: (path as NSString).appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let deps = json["dependencies"] as? [String: Any],
               deps["react"] != nil {
                return .react
            }
            return .nodejs
        }

        // Generic git repo
        if exists(".git") {
            return .git
        }

        return .unknown
    }
}
