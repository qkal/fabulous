import FabCore
import Testing

@Suite struct TaskTimeoutTests {
    @Test func fastTaskReturnsValue() async {
        let task = Task { 42 }
        let value = await TaskTimeout.value(of: task, within: .seconds(1))
        #expect(value == 42)
    }

    @Test func slowTaskTimesOutToNil() async {
        let task = Task<Int, Never> {
            try? await Task.sleep(for: .seconds(5))
            return 42
        }
        let value = await TaskTimeout.value(of: task, within: .milliseconds(20))
        #expect(value == nil)
        task.cancel()
    }
}
