import Testing
@testable import MonitorCore

@Suite struct BuildInfoTests {
    @Test func productNameIsRtop() {
        #expect(BuildInfo.productName == "rtop")
        #expect(!BuildInfo.version.isEmpty)
    }
}
