import Foundation

extension HostServer {
    func handlePreview(_ request: LivePreviewRequest, from connection: ServerConnection) async -> HostReply {
        guard connection.device?.kind == .app else { return .hostOnly }
        switch request {
        case .sources(let taskID):
            return .previewSources(LivePreviewSource.allCases.filter { previewSource($0, taskID: taskID) != nil })
        case .simulators(let taskID):
            guard hasPreviewTask(taskID) else { return .failed(message: "This task isn’t available on the Mac.") }
            await simulators.refreshDevices()
            let running = simulators.devices.filter { $0.state == .booted }.map {
                LivePreviewSimulator(id: $0.udid, name: $0.name, runtime: $0.runtime, symbol: $0.family.symbol)
            }
            return .previewSimulators(running, selectedID: simulators.shown[taskID])
        case .start(let id, let taskID, let source, let openBrowser, let simulatorID):
            // The companion requests video while visible. Its independent
            // activity update can still describe the previous scene phase.
            guard let target = previewSource(source, taskID: taskID, openBrowser: openBrowser == true, simulatorID: simulatorID) else {
                return .failed(message: "The \(source.title.lowercased()) isn’t available on the Mac.")
            }
            let preview = HostLivePreview(id: id)
            connection.livePreview = preview
            do {
                return try await preview.offer(for: target, useRelay: connection.isRelayed) { [weak self] in
                    switch target {
                    case .browser(let browser):
                        self?.browsers.browser(for: taskID) === browser
                    case .simulator(let session):
                        self?.simulators.shown[taskID] == session.udid && session.isBooted
                    }
                }
            } catch {
                if connection.livePreview === preview { connection.livePreview = nil }
                return .failed(message: error.localizedDescription)
            }
        case .answer(let id, let sdp):
            guard let preview = connection.livePreview, preview.id == id else {
                return .failed(message: "This preview has ended.")
            }
            do {
                try await preview.answer(sdp)
                return .done
            } catch {
                if connection.livePreview === preview { connection.livePreview = nil }
                return .failed(message: error.localizedDescription)
            }
        case .input(let id, let input):
            guard let preview = connection.livePreview, preview.id == id else {
                return .failed(message: "This preview has ended.")
            }
            do {
                try await preview.control(input)
                return .done
            } catch {
                return .failed(message: error.localizedDescription)
            }
        case .stop(let id):
            if connection.livePreview?.id == id { connection.livePreview = nil }
            return .done
        }
    }

    private func previewSource(
        _ source: LivePreviewSource, taskID: String, openBrowser: Bool = false, simulatorID: String? = nil
    ) -> PreviewCapture.Source? {
        switch source {
        case .browser:
            if let browser = browsers.browser(for: taskID) { return .browser(browser) }
            guard openBrowser, hasPreviewTask(taskID) else { return nil }
            let browser = browsers.browserOpening(for: taskID)
            browser.startNavigation(.open(URL(string: "about:blank")!))
            return .browser(browser)
        case .simulator:
            if let simulatorID, simulatorID != simulators.shown[taskID] {
                guard hasPreviewTask(taskID), simulators.session(udid: simulatorID)?.isBooted == true,
                      let session = simulators.show(simulatorID, in: taskID) else { return nil }
                return .simulator(session)
            }
            guard let session = simulators.session(for: taskID), session.isBooted else { return nil }
            return .simulator(session)
        }
    }
}
