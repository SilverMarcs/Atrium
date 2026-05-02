import Foundation
import ACP
import ACPModel

extension ACPSession {
    func launchAndCreateSession() async {
        isConnecting = true
        error = nil

        do {
            let newClient = try await launchAndInitialize()
            try await createNewSession(client: newClient)
        } catch {
            isConnecting = false
            self.error = error.localizedDescription
        }
    }

    func relaunchAndLoadSession(_ sessionId: SessionId) async {
        notificationTask?.cancel()
        notificationTask = nil
        let oldClient = client
        setClient(nil)
        setSessionId(nil)
        isConnected = false
        isConnecting = true
        error = nil

        if let oldClient {
            await oldClient.terminate()
            try? await Task.sleep(for: .milliseconds(500))
        }

        do {
            isReplaying = true
            let newClient = try await launchAndInitialize()
            listenForNotifications(client: newClient)

            let response = try await newClient.loadSession(
                sessionId: sessionId,
                cwd: workingDirectory,
                mcpServers: []
            )
            let resolvedId = response.sessionId ?? sessionId
            setSessionId(resolvedId)

            try? await applySessionConfig(client: newClient, sessionId: resolvedId)

            // Let queued replay notifications drain before re-opening the
            // update handler.
            try? await Task.sleep(for: .seconds(1))
            isReplaying = false

            isConnected = true
            isConnecting = false
            onConnected?()
        } catch {
            // Session no longer exists on the agent side (e.g. process was
            // killed, disk state cleared). Fall back to a fresh session so the
            // user isn't left stuck.
            isReplaying = false
            do {
                let fallbackClient: Client
                if let existing = client {
                    fallbackClient = existing
                } else {
                    fallbackClient = try await launchAndInitialize()
                }
                try await createNewSession(client: fallbackClient)
            } catch {
                isConnecting = false
                self.error = error.localizedDescription
            }
        }
    }

    func launchAndInitialize() async throws -> Client {
        let newClient = Client()
        await newClient.setDelegate(delegate)
        setClient(newClient)

        try await newClient.launch(
            agentPath: "/usr/bin/env",
            arguments: provider.acpCommand,
            workingDirectory: workingDirectory
        )

        _ = try await newClient.initialize(
            capabilities: ClientCapabilities(
                fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
                terminal: false
            ),
            clientInfo: ClientInfo(
                name: "Atrium",
                title: "Swift Terminal",
                version: "1.0.0"
            ),
            timeout: 120
        )

        return newClient
    }

    func createNewSession(client: Client) async throws {
        let session = try await client.newSession(
            workingDirectory: workingDirectory,
            timeout: 60
        )
        setSessionId(session.sessionId)

        try? await applySessionConfig(client: client, sessionId: session.sessionId)

        isConnected = true
        isConnecting = false
        listenForNotifications(client: client)
        onConnected?()
    }

    func terminateAndRelaunch() async {
        notificationTask?.cancel()
        notificationTask = nil
        let oldClient = client
        setClient(nil)
        setSessionId(nil)
        isConnected = false

        if let oldClient {
            await oldClient.terminate()
            try? await Task.sleep(for: .milliseconds(500))
        }

        do {
            let newClient = try await launchAndInitialize()
            try await createNewSession(client: newClient)
        } catch {
            isConnecting = false
            self.error = error.localizedDescription
        }
    }

    private func applySessionConfig(client: Client, sessionId: SessionId) async throws {
        _ = try await client.setConfigOption(
            sessionId: sessionId,
            configId: SessionConfigId("mode"),
            value: SessionConfigValueId(permissionMode.configValue(for: provider))
        )
        if !model.isEmpty {
            _ = try await client.setConfigOption(
                sessionId: sessionId,
                configId: SessionConfigId("model"),
                value: SessionConfigValueId(model)
            )
        }
    }
}
