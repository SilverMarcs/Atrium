import Foundation

extension HostServer {
    func handlePreview(_ request: LivePreviewRequest, from connection: ServerConnection) async -> HostReply {
        guard connection.device?.kind == .app else { return .hostOnly }
        switch request {
        case .sources(let taskID):
            return .previewSources(LivePreviewSource.allCases.filter { previewSource($0, taskID: taskID) != nil })
        case .start(let id, let taskID, let source):
            // The companion requests video while visible. Its independent
            // activity update can still describe the previous scene phase.
            guard let target = previewSource(source, taskID: taskID) else {
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
        case .stop(let id):
            if connection.livePreview?.id == id { connection.livePreview = nil }
            return .done
        }
    }

    private func previewSource(_ source: LivePreviewSource, taskID: String) -> PreviewCapture.Source? {
        switch source {
        case .browser:
            return browsers.browser(for: taskID).map(PreviewCapture.Source.browser)
        case .simulator:
            guard let session = simulators.session(for: taskID), session.isBooted else { return nil }
            return .simulator(session)
        }
    }
}
