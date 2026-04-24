@testable import PlatformKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(PlatformKit.moduleName == "PlatformKit")
}
