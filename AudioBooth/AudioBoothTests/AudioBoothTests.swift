import Testing
@testable import AudioBooth

@Suite("AudioBooth Baseline Tests")
struct AudioBoothTests {
  @Test("Module can be imported and verified")
  func testModuleImport() async throws {
    #expect(true)
  }
}
