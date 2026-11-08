import Foundation
import MLX

/// Lets only one piece of MLX work (the storyteller, a narrator sentence, a listening pass,
/// loading a model) use the GPU at a time. Running two at once can stall or crash the app.
/// Voice and listening work jumps the queue, so the narrator never waits behind a memory pass.
actor MLXGate {
    static let shared = MLXGate()

    private var held = false
    private var waiters: [(CheckedContinuation<Void, Never>, String)] = []
    /// What holds the gate now and since when, so a waiting voice can say what it is waiting for.
    private(set) var holder: String?
    private(set) var heldSince: Date?

    func acquire(urgent: Bool = false, label: String = "the storyteller") async {
        if !held { held = true; holder = label; heldSince = .now; return }
        await withCheckedContinuation { c in
            if urgent { waiters.insert((c, label), at: 0) } else { waiters.append((c, label)) }
        }
    }

    /// "the storyteller (for 12 s)", or nil when the gate is free.
    func status() -> String? {
        guard held, let holder else { return nil }
        let s = heldSince.map { Int(Date.now.timeIntervalSince($0)) } ?? 0
        return "\(holder), busy for \(s) s"
    }

    /// Runs `body` while holding the gate. The work itself runs off the main thread.
    nonisolated func run<T: Sendable>(urgent: Bool = false, label: String = "the storyteller", _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        await acquire(urgent: urgent, label: label)
        do {
            // Always on the same thread: MLX keeps its GPU streams and command encoders per thread,
            // so a voice that made speech on one thread could crash when asked again on another.
            let v = try await Task.detached(executorPreference: MLXThread.shared, priority: .userInitiated) { try await body() }.value
            await release()
            return v
        } catch {
            await release()
            throw error
        }
    }

    func release() {
        if waiters.isEmpty {
            held = false; holder = nil; heldSince = nil
        } else {
            let (c, label) = waiters.removeFirst()
            holder = label; heldSince = .now
            c.resume()
        }
    }
}

/// One long-lived thread that runs every gated piece of MLX work.
final class MLXThread: TaskExecutor, @unchecked Sendable {
    static let shared = MLXThread()

    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var jobs: [UnownedJob] = []

    private init() {
        let thread = Thread { [unowned self] in self.loop() }
        thread.name = "Phonodeck MLX"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 8 << 20
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        lock.withLock { jobs.append(job) }
        ready.signal()
    }

    private func loop() {
        while true {
            ready.wait()
            guard let job = lock.withLock({ jobs.isEmpty ? nil : jobs.removeFirst() }) else { continue }
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

/// Carries a model object into background work. The gate makes sure only one task uses it at a time.
struct Unchecked<T>: @unchecked Sendable { let value: T }

/// Remembers the last MLX failure that would close the app, so the next launch can say what it was.
/// MLX reports some failures from outside the task that started the work, where `withError` can't
/// catch them; those still end the app, but the reason is no longer lost.
enum MLXCrashRecorder {
    static let key = "lastMLXError"

    static func install() {
        setErrorHandler({ message, _ in
            let text = message.map { String(cString: $0) } ?? "unknown MLX error"
            UserDefaults.standard.set(text, forKey: MLXCrashRecorder.key)
            UserDefaults.standard.synchronize()
            NSLog("Phonodeck MLX error: %@", text)
            fatalError(text)
        })
    }

    /// The failure from last time, if there was one. Reading it clears it.
    static func takeLast() -> String? {
        let text = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return text
    }
}
