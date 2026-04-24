@testable import LFSKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(LFSKit.moduleName == "LFSKit")
}
