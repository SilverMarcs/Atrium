import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// A recording in progress, with its time and a button to finish it.
struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            HStack {
                DictationWaveform()
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text("Dictating")
                        .font(.headline)
                    DictationElapsedTime(attributes: context.attributes)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                FinishDictationButton()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Dictating")
                    } icon: {
                        DictationWaveform()
                    }
                    .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DictationElapsedTime(attributes: context.attributes)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    FinishDictationButton()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } compactLeading: {
                DictationWaveform()
            } compactTrailing: {
                DictationElapsedTime(attributes: context.attributes)
                    .frame(maxWidth: 40)
            } minimal: {
                DictationWaveform()
            }
        }
    }
}

private struct DictationWaveform: View {
    var body: some View {
        Image(systemName: "waveform")
            .foregroundStyle(.red)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers.reversing, options: .repeat(.continuous))
            .accessibilityLabel("Recording")
    }
}

/// Counts up to the recording's limit, where it stops.
private struct DictationElapsedTime: View {
    let attributes: DictationActivityAttributes

    var body: some View {
        Text(timerInterval: attributes.startedAt...attributes.endsBy, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

private struct FinishDictationButton: View {
    var body: some View {
        Button(intent: FinishDictationIntent()) {
            Label("Finish", systemImage: "stop.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }
}
