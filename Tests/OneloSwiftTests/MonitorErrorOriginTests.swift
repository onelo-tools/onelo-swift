import XCTest
@testable import OneloSwift

/// #548 — an uncaught crash is tagged with whose code threw it. Pure: no
/// `Onelo(...)` / `OneloAuth(config:)`, so no Keychain access.
final class MonitorErrorOriginTests: XCTestCase {
    private func frame(_ symbol: String?) -> MonitorStackFrame {
        MonitorStackFrame(address: "0x1", symbol: symbol, module: "MyApp", offset: nil)
    }

    func testMangledModuleIsRead() {
        XCTAssertEqual(_swiftModule(ofMangled: "$s10OneloSwift0A4AuthC9_doRefreshyyF"), "OneloSwift")
        XCTAssertEqual(_swiftModule(ofMangled: "$s5MyApp11ContentViewV4bodyQrvg"), "MyApp")
        XCTAssertEqual(_swiftModule(ofMangled: "$ss17_assertionFailure"), "Swift")
        XCTAssertNil(_swiftModule(ofMangled: "objc_exception_throw"))
    }

    func testCrashInSdkCodeIsTheSdks() {
        let frames = [
            frame("$s10OneloSwift19MonitorCrashCaptureC7installyyF"), // capture machinery
            frame("_sigtramp"),
            frame("$ss17_assertionFailure"),
            frame("$s10OneloSwift0A4AuthC9_doRefreshyyF"),
            frame("$s5MyApp11ContentViewV4bodyQrvg"),
        ]
        XCTAssertEqual(monitorErrorOrigin(frames: frames), "onelo_sdk")
    }

    func testAppCallbackTheSdkInvokedIsTheApps() {
        let frames = [
            frame("$s5MyApp9AppDelegateC8onChangeyyF"),
            frame("$s10OneloSwift0A4AuthC15notifyListenersyyF"),
        ]
        XCTAssertEqual(monitorErrorOrigin(frames: frames), "app")
    }

    func testStrippedFramesAreTheApps() {
        XCTAssertEqual(monitorErrorOrigin(frames: [frame(nil), frame(nil)]), "app")
    }
}
