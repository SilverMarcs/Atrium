import Foundation

/// Wire protocol for the Atrium companion connection. Both the macOS server
/// (host) and the iOS client compile this file. Keep it dependency-free —
/// Foundation only — so the iOS target stays minimal.
///
/// Transport: a single TCP connection per client. Each frame is a 4-byte
/// big-endian length prefix followed by JSON-encoded `CompanionMessage` bytes.

public enum CompanionWire {
    public static let bonjourServiceType = "_atrium._tcp"
    public static let protocolVersion = 1
    /// Maximum frame size we'll accept. Generous for `sessionSnapshot`
    /// payloads but bounded so a malformed length prefix can't OOM us.
    public static let maxFrameBytes = 16 * 1024 * 1024
}

public enum CompanionKind: String, Codable, Sendable {
    // Client → Server
    case auth
    case listSessions
    case subscribe
    case unsubscribe
    case sendPrompt
    case createChat
    case archiveChat
    case disconnectChat
    case deleteChat
    case updateScratchpad
    case stopChat
    case setSessionModel
    case setSessionPermissionMode

    // Server → Client
    case hello
    case authResult
    case sessionsList
    case sessionSnapshot
    case sessionUpdate
    case chatCreated
    case error
}

/// Single envelope type for both directions. Optional fields are populated
/// based on `kind`; everything else stays `nil`. This is verbose but keeps
/// JSON round-tripping trivial on both sides without custom Codable.
public struct CompanionMessage: Codable, Sendable {
    public var kind: CompanionKind

    // auth
    public var token: String?
    /// Stable per-device identifier sent during `auth`. The server uses it
    /// to evict any prior connection from the same client (e.g. after the
    /// iPhone backgrounds, the OS kills the old socket but the server
    /// hasn't noticed yet) so the connected-clients count reflects unique
    /// devices instead of accumulated zombies.
    public var clientId: UUID?

    // subscribe / unsubscribe / sendPrompt / sessionUpdate / sessionSnapshot
    public var sessionId: UUID?

    // sendPrompt
    public var promptText: String?

    // createChat
    public var workspaceId: UUID?
    public var providerName: String?

    // updateScratchpad
    public var scratchpadText: String?

    // setSessionModel / setSessionPermissionMode — also patched in
    // sessionUpdate when the host changes selection on the Mac side.
    public var modelRawValue: String?
    public var permissionModeRawValue: String?

    // authResult
    public var ok: Bool?

    // authResult / error
    public var error: String?

    // hello
    public var serverName: String?
    public var version: Int?

    // sessionsList
    public var workspaces: [WireWorkspace]?
    /// Provider names (e.g. "Claude", "Codex", "Gemini") the host supports
    /// for new chats. Sent on `sessionsList` so iOS doesn't need to bake the
    /// list into its binary — adding a provider on the Mac shows up in the
    /// iOS "New Chat" menu after the next list refresh. Symbol/color come
    /// from the shared `ProviderStyle` lookup keyed on the same name.
    public var availableProviders: [String]?

    // sessionSnapshot
    public var session: WireSession?

    // sessionUpdate
    public var patch: WireSessionPatch?

    public init(kind: CompanionKind) {
        self.kind = kind
    }
}

public struct WireWorkspace: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// Raw image bytes of the user's custom workspace icon (PNG/JPEG/ICNS).
    /// nil when the workspace has no custom icon — iOS shows a folder
    /// fallback in that case. Sized once per `listSessions`, refreshed on
    /// pull-to-refresh; small enough at typical icon sizes (<200 KB) to ship
    /// inline without a separate asset request.
    public var customIconData: Data?
    public var isArchived: Bool
    /// Workspace-level scratchpad text. Carried in the workspace list so the
    /// iOS inspector can display + edit it without a separate fetch.
    public var scratchpad: String
    public var sessions: [WireSessionMeta]

    public init(id: UUID, name: String, customIconData: Data?, isArchived: Bool, scratchpad: String, sessions: [WireSessionMeta]) {
        self.id = id
        self.name = name
        self.customIconData = customIconData
        self.isArchived = isArchived
        self.scratchpad = scratchpad
        self.sessions = sessions
    }
}

public struct WireSessionMeta: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var workspaceId: UUID
    public var title: String
    public var date: Date
    public var turnCount: Int
    public var isProcessing: Bool
    public var isArchived: Bool
    public var providerName: String
    /// Whether the chat has a live ACP session attached on the host. iOS
    /// tints the provider icon when true, neutral when not — same idea as
    /// the macOS sidebar.
    public var isActive: Bool
    /// Mirror of `Chat.hasNotification`. iOS uses this to flag the row with
    /// a badge so the user can spot updates at a glance.
    public var hasNotification: Bool

    public init(id: UUID, workspaceId: UUID, title: String, date: Date, turnCount: Int, isProcessing: Bool, isArchived: Bool, providerName: String, isActive: Bool, hasNotification: Bool) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.date = date
        self.turnCount = turnCount
        self.isProcessing = isProcessing
        self.isArchived = isArchived
        self.providerName = providerName
        self.isActive = isActive
        self.hasNotification = hasNotification
    }
}

public struct WireSession: Codable, Sendable {
    public var meta: WireSessionMeta
    public var messages: [WireMessage]
    /// Inspector-only fields. Cheap to ship as part of the session
    /// snapshot since the iOS inspector reads them directly.
    public var modelLabel: String
    public var permissionLabel: String
    public var permissionSystemImage: String
    public var usedTokens: Int
    public var contextSize: Int
    /// Drives the iOS model picker. Available models are filtered by the
    /// session's provider on the host side, so iOS never has to know which
    /// models belong to which provider.
    public var availableModels: [WireAgentModel]
    public var modelRawValue: String
    public var availableModes: [WirePermissionMode]
    public var permissionModeRawValue: String
    /// Latest session-level error from the host (e.g. agent send failure).
    /// nil means the chat has no active error. iOS renders a red banner when
    /// set, mirroring the Mac's `ACPView` error label.
    public var error: String?

    public init(
        meta: WireSessionMeta,
        messages: [WireMessage],
        modelLabel: String,
        permissionLabel: String,
        permissionSystemImage: String,
        usedTokens: Int,
        contextSize: Int,
        availableModels: [WireAgentModel],
        modelRawValue: String,
        availableModes: [WirePermissionMode],
        permissionModeRawValue: String,
        error: String? = nil
    ) {
        self.meta = meta
        self.messages = messages
        self.modelLabel = modelLabel
        self.permissionLabel = permissionLabel
        self.permissionSystemImage = permissionSystemImage
        self.usedTokens = usedTokens
        self.contextSize = contextSize
        self.availableModels = availableModels
        self.modelRawValue = modelRawValue
        self.availableModes = availableModes
        self.permissionModeRawValue = permissionModeRawValue
        self.error = error
    }
}

/// Snapshot of one selectable model. Pure data — both sides read these as
/// opaque options without needing to know about the host's `AgentModel`
/// enum, so adding/removing models on the Mac doesn't require an iOS update.
public struct WireAgentModel: Codable, Sendable, Hashable, Identifiable {
    public var rawValue: String
    public var name: String
    public var imageName: String

    public var id: String { rawValue }

    public init(rawValue: String, name: String, imageName: String) {
        self.rawValue = rawValue
        self.name = name
        self.imageName = imageName
    }
}

public struct WirePermissionMode: Codable, Sendable, Hashable, Identifiable {
    public var rawValue: String
    public var label: String
    public var systemImage: String
    public var description: String

    public var id: String { rawValue }

    public init(rawValue: String, label: String, systemImage: String, description: String) {
        self.rawValue = rawValue
        self.label = label
        self.systemImage = systemImage
        self.description = description
    }
}

public struct WireMessage: Codable, Sendable, Identifiable, Hashable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: UUID
    public var role: Role
    public var turnIndex: Int
    /// Ordered content blocks. Text and tool-calls preserve the order the
    /// host saw them in, so the iOS view can collapse contiguous tool-call
    /// runs into a single badge while still rendering markdown text in
    /// between.
    public var blocks: [WireBlock]

    public init(id: UUID, role: Role, turnIndex: Int, blocks: [WireBlock]) {
        self.id = id
        self.role = role
        self.turnIndex = turnIndex
        self.blocks = blocks
    }
}

public struct WireBlock: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text
        case toolCall
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    /// SF Symbol name for tool-call blocks. Lets iOS render a small badge
    /// per call without needing to re-derive symbols from kind strings.
    public var toolSymbolName: String?

    public init(id: UUID, kind: Kind, text: String = "", toolSymbolName: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolSymbolName = toolSymbolName
    }
}

/// Sent on every change in a subscribed session. Fields that didn't change
/// are nil. The simplest correct patch is "full message list replacement",
/// which we use for MVP — chats are small enough that bandwidth doesn't
/// matter.
public struct WireSessionPatch: Codable, Sendable {
    public var title: String?
    public var date: Date?
    public var turnCount: Int?
    public var isProcessing: Bool?
    public var messages: [WireMessage]?
    public var modelLabel: String?
    public var permissionLabel: String?
    public var permissionSystemImage: String?
    public var usedTokens: Int?
    public var contextSize: Int?
    /// Carried so the iOS picker reflects model/permission changes the user
    /// makes on the Mac toolbar in real time. The available-options arrays
    /// don't change for a given session (provider is fixed once created),
    /// so they're not patched.
    public var modelRawValue: String?
    public var permissionModeRawValue: String?
    /// New error value when the session's error state changed. nil here is
    /// ambiguous between "no change" and "cleared", so `errorChanged` carries
    /// the disambiguation: when true, apply `error` (which may itself be nil
    /// to clear).
    public var error: String?
    public var errorChanged: Bool?

    public init(
        title: String? = nil,
        date: Date? = nil,
        turnCount: Int? = nil,
        isProcessing: Bool? = nil,
        messages: [WireMessage]? = nil,
        modelLabel: String? = nil,
        permissionLabel: String? = nil,
        permissionSystemImage: String? = nil,
        usedTokens: Int? = nil,
        contextSize: Int? = nil,
        modelRawValue: String? = nil,
        permissionModeRawValue: String? = nil,
        error: String? = nil,
        errorChanged: Bool? = nil
    ) {
        self.title = title
        self.date = date
        self.turnCount = turnCount
        self.isProcessing = isProcessing
        self.messages = messages
        self.modelLabel = modelLabel
        self.permissionLabel = permissionLabel
        self.permissionSystemImage = permissionSystemImage
        self.usedTokens = usedTokens
        self.contextSize = contextSize
        self.modelRawValue = modelRawValue
        self.permissionModeRawValue = permissionModeRawValue
        self.error = error
        self.errorChanged = errorChanged
    }
}

// MARK: - Framing

/// Reads/writes 4-byte big-endian length prefixes around JSON payloads.
public enum CompanionFraming {
    public static func encode(_ message: CompanionMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(message)
        precondition(body.count <= CompanionWire.maxFrameBytes, "frame too large")
        var prefix = UInt32(body.count).bigEndian
        var out = Data(capacity: 4 + body.count)
        withUnsafeBytes(of: &prefix) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    public static func decode(_ data: Data) throws -> CompanionMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CompanionMessage.self, from: data)
    }
}

/// Accumulates bytes from an `NWConnection` receive callback and pops
/// complete frames as they arrive. Not thread-safe — confine to one actor.
public final class CompanionFrameBuffer {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete frame body (JSON bytes only — length prefix
    /// already stripped) or nil if not enough bytes have arrived. Throws on
    /// oversized frames so a corrupt prefix tears the connection down rather
    /// than buffering forever.
    public func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).withUnsafeBytes { raw -> UInt32 in
            raw.load(as: UInt32.self).bigEndian
        }
        if Int(length) > CompanionWire.maxFrameBytes {
            throw CompanionFramingError.oversizedFrame(Int(length))
        }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let body = buffer.subdata(in: 4 ..< 4 + Int(length))
        buffer.removeSubrange(0 ..< 4 + Int(length))
        return body
    }
}

public enum CompanionFramingError: Error {
    case oversizedFrame(Int)
}
