import Foundation

class RingBuffer {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ newSamples: [Float]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        let result = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }

    var duration: Double {
        lock.lock()
        let count = samples.count
        lock.unlock()
        return Double(count) / 16000.0
    }

    var count: Int {
        lock.lock()
        let c = samples.count
        lock.unlock()
        return c
    }
}
