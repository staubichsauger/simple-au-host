import Foundation

struct EngineTelemetryStrings {
    let telemetrySummary: String
    let ringTelemetrySummary: String
    let workerTelemetrySummary: String
    let realtimeTelemetrySummary: String
    let bufferedTelemetrySummary: String
    let broadcastTelemetrySummary: String
}

enum EngineTelemetryFormatter {
    static func strings(for telemetry: AudioEngineTelemetrySnapshot) -> EngineTelemetryStrings {
        EngineTelemetryStrings(
            telemetrySummary: "Callbacks in/out: \(telemetry.peakInputCallbackFrames) / \(telemetry.peakOutputCallbackFrames) frames",
            ringTelemetrySummary: "Peak ring occupancy in/out: \(occupancyString(telemetry.peakInputRingOccupancyFrames, capacity: telemetry.inputRingCapacityFrames)) / \(occupancyString(telemetry.peakOutputRingOccupancyFrames, capacity: telemetry.outputRingCapacityFrames))",
            workerTelemetrySummary: "Workers: \(telemetry.workerShardCount) shards, track/shard render avg \(telemetry.averageTrackRenderDurationMicros) / \(telemetry.averageShardRenderDurationMicros) us, peak \(telemetry.peakTrackRenderDurationMicros) / \(telemetry.peakShardRenderDurationMicros) us, util \(telemetry.peakShardUtilizationPercent)%, wakeups \(telemetry.peakWorkerWakeupsPerSecond)/s",
            realtimeTelemetrySummary: realtimeString(telemetry.realtime),
            bufferedTelemetrySummary: bufferedString(label: "Buffered", telemetry.buffered),
            broadcastTelemetrySummary: bufferedString(label: "Broadcast", telemetry.broadcast)
        )
    }

    private static func realtimeString(_ telemetry: LatencyClassTelemetrySnapshot) -> String {
        "Realtime: \(telemetry.trackCount) tracks, render avg/peak \(telemetry.averageTrackRenderDurationMicros) / \(telemetry.peakTrackRenderDurationMicros) us"
    }

    private static func bufferedString(
        label: String,
        _ telemetry: LatencyClassTelemetrySnapshot
    ) -> String {
        "\(label): \(telemetry.trackCount) tracks, \(telemetry.workerShardCount) shards, track/shard avg \(telemetry.averageTrackRenderDurationMicros) / \(telemetry.averageShardRenderDurationMicros) us, peak \(telemetry.peakTrackRenderDurationMicros) / \(telemetry.peakShardRenderDurationMicros) us, util \(telemetry.peakShardUtilizationPercent)%, wakeups \(telemetry.peakWorkerWakeupsPerSecond)/s"
    }

    private static func occupancyString(_ frames: UInt64, capacity: Int) -> String {
        guard capacity > 0 else {
            return "\(frames) frames"
        }
        let percent = Double(frames) / Double(capacity) * 100
        return "\(frames) frames (\(Int(percent.rounded()))%)"
    }
}
