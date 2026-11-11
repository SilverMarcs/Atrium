import Foundation

nonisolated extension [PairedHost] {
    /// Adds a host, or updates it in place keeping the name chosen for it.
    func adding(_ host: PairedHost) -> [PairedHost] {
        var host = host
        var hosts = self
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            host.customName = host.customName ?? hosts[index].customName
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        return hosts
    }

    func renaming(_ host: PairedHost, to name: String?) -> [PairedHost] {
        map { saved in
            guard saved.id == host.id else { return saved }
            var renamed = saved
            renamed.customName = name
            return renamed
        }
    }
}
