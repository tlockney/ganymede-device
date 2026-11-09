@testable import DeviceBridge
import Photos
import XCTest

/// A photo library in memory, with a permission the test sets.
@MainActor
private final class FakeLibrary: PhotoLibrary {
    var status: PermissionStatus
    var answer: PermissionStatus = .writeOnly
    var prompts = 0
    var saved: [Data] = []
    var failure: DeviceCallError?

    init(_ status: PermissionStatus) {
        self.status = status
    }

    func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        if status == .notDetermined {
            prompts += 1
            status = answer
        }
        done(status)
    }

    func save(_ image: Data, done: @escaping @MainActor (DeviceCallError?) -> Void) {
        if let failure {
            done(failure)
            return
        }
        saved.append(image)
        done(nil)
    }
}

/// The ledger's prompt, always allowing.
@MainActor
private final class Always: LedgerPrompter {
    var asked = 0
    func askPermission(_ capability: String, notebook: String, id: Int, answer: @escaping @MainActor (LedgerAnswer?) -> Void) {
        asked += 1
        answer(.always)
    }

    func dismissPermission(_ id: Int) {}
}

@MainActor
final class PhotosTests: XCTestCase {
    private lazy var always = Always()
    private var nextID = 0

    /// A 1×1 PNG.
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    /// A bridge that saves photos; kernel 1 runs a.ipynb, kernel 2 none.
    private func bridge(_ library: FakeLibrary) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.ledgerPrompter = always
        bridge.setNotebook("a.ipynb", for: 1)
        bridge.addPhotoSaving(library)
        return bridge
    }

    private func call(_ bridge: DeviceBridge, _ method: String, _ params: [String: Any] = [:], owner: Int = 1) -> [String: Any]? {
        nextID += 1
        var answer: [String: Any]?
        bridge.respond(to: ["id": nextID, "owner": owner, "method": method, "params": params]) { answer = $0 }
        return answer
    }

    private func errorCode(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    private func image(_ data: Data) -> [String: Any] {
        ["image": try! DeviceBridge.binary(data)]
    }

    func testHelloListsSaveAndTheTrio() {
        let capabilities = bridge(FakeLibrary(.authorized)).capabilities
        for method in ["photos.save", "photos.authorizationStatus", "photos.requestAuthorization"] {
            XCTAssertTrue(capabilities.contains(method), method)
        }
        let bare = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        XCTAssertFalse(bare.capabilities.contains("photos.save"))
    }

    func testSaveAsksThenAddsTheImage() {
        let library = FakeLibrary(.notDetermined)
        let reply = call(bridge(library), "photos.save", image(png))
        XCTAssertNotNil(reply?["result"])
        XCTAssertNil(reply?["error"])
        XCTAssertEqual(library.prompts, 1)
        XCTAssertEqual(library.saved, [png])
        XCTAssertEqual(always.asked, 1)
    }

    func testRefusalsRejectDenied() {
        let library = FakeLibrary(.notDetermined)
        library.answer = .denied
        let bridge = bridge(library)
        XCTAssertEqual(errorCode(call(bridge, "photos.save", image(png))), "denied")
        XCTAssertEqual(errorCode(call(bridge, "photos.save", image(png), owner: 2)), "denied", "no notebook")
        XCTAssertTrue(library.saved.isEmpty)
        XCTAssertEqual(call(bridge, "photos.authorizationStatus")?["result"] as? String, "denied")
    }

    func testNotAnImageFailsBeforeAnyPrompt() {
        let library = FakeLibrary(.notDetermined)
        let bridge = bridge(library)
        XCTAssertEqual(errorCode(call(bridge, "photos.save", image(Data("not an image".utf8)))), "failed")
        XCTAssertEqual(errorCode(call(bridge, "photos.save", [:])), "failed")
        XCTAssertEqual(library.prompts, 0)
        XCTAssertEqual(always.asked, 0)
        XCTAssertTrue(library.saved.isEmpty)
    }

    func testALibraryFailureReachesTheCell() {
        let library = FakeLibrary(.writeOnly)
        library.failure = DeviceCallError("failed", "photos.save: full")
        XCTAssertEqual(errorCode(call(bridge(library), "photos.save", image(png))), "failed")
    }

    func testPhotoKitStatusesMap() {
        XCTAssertEqual(SystemPhotoLibrary.status(.notDetermined), .notDetermined)
        XCTAssertEqual(SystemPhotoLibrary.status(.denied), .denied)
        XCTAssertEqual(SystemPhotoLibrary.status(.restricted), .restricted)
        XCTAssertEqual(SystemPhotoLibrary.status(.authorized), .writeOnly)
    }
}
