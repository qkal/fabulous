import Foundation

/// Bounded await on a task that must not delay its caller: nil on
/// timeout. On timeout the task is cancelled; nil is returned once it
/// winds down (bounded by the task's own cancellation responsiveness) —
/// `withTaskGroup` implicitly awaits every child at scope exit, so without
/// this the group's drain of `task.value` would block until the task
/// completes on its own, defeating the timeout.
public enum TaskTimeout {
    public static func value<T: Sendable>(
        of task: Task<T, Never>,
        within limit: Duration
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: limit)
                // Only cancel if we fired the timeout, not if we were cancelled
                // because the value task already won.
                guard !Task.isCancelled else { return nil }
                task.cancel()   // bounded drain: the awaiting child returns as soon as the cancelled task finishes
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
