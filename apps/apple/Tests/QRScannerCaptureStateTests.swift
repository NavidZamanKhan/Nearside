import Foundation

@main
struct QRScannerCaptureStateTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        var scanner = QRScannerCaptureState()
        check(scanner.shouldScan, "A presented scanner starts in camera mode")
        check(scanner.capture(), "The first scanned result is accepted")
        check(!scanner.shouldScan, "A result immediately pauses the camera")
        check(!scanner.capture(), "Repeated metadata callbacks are ignored")
        scanner.retry()
        check(scanner.shouldScan, "An invalid result can be explicitly retried")
        check(scanner.capture(), "Retry accepts another result")
        check(scanner.beginPairing(), "A valid captured result enters secure pairing")
        check(scanner.isProcessing, "Pairing progress is visible")
        check(!scanner.capture(), "In-flight pairing cannot process a repeated QR")
        check(!scanner.cancel(), "An in-flight authentication cannot masquerade as cancelled")
        scanner.retry()
        check(scanner.isProcessing, "Retry cannot start a second handshake")
        scanner.finishPairing(succeeded: false)
        check(!scanner.shouldScan && !scanner.isProcessing, "A rejected pairing stays paused for review")
        scanner.retry()
        check(scanner.capture() && scanner.beginPairing(), "A rejected pairing permits an explicit retry")
        scanner.finishPairing(succeeded: true)
        check(scanner.phase == .completed, "Success completes the scanner")
        scanner.retry()
        check(!scanner.shouldScan && !scanner.capture(), "Success prevents repeated processing")

        var cancelled = QRScannerCaptureState()
        check(cancelled.cancel(), "Cancel is available before capture")
        check(!cancelled.shouldScan && !cancelled.capture(), "Cancellation stops all capture callbacks")
        cancelled.retry()
        check(cancelled.phase == .cancelled, "A dismissed scanner cannot be restarted by delayed callbacks")
        cancelled.finishPairing(succeeded: true)
        check(cancelled.phase == .cancelled, "A late result cannot change a cancelled scanner")

        var invalid = QRScannerCaptureState()
        check(invalid.capture() && invalid.cancel(), "Cancellation also works after an invalid capture")
        check(!invalid.beginPairing(), "Cancelled captures cannot enroll peers")

        print("QR scanner capture state: \(checks) checks passed")
    }
}
