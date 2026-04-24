@testable import TaskWindowKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(TaskWindowKit.moduleName == "TaskWindowKit")
}
