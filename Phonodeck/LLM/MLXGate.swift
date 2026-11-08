import Foundation
import MLX

/// Lets only one piece of MLX work (the storyteller, a narrator sentence, a listening pass,
/// loading a model) use the GPU at a time. Running two at once can stall or crash the app.
/// Voice and listening work jumps the queue, so the narrator never waits behind a memory pass.
actor MLXGate {
    static let shared = MLXGate()

    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire(urgent: Bool = false) async {
        if !held { held = true; return }
        await withCheckedContinuation { c in
            if urgent { waiters.insert(c, at: 0) } else { waiters.append(c) }
        }
    }

    /// Runs `body` while holding the gate. The work itself runs off the main thread.
    nonisolated func run<T: Sendable>(urgent: Bool = false, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        await acquire(urgent: urgent)
        do {
            let v = try await Task.detached(priority: .userInitiated) { try await body() }.value
            await release()
            return v
        } catch {
            await release()
            throw error
        }
    }

    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
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
