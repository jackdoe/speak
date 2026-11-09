import Foundation

final class Ring: @unchecked Sendable {
    private static let capacity = Recognizer.rate * 600

    private let condition = NSCondition()
    private var samples = [Float](repeating: 0, count: capacity)
    private var written = 0

    var now: Int {
        condition.withLock { written }
    }

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        condition.withLock {
            for sample in chunk {
                samples[written % Self.capacity] = sample
                written += 1
            }
            condition.broadcast()
        }
    }

    func slice(from start: Int, to end: Int, waitingUntil deadline: Date) -> [Float] {
        condition.withLock {
            while written < end, condition.wait(until: deadline) {}
            let end = min(end, written)
            let start = min(max(start, written - Self.capacity, 0), end)
            return (start ..< end).map { samples[$0 % Self.capacity] }
        }
    }
}
