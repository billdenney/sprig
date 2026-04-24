@testable import RepoState
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(RepoState.moduleName == "RepoState")
}
