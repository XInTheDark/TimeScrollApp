import Foundation

/// A thread that runs a run loop, for run-loop sources such as Accessibility observers.
final class TimeWarpRunLoopThread: Thread {
  private let ready = DispatchSemaphore(value: 0)
  private var runLoop: CFRunLoop?

  init(name: String) {
    super.init()
    self.name = name
    qualityOfService = .utility
  }

  override func start() {
    guard !isExecuting, !isFinished else { return }
    super.start()
    ready.wait()
  }

  override func main() {
    let current = CFRunLoopGetCurrent()
    runLoop = current
    // A run loop with no sources returns at once; a timer that never fires keeps it alive.
    let keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e10, 1e10, 0, 0) { _ in }
    CFRunLoopAddTimer(current, keepAlive, .defaultMode)
    ready.signal()
    CFRunLoopRun()
    CFRunLoopTimerInvalidate(keepAlive)
  }

  /// Runs `block` on the thread. Blocks sent before `finish()` run before the thread exits.
  func perform(_ block: @escaping () -> Void) {
    guard let runLoop else { return }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
    CFRunLoopWakeUp(runLoop)
  }

  /// Ends the run loop after the blocks already sent, so the thread exits.
  func finish() {
    guard let runLoop else { return }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
    CFRunLoopWakeUp(runLoop)
  }
}
