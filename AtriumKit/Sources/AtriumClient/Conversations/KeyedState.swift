import Observation

/// A dictionary that views observe one key at a time. Reading `state[key]`
/// in a view's body makes it depend on that key alone, so a change to another
/// task's transcript doesn't update the chat on screen.
///
/// Iterating keys or values isn't observed; it's for model code.
@MainActor
public final class KeyedState<Value> {
    @Observable
    final class Slot {
        var value: Value?
        init(_ value: Value? = nil) { self.value = value }
    }

    private var slots: [String: Slot] = [:]

    public init() {}

    private func slot(_ key: String) -> Slot {
        if let slot = slots[key] { return slot }
        // Created on first read too, so the reader hears when the key gets a value.
        let slot = Slot()
        slots[key] = slot
        return slot
    }

    public internal(set) subscript(key: String) -> Value? {
        get { slot(key).value }
        set {
            guard let slot = slots[key] else {
                if let newValue { slots[key] = Slot(newValue) }
                return
            }
            // Clearing an empty key isn't a change readers need to hear about.
            guard newValue != nil || slot.value != nil else { return }
            slot.value = newValue
        }
    }

    public internal(set) subscript(key: String, default defaultValue: @autoclosure () -> Value) -> Value {
        get { self[key] ?? defaultValue() }
        set { self[key] = newValue }
    }

    /// Keys that hold a value.
    public var keys: [String] { slots.compactMap { $0.value.value == nil ? nil : $0.key } }

    @discardableResult
    func removeValue(forKey key: String) -> Value? {
        guard let value = slots[key]?.value else { return nil }
        slots[key]?.value = nil
        return value
    }

    func removeAll() {
        for slot in slots.values where slot.value != nil { slot.value = nil }
    }
}
