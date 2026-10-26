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
}
