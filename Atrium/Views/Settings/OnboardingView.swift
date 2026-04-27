import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .padding(.top, 32)

                VStack(spacing: 4) {
                    Text("Welcome to Atrium")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("A native macOS terminal built for vibe coding.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(
                    icon: "sparkles",
                    title: "Made for Vibe Coding",
                    description: "Stay in flow while your AI agent works. Review diffs, browse files, and run commands side-by-side without leaving the terminal."
                )
                FeatureRow(
                    icon: "folder.badge.plus",
                    title: "Project Workspaces",
                    description: "Add a workspace for each project directory and jump back into context instantly."
                )
                FeatureRow(
                    icon: "sidebar.right",
                    title: "Built-in Inspector",
                    description: "Browse files, view Git changes, search your project, and revisit past commands without leaving the app."
                )
                FeatureRow(
                    icon: "square.and.pencil",
                    title: "Edit Files Inline",
                    description: "Tap a file to open it in the editor with syntax highlighting."
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
