@testable import SubmoduleKit
import Testing

@Test func `module name is set`() {
    #expect(SubmoduleKit.moduleName == "SubmoduleKit")
}
