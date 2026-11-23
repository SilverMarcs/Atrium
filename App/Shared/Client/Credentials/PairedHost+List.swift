import Foundation

nonisolated extension [PairedHost] {
    /// Adds a host, or replaces it in place.
    func adding(_ host: PairedHost) -> [PairedHost] {
        var hosts = self
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        return hosts
    }

    /// Updates a saved host's advertised metadata in place, leaving unsaved hosts alone.
    func updating(_ host: PairedHost) -> [PairedHost] {
        map { $0.id == host.id ? host : $0 }
    }
}
