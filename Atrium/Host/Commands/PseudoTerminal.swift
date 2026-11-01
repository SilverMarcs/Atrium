import Darwin
import Foundation

/// A program running on a pseudo-terminal of its own, which is its controlling
/// terminal: it sees a terminal on its input and output, programs that open
/// `/dev/tty` reach it, and Control-C interrupts what's in the foreground.
///
/// The program leads a session of its own, as a shell in a terminal window
/// does. When it exits, the terminal closes and anything it left running in
/// the background is hung up, as closing the window would. Its exit is always
/// reported, so it never lingers unreaped.
nonisolated final class PseudoTerminal: @unchecked Sendable {
    enum Event: Sendable {
        case output(Data)
        /// The exit status, or 128 plus the signal that ended the program.
        case exit(Int32)
    }

    let pid: pid_t
    /// What the program writes, then how it exited.
    let events: AsyncStream<Event>

    /// The terminal and sources are only touched on `queue`.
    private let master: Int32
    private let queue = DispatchQueue(label: "Atrium.PseudoTerminal")
    private let continuation: AsyncStream<Event>.Continuation
    private var readSource: (any DispatchSourceRead)?
    private var exitSource: (any DispatchSourceProcess)?
    private var isOpen = true

    /// Starts `arguments[0]` at `executable` in `directory`.
    init(executable: String, arguments: [String], environment: [String: String], directory: String,
         size: (columns: UInt16, rows: UInt16) = (120, 40)) throws {
        let cExecutable = strdup(executable)
        let cDirectory = strdup(directory)
        let cArguments = arguments.map { strdup($0) } + [nil]
        let cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            free(cExecutable)
            free(cDirectory)
            cArguments.forEach { free($0) }
            cEnvironment.forEach { free($0) }
        }
        // Prepared before forking: the child may only make async-signal-safe calls until it execs.
        var defaultAction = sigaction()
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&defaultAction.sa_mask)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var window = winsize(ws_row: size.rows, ws_col: size.columns, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1

        let pid = forkpty(&master, nil, nil, &window)
        if pid == 0 {
            // Signals Atrium ignores or blocks would otherwise stay that way in the program.
            for signal in 1..<NSIG where signal != SIGKILL && signal != SIGSTOP {
                sigaction(signal, &defaultAction, nil)
            }
            sigprocmask(SIG_SETMASK, &emptyMask, nil)
            chdir(cDirectory)
            execve(cExecutable, cArguments, cEnvironment)
            _exit(127)
        }
        guard pid > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.pid = pid
        self.master = master
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        queue.async { [self] in
            let reader = DispatchSource.makeReadSource(fileDescriptor: self.master, queue: queue)
            reader.setEventHandler { [weak self] in self?.readAvailable() }
            // Closing the terminal once the source lets go of it.
            reader.setCancelHandler { [master = self.master] in Darwin.close(master) }
            reader.resume()
            readSource = reader
            // A program that already exited reports it as soon as this resumes.
            let exit = DispatchSource.makeProcessSource(identifier: self.pid, eventMask: .exit, queue: queue)
            exit.setEventHandler { [weak self] in self?.programExited() }
            exit.resume()
            exitSource = exit
        }
    }

    deinit {
        if isOpen { readSource?.cancel() }
    }

    /// Types bytes into the terminal. What the program hasn't read yet when
    /// its input fills up is dropped.
    func write(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard isOpen else { return }
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// Sends a signal to the program and everything it started that's still
    /// in its session, including jobs a shell runs in groups of their own.
    func signal(_ signal: Int32) {
        for member in Self.processes(inSession: pid) { kill(member, signal) }
    }

    /// Hangs up the terminal, as closing its window would. Its output stops,
    /// and the exit follows once the program has ended.
    func close() {
        signal(SIGHUP)
        queue.async { [self] in closeTerminal() }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while isOpen {
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 {
                continuation.yield(.output(Data(buffer[..<count])))
            } else {
                // Nothing more for now, or nothing will write to the terminal again.
                if count == 0 || errno != EAGAIN { closeTerminal() }
                return
            }
        }
    }

    private func programExited() {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        // What it wrote before exiting may not have been read yet.
        readAvailable()
        closeTerminal()
        exitSource?.cancel()
        signal(SIGHUP)
        // A job the program forked just before exiting can miss the first hang-up while it starts.
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in signal(SIGHUP) }
        let endingSignal = status & 0x7F
        continuation.yield(.exit(endingSignal == 0 ? (status >> 8) & 0xFF : 128 + endingSignal))
        continuation.finish()
    }

    private func closeTerminal() {
        guard isOpen else { return }
        isOpen = false
        readSource?.cancel()
    }

    /// The processes whose session `leader` started, including after it exited.
    private static func processes(inSession leader: pid_t) -> [pid_t] {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&query, 3, nil, &size, nil, 0) == 0 else { return [] }
        // Room for processes started since the size was read.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&query, 3, &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .map(\.kp_proc.p_pid)
            .filter { $0 > 0 && getsid($0) == leader }
    }
}
