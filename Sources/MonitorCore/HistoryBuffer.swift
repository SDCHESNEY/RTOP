/// One history entry. An unavailable sample is kept explicitly so a gap shows
/// as a gap, not as zero.
public struct HistorySample<Value: Sendable & Equatable>: Sendable, Equatable {
    public var atNanoseconds: UInt64
    public var value: Availability<Value>

    public init(atNanoseconds: UInt64, value: Availability<Value>) {
        self.atNanoseconds = atNanoseconds
        self.value = value
    }
}

/// Fixed-capacity ring buffer; the oldest sample is overwritten when full.
public struct HistoryBuffer<Value: Sendable & Equatable>: Sendable, Equatable {
    public static var maximumCapacity: Int { 3600 }

    public let capacity: Int
    private var storage: [HistorySample<Value>] = []
    /// Index of the oldest sample once the buffer is full.
    private var head = 0

    /// Capacity is clamped to 1...3600.
    public init(capacity: Int = 60) {
        self.capacity = min(max(capacity, 1), Self.maximumCapacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }

    public mutating func append(_ sample: HistorySample<Value>) {
        if storage.count < capacity {
            storage.append(sample)
        } else {
            storage[head] = sample
            head = (head + 1) % capacity
        }
    }

    public mutating func append(_ value: Availability<Value>, atNanoseconds: UInt64) {
        append(HistorySample(atNanoseconds: atNanoseconds, value: value))
    }

    /// Samples oldest to newest.
    public var samples: [HistorySample<Value>] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    /// The newest `limit` samples, oldest first.
    public func recent(_ limit: Int) -> [HistorySample<Value>] {
        Array(samples.suffix(max(0, limit)))
    }
}
