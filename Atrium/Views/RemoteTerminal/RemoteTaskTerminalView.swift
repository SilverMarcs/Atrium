import AtriumClient
import AtriumProtocol
import SwiftUI

struct RemoteTaskTerminalView: View {
    @State private var controller: RemoteTerminalController

    init(host: HostClient, taskID: String) {
        _controller = State(initialValue: RemoteTerminalController(host: host, taskID: taskID))
    }

    var body: some View {
        Group {
            if let error = controller.host.terminalErrors[controller.taskID] {
                ContentUnavailableView {
                    Label("Couldn’t Attach Terminal", systemImage: "terminal")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { controller.host.reload(.terminal(taskID: controller.taskID)) }
                }
            } else if let frame = controller.host.terminals[controller.taskID] {
                RemoteTerminalRepresentable(frame: frame, acceptsInput: controller.host.isConnected && !frame.hasExited, send: controller.send)
                    .safeAreaInset(edge: .bottom) {
                        if !controller.host.isConnected {
                            ProgressView("Reconnecting…")
                                .padding()
                        } else if frame.hasExited {
                            Button("Resume Task", systemImage: "play") { Task { await controller.resume() } }
                                .disabled(controller.isResuming)
                                .padding()
                        }
                    }
            } else {
                ProgressView("Attaching terminal…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await controller.follow() }
    }
}
