import ArgumentParser

@main
struct Atrium: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "atrium",
        abstract: "Operate Atrium sessions on a paired Mac through its relay.",
        discussion: """
        Every command prints one JSON document to standard output, or JSON lines \
        for streams, and exits non-zero with {"error": {...}} on failure. \
        Reading a session never marks it read or changes where the Mac sends alerts.

        Exit codes: 0 ok, 1 failed or rejected by the host, 3 not paired or revoked, \
        4 host unreachable (nothing was sent), 5 outcome unknown (repeat with the \
        same --id), 6 timed out waiting, 64 invalid usage.
        """,
        version: atriumVersion,
        subcommands: [
            Pair.self, Hosts.self, Forget.self, Status.self,
            Projects.self, Sessions.self, Show.self, Read.self, Follow.self, Models.self,
            Start.self, Send.self, Interrupt.self, Respond.self,
            Rename.self, Settle.self, Restore.self, Snooze.self, Unsnooze.self,
            MarkRead.self, MarkUnread.self, Configure.self, Fork.self, Delete.self,
        ]
    )
}
