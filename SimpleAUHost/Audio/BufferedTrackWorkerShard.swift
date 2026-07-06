import AudioToolbox
import Foundation

extension MultiTrackAudioHostController {
    final class BufferedTrackWorkerShard: @unchecked Sendable {
        let id: Int
        let latencyClass: TrackLatencyClass
        let processingFrames: Int

        private let tracks: [TrackRuntime]
        private let inputChannelOffsets: [Int]
        private let channelIndexMap: [Int: Int]
        private let recordDroppedFrames: @Sendable (UInt32) -> Void
        private let signalStagedOutput: @Sendable () -> Void
        private let runtimeStatusMessage: @Sendable () -> String?

        private var inputRings: [FloatRingBuffer]
        private var stagedInputs: [UnsafeMutablePointer<Float>]
        private let stateLock = NSLock()
        private let wakeup = AudioWorkerWakeup()
        private let exitGroup = DispatchGroup()
        private var workerThread: Thread?
        private var shouldRun = false

        private let peakInputRingOccupancyFrames = AtomicCounter()
        private let renderTelemetry = RenderTelemetry()
        private let peakUtilizationPercent = AtomicCounter()
        private let peakWakeupsPerSecond = AtomicCounter()

        init(
            id: Int,
            latencyClass: TrackLatencyClass,
            tracks: [TrackRuntime],
            recordDroppedFrames: @escaping @Sendable (UInt32) -> Void,
            signalStagedOutput: @escaping @Sendable () -> Void,
            runtimeStatusMessage: @escaping @Sendable () -> String?
        ) throws {
            self.id = id
            self.latencyClass = latencyClass
            self.tracks = tracks
            self.recordDroppedFrames = recordDroppedFrames
            self.signalStagedOutput = signalStagedOutput
            self.runtimeStatusMessage = runtimeStatusMessage
            self.processingFrames = tracks.first?.processingFrames ?? 0

            let orderedInputChannels = Set(tracks.flatMap(\.inputChannelOffsets)).sorted()
            self.inputChannelOffsets = orderedInputChannels
            self.channelIndexMap = Dictionary(uniqueKeysWithValues: orderedInputChannels.enumerated().map { ($1, $0) })
            self.inputRings = orderedInputChannels.map { _ in FloatRingBuffer() }
            self.stagedInputs = []

            try prepareBuffers()
        }

        deinit {
            stopWorker()
            for pointer in stagedInputs {
                pointer.deallocate()
            }
        }

        var trackCount: Int {
            tracks.count
        }

        var inputRingCapacityFrames: Int {
            inputRings.reduce(0) { max($0, Int($1.capacity)) }
        }

        func peakInputRingOccupancy() -> UInt64 {
            peakInputRingOccupancyFrames.load()
        }

        func peakRenderDurationMicros() -> UInt64 {
            renderTelemetry.peakDurationMicros()
        }

        func averageRenderDurationMicros() -> UInt64 {
            renderTelemetry.averageDurationMicros()
        }

        func peakUtilization() -> UInt64 {
            peakUtilizationPercent.load()
        }

        func peakWakeups() -> UInt64 {
            peakWakeupsPerSecond.load()
        }

        func resetTelemetry() {
            peakInputRingOccupancyFrames.reset()
            renderTelemetry.reset()
            peakUtilizationPercent.reset()
            peakWakeupsPerSecond.reset()
        }

        func enqueueInput(from captureBufferList: UnsafeMutableAudioBufferListPointer, frameCount: UInt32) {
            guard processingFrames > 0 else { return }
            var droppedFrames: UInt32 = 0
            for (ringIndex, channelOffset) in inputChannelOffsets.enumerated() {
                guard channelOffset < captureBufferList.count,
                      let source = captureBufferList[channelOffset].mData?.assumingMemoryBound(to: Float.self) else {
                    droppedFrames = max(droppedFrames, frameCount)
                    continue
                }
                let writtenFrames = inputRings[ringIndex].write(from: source, count: frameCount)
                peakInputRingOccupancyFrames.storeMax(UInt64(inputRings[ringIndex].availableRead()))
                droppedFrames = max(droppedFrames, frameCount - writtenFrames)
            }
            if droppedFrames > 0 {
                recordDroppedFrames(droppedFrames)
            }
        }

        func signalWorkAvailable() {
            wakeup.signal()
        }

        func startWorker(affinityTag: Int32?) {
            stateLock.lock()
            shouldRun = true
            stateLock.unlock()
            exitGroup.enter()

            let workerThread = Thread { [weak self] in
                defer {
                    self?.exitGroup.leave()
                }
                self?.workerLoop(affinityTag: affinityTag)
            }
            workerThread.name = "SimpleAUHost.TrackShard.\(latencyClass.rawValue).\(id)"
            workerThread.qualityOfService = .userInteractive
            self.workerThread = workerThread
            workerThread.start()
        }

        func requestStop() {
            stateLock.lock()
            shouldRun = false
            stateLock.unlock()

            // `Thread.cancel()` only sets `isCancelled`; the wakeup signal below is
            // what actually unblocks a worker parked in `wakeup.wait()`. The wakeup
            // latch guarantees the signal is not lost even if it fires before the
            // worker reaches `wait()`, and every wait in `workerLoop` loops back to
            // the `shouldContinue()` check, so shutdown cannot hang in a wait point.
            // Keep those invariants when changing the loop.
            workerThread?.cancel()
            wakeup.signal()
        }

        func joinStopped() {
            if workerThread != nil {
                if exitGroup.wait(timeout: .now() + .seconds(5)) == .timedOut {
                    NSLog("SimpleAUHost: worker shard \(id) did not exit within 5 seconds; continuing to wait.")
                    assertionFailure("Worker shard \(id) failed to stop in time")
                    exitGroup.wait()
                }
            }
            workerThread = nil
        }

        func stopWorker() {
            requestStop()
            joinStopped()
        }

        private func prepareBuffers() throws {
            let ringCapacity = UInt32(max(processingFrames * 32, 4096))
            for ring in inputRings {
                guard ring.initialize(minimumCapacity: ringCapacity) else {
                    throw AudioHostError("Failed to allocate worker shard input buffer.")
                }
            }
            stagedInputs = inputChannelOffsets.map { _ in
                UnsafeMutablePointer<Float>.allocate(capacity: processingFrames)
            }
        }

        private func shouldContinue() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return shouldRun
        }

        private func workerLoop(affinityTag: Int32?) {
            guard processingFrames > 0 else { return }
            promoteCurrentThreadToAudioWorkerQoS(QOS_CLASS_USER_INTERACTIVE)
            if let affinityTag {
                bestEffortSetCurrentThreadAffinity(tag: affinityTag)
            }

            let frames = UInt32(processingFrames)
            var windowStart = currentUptimeNanoseconds()
            var windowWakeups: UInt64 = 0
            var windowActive: UInt64 = 0

            while shouldContinue() && !Thread.current.isCancelled {
                // Permanent exit: a non-nil runtime status means the engine was
                // invalidated (e.g. device change) and must be restarted.
                if runtimeStatusMessage() != nil {
                    return
                }

                switch processReadiness(frameCount: frames) {
                case .ready:
                    break
                case .waitingForInput, .waitingForOutputSpace:
                    // Both the input producer (HW callbacks) and the output consumer
                    // (staged output worker) signal this wakeup every cycle, so
                    // waiting here never stalls while the engine runs. `continue`
                    // re-evaluates `shouldContinue()` so shutdown cannot hang here.
                    wakeup.wait()
                    windowWakeups += 1
                    updateTimingWindow(
                        now: currentUptimeNanoseconds(),
                        windowStart: &windowStart,
                        windowWakeups: &windowWakeups,
                        windowActiveNanoseconds: &windowActive
                    )
                    continue
                }

                let roundStart = currentUptimeNanoseconds()
                stageInputRound(frameCount: frames)
                for runtime in tracks {
                    guard let input1 = inputPointer(for: runtime.inputStartChannelOffset) else { continue }
                    let input2 = runtime.configuration.channelCount == 2
                        ? inputPointer(for: runtime.inputStartChannelOffset + 1)
                        : nil
                    runtime.renderBufferedOutput(input1: input1, input2: input2)
                }
                signalStagedOutput()
                let roundDuration = currentUptimeNanoseconds() - roundStart
                renderTelemetry.record(durationNanoseconds: roundDuration)
                windowActive += roundDuration
                updateTimingWindow(
                    now: currentUptimeNanoseconds(),
                    windowStart: &windowStart,
                    windowWakeups: &windowWakeups,
                    windowActiveNanoseconds: &windowActive
                )
            }
        }

        private enum ProcessReadiness {
            case ready
            case waitingForInput
            case waitingForOutputSpace
        }

        private func processReadiness(frameCount: UInt32) -> ProcessReadiness {
            let hasInput = inputRings.allSatisfy { ring in
                ring.availableRead() >= frameCount
            }
            guard hasInput else { return .waitingForInput }

            let hasOutputSpace = tracks.allSatisfy { $0.canAcceptBufferedInput(frames: processingFrames) }
            return hasOutputSpace ? .ready : .waitingForOutputSpace
        }

        private func stageInputRound(frameCount: UInt32) {
            var droppedFrames: UInt32 = 0
            for index in inputRings.indices {
                let readFrames = inputRings[index].read(into: stagedInputs[index], count: frameCount)
                if readFrames < frameCount {
                    droppedFrames = max(droppedFrames, frameCount - readFrames)
                    stagedInputs[index].advanced(by: Int(readFrames)).update(repeating: 0, count: processingFrames - Int(readFrames))
                }
            }
            if droppedFrames > 0 {
                recordDroppedFrames(droppedFrames)
            }
        }

        private func inputPointer(for channelOffset: Int) -> UnsafeMutablePointer<Float>? {
            guard let index = channelIndexMap[channelOffset], index < stagedInputs.count else {
                return nil
            }
            return stagedInputs[index]
        }

        private func updateTimingWindow(
            now: UInt64,
            windowStart: inout UInt64,
            windowWakeups: inout UInt64,
            windowActiveNanoseconds: inout UInt64
        ) {
            let oneSecond: UInt64 = 1_000_000_000
            guard now >= windowStart + oneSecond else { return }

            let elapsed = max(1, now - windowStart)
            let utilization = min(UInt64(100), (windowActiveNanoseconds * 100) / elapsed)
            peakUtilizationPercent.storeMax(utilization)
            peakWakeupsPerSecond.storeMax(windowWakeups)

            windowStart = now
            windowWakeups = 0
            windowActiveNanoseconds = 0
        }
    }

}
