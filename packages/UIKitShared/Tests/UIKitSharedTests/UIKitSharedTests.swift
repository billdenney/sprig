import Testing
@testable import UIKitShared

@Test func moduleNameIsSet() {
    #expect(UIKitShared.moduleName == "UIKitShared")
}
