import AtriumProtocol
import CryptoKit
import Foundation

/// The bearer token ChatGPT's requests carry. It lives only in the header file
/// the tunnel client sends with each request, which only Atrium's user can
/// read, so it survives relaunches without being kept anywhere else.
@MainActor
final class ChatGPTCredential {
    /// What the tunnel client sends as ChatGPT's `Authorization` header.
    let headerFile: URL
    /// The SHA-256 of the header, so checks never compare the secret directly.
    private var digest: Data?

    init(directory: URL) {
        headerFile = directory.appending(path: "chatgpt-authorization")
        digest = (try? String(contentsOf: headerFile, encoding: .utf8)).map(Self.digest)
    }

    var exists: Bool { digest != nil }

    func accepts(_ authorization: String?) -> Bool {
        guard let authorization, let digest else { return false }
        return Self.digest(authorization) == digest
    }

    /// Issues a new token, replacing any earlier one, and writes its header.
    func issue() throws {
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URLEncodedString()
        let header = "Bearer " + token
        try FileManager.default.createDirectory(at: headerFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(header.utf8).write(to: headerFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: headerFile.path(percentEncoded: false))
        digest = Self.digest(header)
    }

    /// Shuts ChatGPT out: its token stops working and the header file goes.
    func revoke() {
        digest = nil
        try? FileManager.default.removeItem(at: headerFile)
    }

    private static func digest(_ header: String) -> Data {
        Data(SHA256.hash(data: Data(header.utf8)))
    }
}
