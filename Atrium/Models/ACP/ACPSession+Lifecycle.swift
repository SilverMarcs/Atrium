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

            let configOptions = try await applySessionConfig(
                client: newClient,
                sessionId: resolvedId,
                initialOptions: response.configOptions
            )
            publishSessionConfiguration(configOptions)

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

        let configOptions = try await applySessionConfig(
            client: client,
            sessionId: session.sessionId,
            initialOptions: session.configOptions
        )
        publishSessionConfiguration(configOptions)

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

    private func applySessionConfig(
        client: Client,
        sessionId: SessionId,
        initialOptions: [SessionConfigOption]?
    ) async throws -> [SessionConfigOption]? {
        var latestOptions: [SessionConfigOption]?
        do {
            latestOptions = try await applyPermissionConfiguration(
                permissionMode,
                client: client,
                sessionId: sessionId
            )
        } catch {
            guard provider != .codex else { throw error }
        }

        let availableOptions = latestOptions ?? initialOptions
        guard let modelOption = availableOptions?.first(where: {
            $0.id.value == CodexSessionConfiguration.modelConfigId
        }), case .select(let select) = modelOption.kind else {
            if !model.isEmpty {
                do {
                    let response = try await client.setConfigOption(
                        sessionId: sessionId,
                        configId: SessionConfigId(CodexSessionConfiguration.modelConfigId),
                        value: SessionConfigValueId(model)
                    )
                    latestOptions = response.configOptions
                } catch {
                    guard provider != .codex else { throw error }
                }
            }
            return latestOptions ?? initialOptions
        }

        let selectableOptions: [SessionConfigSelectOption]
        switch select.options {
        case .ungrouped(let options):
            selectableOptions = options
        case .grouped(let groups):
            selectableOptions = groups.flatMap(\.options)
        }
        let availableValues = selectableOptions.map(\.value.value)
        let selectedModel = CodexSessionConfiguration.compatibleModelSelection(
            model,
            availableValues: availableValues
        ) ?? select.currentValue.value
        model = selectedModel

        if selectedModel != select.currentValue.value {
            let response = try await client.setConfigOption(
                sessionId: sessionId,
                configId: SessionConfigId(CodexSessionConfiguration.modelConfigId),
                value: SessionConfigValueId(selectedModel)
            )
            latestOptions = response.configOptions
        }

        return latestOptions ?? initialOptions
    }

    func applyPermissionConfiguration(
        _ mode: PermissionMode,
        client: Client,
        sessionId: SessionId
    ) async throws -> [SessionConfigOption] {
        let modeResponse = try await client.setConfigOption(
            sessionId: sessionId,
            configId: SessionConfigId(CodexSessionConfiguration.modeConfigId),
            value: SessionConfigValueId(mode.configValue(for: provider))
        )

        guard provider == .codex else {
            return modeResponse.configOptions
        }

        let collaborationResponse = try await client.setConfigOption(
            sessionId: sessionId,
            configId: SessionConfigId(CodexSessionConfiguration.collaborationModeConfigId),
            value: SessionConfigValueId(mode.codexCollaborationConfigValue)
        )
        return collaborationResponse.configOptions
    }

    func publishSessionConfiguration(_ options: [SessionConfigOption]?) {
        guard let options else { return }
        onSessionUpdate?(.configOptionUpdate(options))
    }
}
