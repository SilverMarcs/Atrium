import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .padding(.top, 24)

                VStack(spacing: 4) {
                    Text("Welcome to Atrium")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("One place for your Claude Code and Codex chats.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(
                    icon: "sparkles",
                    title: "Your Agents, Ready",
                    description: "Atrium finds Claude Code and Codex on this Mac by itself. Every chat, even ones started in the terminal, shows up in the sidebar."
                )
                FeatureRow(
                    icon: "folder.badge.plus",
                    title: "Start in a Project",
                    description: "Add a project folder, then start a chat in it. Pick the agent and model for each chat, or start it in a new worktree."
                )
                FeatureRow(
                    icon: "sidebar.right",
                    title: "See What Changed",
                    description: "View the project’s files, Git changes, search and commands right beside the chat."
                )
                FeatureRow(
                    icon: "iphone",
                    title: "Take It With You",
                    description: "Pair your iPhone or iPad in Settings to follow chats, answer questions and get alerts when an agent needs you."
                )
            }
            .padding(.horizontal, 36)

            Spacer(minLength: 28)

            Button {
                dismiss()
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.medium)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 36)
            .padding(.bottom, 30)
        }
        .frame(width: 480)
        .frame(minHeight: 560)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    OnboardingView()
}
