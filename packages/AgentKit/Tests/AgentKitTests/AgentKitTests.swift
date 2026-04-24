@testable import AgentKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(AgentKit.moduleName == "AgentKit")
}
