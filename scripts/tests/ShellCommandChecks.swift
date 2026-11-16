import Foundation

/// What agents' shell commands are taken to have opened and worked in, from
/// commands shaped like ones agents ran.
@main
struct ShellCommandChecks {
    struct Failure: Error { let message: String }

    static func main() {
        do {
            try opensOnlyWhatACreateCommandPrinted()
            try followsDirectoriesIntoWorkedRepositories()
            print("Shell command checks passed")
        } catch let failure as Failure {
            print("FAIL: \(failure.message)")
            exit(1)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func opensOnlyWhatACreateCommandPrinted() throws {
        let two = AgentShellCommand("""
            cd /w/chat/api && CS=$(gh pr create --draft --title "Dates" --body "$(cat <<'EOF'
            Mentions gh pr list and https://github.com/o/api/pull/7
            EOF
            )") && FE=$(cd ../web && gh pr create --title "Dates") && echo "$CS" && echo "$FE"
            """, directory: "/w")
        try check(two.openedPullRequests(output: "https://github.com/o/api/pull/94\nhttps://github.com/o/web/pull/1650\n")
            == urls("https://github.com/o/api/pull/94", "https://github.com/o/web/pull/1650"), "two pull requests one command opened")

        let pushed = AgentShellCommand(
            "git push -u origin fix 2>&1 | tail -2 && gh pr create --base develop --title 'Fix'", directory: "/w/hermes")
        try check(pushed.openedPullRequests(output: "remote:   https://github.com/o/hermes/pull/new/fix\nhttps://github.com/o/hermes/pull/95\n")
            == urls("https://github.com/o/hermes/pull/95"), "the pull request beside a push's hint")

        let search = AgentShellCommand(#"grep -rh 'gh pr create' ~/.claude/projects | grep -o 'https://[^"]*'"#, directory: "/w")
        try check(search.openedPullRequests(output: "https://github.com/o/web/pull/1650\n").isEmpty, "a search for create commands")

        let message = AgentShellCommand("git commit -m 'Note; gh pr create next' && gh pr view --json url -q .url", directory: "/w")
        try check(message.openedPullRequests(output: "https://github.com/o/web/pull/11\n").isEmpty, "a create command in a commit message")

        let body = AgentShellCommand("""
            gh pr create --title Fix --body-file - <<'EOF'
            Follows up on it; gh pr list shows the rest
            EOF
            """, directory: "/w")
        try check(body.openedPullRequests(output: "https://github.com/o/web/pull/14\n") == urls("https://github.com/o/web/pull/14"),
                  "a pull request whose body names other commands")

        let echoed = AgentShellCommand(#"echo "gh pr create" && gh pr view 12 --json url -q .url"#, directory: "/w")
        try check(echoed.openedPullRequests(output: "https://github.com/o/web/pull/12\n").isEmpty, "a create command quoted as text")

        let viewed = AgentShellCommand("gh pr create --fill || gh pr view 12 --json url -q .url", directory: "/w")
        try check(viewed.openedPullRequests(output: "https://github.com/o/web/pull/12\n").isEmpty, "a pull request the command names")

        let listed = AgentShellCommand("gh pr create --fill; gh pr list", directory: "/w")
        try check(listed.openedPullRequests(output: "https://github.com/o/web/pull/9\n").isEmpty, "output beside a listing")

        let printed = AgentShellCommand("gh pr create --fill && cat links.txt", directory: "/w")
        try check(printed.openedPullRequests(output: "https://github.com/o/web/pull/13\nhttps://github.com/o/web/pull/9\n").isEmpty,
                  "more pull requests than the command opened")
    }

    static func followsDirectoriesIntoWorkedRepositories() throws {
        let command = AgentShellCommand("""
            cd worktrees/chat/api && git add -A && git commit -m 'Dates' && (cd ../web && git push) && git -C /w/hermes push
            for r in api web; do cd $r && git push; done
            """, directory: "/w")
        try check(command.repositoryFolders == ["/w/worktrees/chat/api", "/w/worktrees/chat/web", "/w/hermes"],
                  "folders committed and pushed in: \(command.repositoryFolders)")

        let reading = AgentShellCommand("cd /w/api && (cd /w/web && git log -5) && git push", directory: "/w")
        try check(reading.repositoryFolders == ["/w/api"], "a push after a subshell's cd: \(reading.repositoryFolders)")
    }

    static func urls(_ strings: String...) -> [URL] { strings.compactMap(URL.init(string:)) }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
}
