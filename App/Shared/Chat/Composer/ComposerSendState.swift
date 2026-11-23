/// Shared by the resting and expanded action buttons so their handoff agrees.
enum ComposerSendState {
    case send, sending, stop

    init(isBusy: Bool, offersStop: Bool) {
        self = isBusy ? .sending : offersStop ? .stop : .send
    }
}
