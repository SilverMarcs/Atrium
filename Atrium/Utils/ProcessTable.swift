import Darwin

/// Read-only queries against the kernel process table.
enum ProcessTable {
    /// Pids whose parent is `parent`, including children that have exited but not
    /// yet been reaped.
    static func children(of parent: pid_t) -> [pid_t] {
        guard parent > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        let capacity = size / MemoryLayout<kinfo_proc>.stride
        let procs = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: capacity)
        defer { procs.deallocate() }
        guard sysctl(&mib, 3, procs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return (0..<count)
            .filter { procs[$0].kp_eproc.e_ppid == parent }
            .map { procs[$0].kp_proc.p_pid }
    }

    /// Whether any process still belongs to process group `group`.
    static func groupIsAlive(_ group: pid_t) -> Bool {
        kill(-group, 0) == 0 || errno == EPERM
    }
}
