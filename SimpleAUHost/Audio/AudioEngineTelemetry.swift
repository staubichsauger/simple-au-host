import Foundation

struct LatencyClassTelemetrySnapshot {
    let trackCount: Int
    let workerShardCount: Int
    let peakTrackRenderDurationMicros: UInt64
    let averageTrackRenderDurationMicros: UInt64
    let peakShardRenderDurationMicros: UInt64
    let averageShardRenderDurationMicros: UInt64
    let peakShardUtilizationPercent: UInt64
    let peakWorkerWakeupsPerSecond: UInt64

    static let zero = LatencyClassTelemetrySnapshot(
        trackCount: 0,
        workerShardCount: 0,
        peakTrackRenderDurationMicros: 0,
        averageTrackRenderDurationMicros: 0,
        peakShardRenderDurationMicros: 0,
        averageShardRenderDurationMicros: 0,
        peakShardUtilizationPercent: 0,
        peakWorkerWakeupsPerSecond: 0
    )
}

struct AudioEngineTelemetrySnapshot {
    let peakInputCallbackFrames: UInt64
    let peakOutputCallbackFrames: UInt64
    let peakEffectRenderFrames: UInt64
    let peakInputRingOccupancyFrames: UInt64
    let peakOutputRingOccupancyFrames: UInt64
    let inputRingCapacityFrames: Int
    let outputRingCapacityFrames: Int
    let peakTrackRenderDurationMicros: UInt64
    let averageTrackRenderDurationMicros: UInt64
    let peakShardRenderDurationMicros: UInt64
    let averageShardRenderDurationMicros: UInt64
    let peakShardUtilizationPercent: UInt64
    let peakWorkerWakeupsPerSecond: UInt64
    let workerShardCount: Int
    let realtime: LatencyClassTelemetrySnapshot
    let buffered: LatencyClassTelemetrySnapshot
    let broadcast: LatencyClassTelemetrySnapshot

    static let zero = AudioEngineTelemetrySnapshot(
        peakInputCallbackFrames: 0,
        peakOutputCallbackFrames: 0,
        peakEffectRenderFrames: 0,
        peakInputRingOccupancyFrames: 0,
        peakOutputRingOccupancyFrames: 0,
        inputRingCapacityFrames: 0,
        outputRingCapacityFrames: 0,
        peakTrackRenderDurationMicros: 0,
        averageTrackRenderDurationMicros: 0,
        peakShardRenderDurationMicros: 0,
        averageShardRenderDurationMicros: 0,
        peakShardUtilizationPercent: 0,
        peakWorkerWakeupsPerSecond: 0,
        workerShardCount: 0,
        realtime: .zero,
        buffered: .zero,
        broadcast: .zero
    )
}

struct TrackPluginLatencySnapshot: Hashable {
    let trackID: UUID
    let pluginLatencyFrames: Int
}
