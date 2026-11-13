/// Whether the timeline stays at its newest message as content grows below
/// it: a reply streaming, the working indicator appearing, or a prompt being
/// sent. Only the reader scrolling away unpins it.
///
/// It's a plain class rather than view state, so scrolling never re-renders
/// the timeline's rows.
final class TimelinePin {
    var isPinned = true
    /// The reader's finger is down, or the scroll they started is still
    /// coasting. Content growing meanwhile mustn't scroll under them.
    var isReaderScrolling = false
    /// The end is within a screen of what the reader sees, close enough that
    /// opening the composer takes the timeline there.
    var isNearEnd = true
    /// How many more times the timeline moving is a jump to the end landing,
    /// to check against its last row.
    var endChecks = 0
    #if os(iOS)
    /// A programmatic scroll is on its way, through offsets it doesn't rest at.
    var isAnimatingScroll = false
    /// Where the timeline was last laid out against the offsets it can rest at.
    var restingPlace = TimelineRestingRange.Place.within
    #endif
}
