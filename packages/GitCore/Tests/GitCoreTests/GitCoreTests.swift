import Testing
@testable import GitCore

@Test func moduleNameIsSet() {
    #expect(GitCore.moduleName == "GitCore")
}
