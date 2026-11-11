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
    case none

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
        case .none:         "Don’t Show Icon"
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
        case .unknown, .none: ""
        }
    }
}
