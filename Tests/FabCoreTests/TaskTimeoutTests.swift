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
        let clock = ContinuousClock()
        let start = clock.now
        let value = await TaskTimeout.value(of: task, within: .milliseconds(20))
        let elapsed = clock.now - start
        #expect(value == nil)
        #expect(elapsed < .seconds(1))
    }

    @Test func fastTaskReturnsValueQuickly() async {
        let task = Task<Int, Never> { 42 }
        let clock = ContinuousClock()
        let start = clock.now
        let value = await TaskTimeout.value(of: task, within: .seconds(1))
        let elapsed = clock.now - start
        #expect(value == 42)
        #expect(elapsed < .seconds(1))
    }
}
