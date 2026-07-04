import Foundation

/// Bounded await on a task that must not delay its caller: nil on
/// timeout. The task itself keeps running — cancelling it (or not) is
/// the caller's decision.
public enum TaskTimeout {
    public static func value<T: Sendable>(
        of task: Task<T, Never>,
        within limit: Duration
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
