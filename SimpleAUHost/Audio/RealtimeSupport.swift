import Darwin
import Foundation

func currentUptimeNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

func estimatedPerformanceCoreCount() -> Int {
    for key in ["hw.perflevel0.physicalcpu", "hw.perflevel0.logicalcpu"] {
        if let value = sysctlInt(named: key), value > 0 {
            return value
        }
    }
    return ProcessInfo.processInfo.activeProcessorCount
}

private func sysctlInt(named name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let result = name.withCString { pointer in
        sysctlbyname(pointer, &value, &size, nil, 0)
    }
    guard result == 0 else { return nil }
    return Int(value)
}

func bestEffortSetCurrentThreadAffinity(tag: Int32) {
    var policy = thread_affinity_policy_data_t(affinity_tag: tag)
    withUnsafeMutablePointer(to: &policy) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: 1) { rebounded in
            _ = thread_policy_set(
                mach_thread_self(),
                thread_policy_flavor_t(THREAD_AFFINITY_POLICY),
                rebounded,
                1
            )
        }
    }
}
