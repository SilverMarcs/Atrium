@testable import AtriumClient
import AtriumProtocol
import Foundation
import Testing

struct CredentialStoreTests {
    private let folder = URL.temporaryDirectory.appending(path: "atrium-tests-\(UUID().uuidString)/config", directoryHint: .isDirectory)
    private var url: URL { folder.appending(path: "credentials.json") }
    private let host = PairedHost(link: PairingLink(hostID: "host-1", publicKey: Data(repeating: 1, count: 32), secret: "s", hostName: "Mac"))

    @Test func keepsAnIdentityAndTokensOnlyItsOwnerCanRead() throws {
        let store = try FileCredentialStore(url: url, deviceName: "Dot")
        try store.save(host, token: "token-1")
        let reopened = try FileCredentialStore(url: url, deviceName: "Other")
        #expect(reopened.device == store.device)
        #expect(reopened.device.name == "Dot")
        #expect(reopened.token(for: host) == "token-1")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.path(percentEncoded: false))
        #expect((folderAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func storesSharingAFileDontUndoEachOther() throws {
        let first = try FileCredentialStore(url: url, deviceName: "Dot")
        let second = try FileCredentialStore(url: url, deviceName: "Dot")
        var other = host
        other.hostID = "host-2"
        try first.save(host, token: "a")
        try second.save(other, token: "b")
        second.rename(host, to: "Studio")
        let reopened = try FileCredentialStore(url: url, deviceName: "Dot")
        #expect(reopened.pairedHosts.map(\.id) == ["host-1", "host-2"])
        #expect(reopened.pairedHosts.first?.displayName == "Studio")
        first.forget(other)
        #expect(try FileCredentialStore(url: url, deviceName: "Dot").pairedHosts.map(\.id) == ["host-1"])
    }

    @Test func pairingAgainKeepsTheChosenName() throws {
        let store = try FileCredentialStore(url: url, deviceName: "Dot")
        try store.save(host, token: "a")
        store.rename(host, to: "Studio")
        try store.save(host, token: "b")
        #expect(store.pairedHosts.first?.displayName == "Studio")
        #expect(store.token(for: host) == "b")
    }
}
