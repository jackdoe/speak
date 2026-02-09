import Foundation
import os

final class RingBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func append(_ newSamples: [Float]) {
        os_unfair_lock_lock(lock)
        samples.append(contentsOf: newSamples)
        os_unfair_lock_unlock(lock)
    }

    func drain() -> [Float] {
        os_unfair_lock_lock(lock)
        let result = samples
        samples.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(lock)
        return result
    }

    var duration: Double {
        os_unfair_lock_lock(lock)
        let count = samples.count
        os_unfair_lock_unlock(lock)
        return Double(count) / 16000.0
    }

    var count: Int {
        os_unfair_lock_lock(lock)
        let c = samples.count
        os_unfair_lock_unlock(lock)
        return c
    }
}
