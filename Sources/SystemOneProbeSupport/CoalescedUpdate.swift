import Foundation

/// Publishes the latest state on the next main-queue turn, without a refresh-rate timer.
@MainActor
public final class CoalescedUpdate {
    public typealias Scheduler = (@escaping @MainActor () -> Void) -> Void
    public var isPaused = false {
        didSet { if !isPaused { enqueueIfNeeded() } }
    }
    private var dirty = false
    private var queued = false
    private var generation: UInt64 = 0
    private let schedule: Scheduler
    private let publish: @MainActor () -> Void

    public init(schedule: @escaping Scheduler = { action in DispatchQueue.main.async { action() } },
                publish: @escaping @MainActor () -> Void) {
        self.schedule = schedule
        self.publish = publish
    }

    public func request() {
        dirty = true
        enqueueIfNeeded()
    }

    public func cancelPending() {
        generation &+= 1
        queued = false
        dirty = false
    }

    public func flushNow() {
        generation &+= 1
        queued = false
        flush()
    }

    private func enqueueIfNeeded() {
        guard dirty, !queued, !isPaused else { return }
        queued = true
        let token = generation
        schedule { [weak self] in
            guard let self, self.generation == token else { return }
            self.queued = false
            self.flush()
        }
    }

    private func flush() {
        guard dirty, !isPaused else { return }
        dirty = false
        publish()
    }
}
