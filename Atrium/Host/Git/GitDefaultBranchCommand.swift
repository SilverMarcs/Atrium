import Foundation

struct GitDefaultBranchCommand: GitCommand {
    var arguments: [String] {
        ["for-each-ref", "--format=%(refname)%00%(symref)", "refs/heads", "refs/remotes"]
    }

    func parse(output: String) throws -> (ref: String, branch: String)? {
        let refs = output.split(separator: "\n").map {
            $0.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        }
        let names = Set(refs.compactMap(\.first))
        let remoteHeads = refs.filter {
            $0.count == 2 && $0[0].hasPrefix("refs/remotes/") && $0[0].hasSuffix("/HEAD")
        }
        let symbolicTargets = remoteHeads.sorted {
            if $0[0] == $1[0] { return false }
            if $0[0] == "refs/remotes/origin/HEAD" { return true }
            if $1[0] == "refs/remotes/origin/HEAD" { return false }
            return $0[0] < $1[0]
        }.map { $0[1] }
        let fallbackTargets = ["refs/remotes/origin/", "refs/heads/"].flatMap { prefix in
            ["main", "master", "develop"].map { prefix + $0 }
        }
        guard let ref = (symbolicTargets + fallbackTargets).first(where: { names.contains($0) }) else {
            return nil
        }
        let branch: String
        if ref.hasPrefix("refs/remotes/") {
            branch = String(ref.dropFirst("refs/remotes/".count).split(separator: "/").dropFirst().joined(separator: "/"))
        } else {
            branch = String(ref.dropFirst("refs/heads/".count))
        }
        return (ref, branch)
    }
}
