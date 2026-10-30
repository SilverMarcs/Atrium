import SwiftUI

extension EnvironmentValues {
    /// Pages in the conversation that a later version revised, by block ID.
    @Entry var earlierPageIDs: Set<String> = []
}
