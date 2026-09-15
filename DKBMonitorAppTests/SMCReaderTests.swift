import Foundation
import Testing
@testable import DKB_Monitor

@Suite struct SMCReaderTests {
    /// `SMCParamStruct` mirrors a C layout the kernel's `AppleSMC` method
    /// reads field by field, and Swift guarantees nothing about how it lays
    /// a struct out. A mismatch wouldn't fail the IOKit call — it would just
    /// read the wrong offsets and report believable nonsense temperatures.
    ///
    /// This pins the size the reader checks at runtime, so a compiler that
    /// ever changes the layout fails here rather than in the temperature
    /// display of a shipped build.
    @Test func paramStructMatchesTheLayoutTheKernelExpects() {
        #expect(MemoryLayout<SMCReader.SMCParamStruct>.stride == SMCReader.expectedParamStructSize)
        #expect(SMCReader.expectedParamStructSize == 80)
    }
}
