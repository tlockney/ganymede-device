import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

// `device.photos.save` (docs/protocol.md, "Photos"): adds an image to the
// photo library with add-only access, so the app can add photos but never
// read the library. `photos.pick` (Pickers.swift) needs no permission; the
// `photos` trio is about this add-only access. The app turns `save` on
// with `DeviceBridge.addPhotoSaving()`.

/// Where saved photos go, and the add-only permission, behind a protocol
/// so tests needn't touch the library.
@MainActor
public protocol PhotoLibrary: Permission {
    /// Adds `image`, already checked to be an image; `done` gets nil, or
    /// the error for the cell.
    func save(_ image: Data, done: @escaping @MainActor (DeviceCallError?) -> Void)
}

/// PhotoKit, add-only.
@MainActor
public final class SystemPhotoLibrary: PhotoLibrary {
    public init() {}

    public var status: PermissionStatus {
        Self.status(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    static func status(_ status: PHAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        // Add-only grants are write-only: the app never reads the library.
        case .authorized, .limited: .writeOnly
        @unknown default: .denied
        }
    }

    public func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        // Without the usage description the system ends the app instead
        // of asking: answer with the status as it is.
        guard status == .notDetermined,
              Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil
        else {
            done(status)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor in done(Self.status(status)) }
        }
    }

    public func save(_ image: Data, done: @escaping @MainActor (DeviceCallError?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: image, options: nil)
        }, completionHandler: { saved, error in
            let failure = saved ? nil : DeviceCallError(
                "failed", "photos.save: \(error?.localizedDescription ?? "the library didn't take the image")")
            Task { @MainActor in done(failure) }
        })
    }
}

extension DeviceBridge {
    /// Turns on `device.photos.save` and the `photos` trio. `library` is
    /// PhotoKit by default. The app needs `NSPhotoLibraryAddUsageDescription`
    /// in its Info.plist and, on a sandboxed Mac, the
    /// `com.apple.security.personal-information.photos-library` entitlement.
    public func addPhotoSaving(_ library: PhotoLibrary? = nil) {
        // Made here, not as the default argument: defaults are evaluated
        // outside the main actor.
        let library = library ?? SystemPhotoLibrary()
        addPermission("photos", library)
        // A bad image fails before the permission prompt.
        addMethod("photos.save", permission: "photos", check: { _ = try Self.savedImage($0) }) { params, reply in
            do {
                library.save(try Self.savedImage(params)) { error in
                    if let error {
                        reply(.failure(error))
                    } else {
                        reply(.success(NSNull()))
                    }
                }
            } catch {
                reply(.failure(error as? DeviceCallError ?? DeviceCallError("failed", "\(error)")))
            }
            return nil
        }
    }

    /// `photos.save`'s image: bytes that ImageIO reads as an image.
    static func savedImage(_ params: [String: Any]) throws -> Data {
        let data: Data
        do {
            data = try bytes(params["image"])
        } catch {
            throw DeviceCallError("failed", "photos.save: \(error)")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              type.conforms(to: .image)
        else {
            throw DeviceCallError("failed", "photos.save takes PNG, JPEG, GIF, HEIC or TIFF bytes")
        }
        return data
    }
}
