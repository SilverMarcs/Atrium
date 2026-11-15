/// Rows from a host may include providers this client no longer supports.
/// Skip those rows without discarding the rest of a snapshot or delta.
nonisolated struct ProviderRows<Element: Decodable>: Decodable {
    let values: [Element]

    private enum CodingKeys: CodingKey { case provider }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !container.isAtEnd {
            let entry = try container.superDecoder()
            let row = try entry.container(keyedBy: CodingKeys.self)
            let provider = try row.decode(String.self, forKey: .provider)
            guard AgentProvider(rawValue: provider) != nil else { continue }
            values.append(try Element(from: entry))
        }
        self.values = values
    }
}
