import Testing
@testable import PlatformKit

@Test func moduleNameIsSet() {
    #expect(PlatformKit.moduleName == "PlatformKit")
}
