@testable import IPCSchema
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(IPCSchema.moduleName == "IPCSchema")
}
