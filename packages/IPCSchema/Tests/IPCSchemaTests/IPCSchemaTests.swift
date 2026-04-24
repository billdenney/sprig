import Testing
@testable import IPCSchema

@Test func moduleNameIsSet() {
    #expect(IPCSchema.moduleName == "IPCSchema")
}
