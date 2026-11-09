import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// `device.camera.capture` (docs/protocol.md, "Camera"): the system camera
// screen, for one photo. It is a dialog that asks for the camera
// permission first: it queues with the other dialogs, and a cancel or an
// interrupt closes it. The app turns it on with
// `DeviceBridge.addCameraCapture()`.

/// The camera permission, over AVFoundation.
@MainActor
public final class SystemCameraPermission: Permission {
    public init() {}

    public var status: PermissionStatus {
        Self.status(AVCaptureDevice.authorizationStatus(for: .video))
    }

    static func status(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    public func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        // Without the usage description the system ends the app instead
        // of asking: answer with the status as it is.
        guard status == .notDetermined,
              Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
        else {
            done(status)
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            Task { @MainActor in done(self.status) }
        }
    }
}

extension DeviceBridge {
    /// Turns on `device.camera.capture` and the `camera` trio where the
    /// device has a camera screen: iPad and iPhone. On a Mac it does
    /// nothing unless `permission` is passed (tests). The app needs
    /// `NSCameraUsageDescription` in its Info.plist.
    public func addCameraCapture(_ permission: Permission? = nil) {
        // Made here, not as the default argument: defaults are evaluated
        // outside the main actor.
        guard let permission = permission ?? Self.systemCamera() else { return }
        addPermission("camera", permission)
        addPermissionedDialog("camera.capture", permission: "camera")
    }

    private static func systemCamera() -> Permission? {
        #if os(iOS)
        UIImagePickerController.isSourceTypeAvailable(.camera) ? SystemCameraPermission() : nil
        #else
        nil
        #endif
    }
}

#if os(iOS)

/// The system camera screen, answering once it has gone.
@MainActor
enum CameraPicker {
    static func controller(done: @escaping (DialogResult) -> Void) throws -> UIViewController {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            throw DialogUnavailable(description: "this device has no camera")
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.mediaTypes = ["public.image"]
        let delegate = CameraDelegate(done: done)
        picker.delegate = delegate
        retain(delegate, by: picker)
        return picker
    }
}

private final class CameraDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let done: (DialogResult) -> Void
    private var answered = false

    init(done: @escaping (DialogResult) -> Void) {
        self.done = done
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        answer(picker) {
            guard let jpeg = image?.jpegData(compressionQuality: 0.9) else {
                return .failed("camera.capture: the photo couldn't be read")
            }
            guard jpeg.count <= DeviceBridge.maxBinaryBytes else {
                return .failed("camera.capture: the photo is over \(DeviceBridge.maxBinaryBytes) bytes")
            }
            return .photo(jpeg)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        answer(picker) { .dismissed }
    }

    /// Closes the camera, then answers: the next dialog shows only once it
    /// has gone.
    private func answer(_ picker: UIImagePickerController, _ result: @escaping () -> DialogResult) {
        guard !answered else { return }
        answered = true
        let done = self.done
        if picker.presentingViewController != nil {
            picker.dismiss(animated: true) { done(result()) }
        } else {
            done(result())
        }
    }
}

#endif
