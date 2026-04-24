import Testing
@testable import AgentKit

@Test func moduleNameIsSet() {
    #expect(AgentKit.moduleName == "AgentKit")
}
