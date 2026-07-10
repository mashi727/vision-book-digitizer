import Foundation

/// A minimal counting semaphore for async/await. Used to serialize calls into
/// Vision: `RecognizeDocumentsRequest.perform` is not safe to run concurrently
/// from multiple tasks in one process — doing so segfaults intermittently — so all
/// recognition funnels through a single permit while the cheaper render and
/// figure-detection stages stay parallel.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int) { self.permits = permits }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Process-wide gate that keeps Vision recognition strictly serial.
let visionGate = AsyncSemaphore(1)
