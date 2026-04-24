import Testing
@testable import RepoState

@Test func moduleNameIsSet() {
    #expect(RepoState.moduleName == "RepoState")
}
