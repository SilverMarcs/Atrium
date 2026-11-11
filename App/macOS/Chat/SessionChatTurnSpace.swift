import SwiftUI

/// Keeps room below the latest turn on the Mac, so its prompt can be held at
/// the top of the timeline while the reply fills in under it, as on iPhone.
///
/// The turn's rows stay in the timeline's one lazy stack, rather than moving
/// into a container of their own each time a prompt starts a turn, which
/// would rebuild every row of the previous turn mid-send. Instead a filler
/// after the turn makes up whatever the turn lacks of the viewport's height.
/// Until the turn is measured, the filler is a whole viewport tall: there's
/// room to hold the prompt at once, and measuring only takes from the end.
@MainActor
@Observable
final class TurnFill {
  static let coordinateSpace = "timeline"

  /// The top of the row holding the latest turn's prompt, in the timeline's space.
  private(set) var turnTop: CGFloat?
  /// Where the turn's rows, indicator and error end, in the timeline's space.
  private(set) var turnEnd: CGFloat?

  /// How tall the filler is, given how tall the turn must be.
  func height(minimum: CGFloat) -> CGFloat {
    guard let turnTop, let turnEnd else { return max(0, minimum) }
    return max(0, minimum - (turnEnd - turnTop))
  }

  var turnHeight: CGFloat? {
    guard let turnTop, let turnEnd else { return nil }
    return turnEnd - turnTop
  }

  func noteTurnTop(_ top: CGFloat) {
    if turnTop != top { turnTop = top }
  }

  func noteTurnEnd(_ end: CGFloat) {
    if turnEnd != end { turnEnd = end }
  }

  /// A new prompt starts a turn the filler hasn't measured.
  func reset() {
    turnTop = nil
  }
}

/// Reports the top of the row that starts the latest turn.
struct TurnTopReporter: View {
  let fill: TurnFill

  var body: some View {
    Color.clear
      .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TurnFill.coordinateSpace)).minY } action: { top in
        fill.noteTurnTop(top)
      }
  }
}

/// The blank space after the latest turn, which its reply grows into.
struct TurnFiller: View {
  let fill: TurnFill
  let anchorSpace: TimelineAnchorSpace
  let isHolding: Bool
  /// Space the timeline keeps below its content, which counts towards the turn.
  let bottomGap: CGFloat

  var body: some View {
    Color.clear
      .frame(height: isHolding ? fill.height(minimum: anchorSpace.turnMinimumHeight - bottomGap) : 0)
      .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TurnFill.coordinateSpace)).minY } action: { end in
        fill.noteTurnEnd(end)
        if let height = fill.turnHeight { anchorSpace.setTurnHeight(height + bottomGap) }
      }
      .accessibilityHidden(true)
  }
}
