@testable import LauncherKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(LauncherKit.moduleName == "LauncherKit")
}
