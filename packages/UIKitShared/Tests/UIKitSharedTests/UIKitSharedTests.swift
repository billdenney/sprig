import Testing
@testable import UIKitShared

@Test("module name is set")

func moduleNameIsSet() {
    #expect(UIKitShared.moduleName == "UIKitShared")
}
