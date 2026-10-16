import Foundation
import Testing

@testable import ChessClient

@Test func qualityFollowsHeatAndLowPowerMode() {
    #expect(RenderQuality(thermalState: .nominal, isLowPowerMode: false) == .full)
    #expect(RenderQuality(thermalState: .fair, isLowPowerMode: false) == .full)
    #expect(RenderQuality(thermalState: .fair, isLowPowerMode: true) == .reduced)
    #expect(RenderQuality(thermalState: .serious, isLowPowerMode: false) == .reduced)
    #expect(RenderQuality(thermalState: .critical, isLowPowerMode: false) == .minimal)
    #expect(RenderQuality(thermalState: .critical, isLowPowerMode: true) == .minimal, "heat outranks Low Power Mode")
}

@Test func lowerQualityNeverDrawsMore() {
    for preferred in [8, 48] {
        let segments = RenderQuality.allCases.map { $0.pieceSegments(preferred: preferred) }
        #expect(segments == segments.sorted(by: >), "\(preferred): \(segments)")
    }
    #expect(RenderQuality.reduced.pieceSegments(preferred: 8) == 8, "faceted pieces stay faceted")
    #expect(RenderQuality.full.hasShadows && !RenderQuality.reduced.hasShadows)
    #expect(RenderQuality.reduced.hasClearCoat && !RenderQuality.minimal.hasClearCoat)
}
