import CoreLocation
import Foundation

// `device.location` (docs/protocol.md, "Location"): a fix, a stream of
// fixes, and geocoding, over Core Location. When-in-use authorization
// only. `current` and `watch` need the location permission (and the
// ledger's grant); geocoding needs neither. The app turns the namespace on
// with `DeviceBridge.addLocation()`.

/// How close a fix must be, as the cell asked.
public enum LocationAccuracy: String, Sendable, CaseIterable {
    /// Within metres.
    case best
    /// Within about a hundred metres.
    case block
    /// Within a few kilometres.
    case city

    /// Core Location's desired accuracy for it.
    public var desired: CLLocationAccuracy {
        switch self {
        case .best: kCLLocationAccuracyBest
        case .block: kCLLocationAccuracyHundredMeters
        case .city: kCLLocationAccuracyThreeKilometers
        }
    }
}

/// A place a geocode found; every part only when known.
public struct GeoPlace: Sendable, Equatable {
    public var name: String?
    public var street: String?
    public var city: String?
    public var region: String?
    public var postalCode: String?
    public var country: String?
    public var countryCode: String?
    public var latitude: Double?
    public var longitude: Double?

    public init(
        name: String? = nil, street: String? = nil, city: String? = nil, region: String? = nil,
        postalCode: String? = nil, country: String? = nil, countryCode: String? = nil,
        latitude: Double? = nil, longitude: Double? = nil
    ) {
        self.name = name
        self.street = street
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.country = country
        self.countryCode = countryCode
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Where fixes and places come from, and the location permission, behind
/// a protocol so tests needn't use Core Location.
@MainActor
public protocol LocationProvider: Permission {
    /// One fix; `done` once, unless the returned cancel runs first.
    func current(_ accuracy: LocationAccuracy, done: @escaping @MainActor (Result<CLLocation, DeviceCallError>) -> Void) -> () -> Void
    /// Fixes until the source is stopped, or `failed` ends it.
    func watch(
        _ accuracy: LocationAccuracy, update: @escaping @MainActor (CLLocation) -> Void,
        failed: @escaping @MainActor (DeviceCallError) -> Void
    ) -> StreamSource
    /// The places `address` may be; `[]` when none.
    func geocode(_ address: String, done: @escaping @MainActor (Result<[GeoPlace], DeviceCallError>) -> Void) -> () -> Void
    /// What is at a position; `[]` when nothing.
    func reverseGeocode(
        latitude: Double, longitude: Double, done: @escaping @MainActor (Result<[GeoPlace], DeviceCallError>) -> Void
    ) -> () -> Void
}

/// Core Location. Each fix and watch has a manager of its own, so their
/// accuracies don't mix and stopping one leaves the others running.
@MainActor
public final class SystemLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    /// For the status and the authorization prompt.
    private let manager = CLLocationManager()
    private var waiting: [@MainActor (PermissionStatus) -> Void] = []
    /// One-shot fixes and geocodes in flight, kept until they answer.
    private var inFlight: [ObjectIdentifier: AnyObject] = [:]

    override public init() {
        super.init()
        manager.delegate = self
    }

    public var status: PermissionStatus {
        Self.status(manager.authorizationStatus, manager.accuracyAuthorization)
    }

    static func status(_ status: CLAuthorizationStatus, _ accuracy: CLAccuracyAuthorization) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        // When in use or always (and the Mac's older `authorized`).
        default: accuracy == .reducedAccuracy ? .reducedAccuracy : .authorized
        }
    }

    public func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        // Without a usage description the system shows nothing and never
        // calls back: answer with the status as it is.
        let keys = ["NSLocationWhenInUseUsageDescription", "NSLocationUsageDescription"]
        guard status == .notDetermined,
              keys.contains(where: { Bundle.main.object(forInfoDictionaryKey: $0) != nil })
        else {
            done(status)
            return
        }
        waiting.append(done)
        if waiting.count == 1 { manager.requestWhenInUseAuthorization() }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let status = self.status
            guard status != .notDetermined, !waiting.isEmpty else { return }
            let done = waiting
            waiting = []
            for answer in done { answer(status) }
        }
    }

    public func current(_ accuracy: LocationAccuracy, done: @escaping @MainActor (Result<CLLocation, DeviceCallError>) -> Void) -> () -> Void {
        let fix = OneFix(accuracy)
        let key = ObjectIdentifier(fix)
        inFlight[key] = fix
        fix.start { [weak self] result in
            self?.inFlight[key] = nil
            done(result)
        }
        return { [weak self] in
            fix.stop()
            self?.inFlight[key] = nil
        }
    }

    public func watch(
        _ accuracy: LocationAccuracy, update: @escaping @MainActor (CLLocation) -> Void,
        failed: @escaping @MainActor (DeviceCallError) -> Void
    ) -> StreamSource {
        Watch(accuracy, update: update, failed: failed)
    }

    // CLGeocoder is deprecated in macOS and iOS 26 in favour of MapKit's
    // geocoding requests; it still works, and MapKit would add a framework
    // for two methods. Moving over is a follow-up.
    public func geocode(_ address: String, done: @escaping @MainActor (Result<[GeoPlace], DeviceCallError>) -> Void) -> () -> Void {
        let geocoder = CLGeocoder()
        let key = ObjectIdentifier(geocoder)
        inFlight[key] = geocoder
        geocoder.geocodeAddressString(address) { [weak self] placemarks, error in
            MainActor.assumeIsolated {
                guard self?.inFlight.removeValue(forKey: key) != nil else { return }
                done(Self.places("location.geocode", placemarks, error))
            }
        }
        return { [weak self] in
            self?.inFlight[key] = nil
            geocoder.cancelGeocode()
        }
    }

    public func reverseGeocode(
        latitude: Double, longitude: Double, done: @escaping @MainActor (Result<[GeoPlace], DeviceCallError>) -> Void
    ) -> () -> Void {
        let geocoder = CLGeocoder()
        let key = ObjectIdentifier(geocoder)
        inFlight[key] = geocoder
        geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)) { [weak self] placemarks, error in
            MainActor.assumeIsolated {
                guard self?.inFlight.removeValue(forKey: key) != nil else { return }
                done(Self.places("location.reverseGeocode", placemarks, error))
            }
        }
        return { [weak self] in
            self?.inFlight[key] = nil
            geocoder.cancelGeocode()
        }
    }

    private static func places(_ method: String, _ placemarks: [CLPlacemark]?, _ error: Error?) -> Result<[GeoPlace], DeviceCallError> {
        if let placemarks, !placemarks.isEmpty { return .success(placemarks.map(place)) }
        if let error = error as? CLError {
            switch error.code {
            case .geocodeFoundNoResult, .geocodeFoundPartialResult: return .success([])
            case .network: return .failure(DeviceCallError("failed", "\(method): no network, or too many requests"))
            default: return .failure(DeviceCallError("failed", "\(method): \(error.localizedDescription)"))
            }
        }
        if let error { return .failure(DeviceCallError("failed", "\(method): \(error.localizedDescription)")) }
        return .success((placemarks ?? []).map(place))
    }

    static func place(_ mark: CLPlacemark) -> GeoPlace {
        let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        return GeoPlace(
            name: mark.name, street: street.isEmpty ? nil : street, city: mark.locality,
            region: mark.administrativeArea, postalCode: mark.postalCode, country: mark.country,
            countryCode: mark.isoCountryCode,
            latitude: mark.location?.coordinate.latitude, longitude: mark.location?.coordinate.longitude)
    }

    /// Why a fix failed, for the cell.
    nonisolated static func error(_ method: String, _ error: Error) -> DeviceCallError {
        switch (error as? CLError)?.code {
        case .denied: DeviceCallError("denied", "\(method): location isn't allowed for this app")
        case .locationUnknown: DeviceCallError("failed", "\(method): the device couldn't find where it is")
        default: DeviceCallError("failed", "\(method): \(error.localizedDescription)")
        }
    }
}

/// A fix Core Location reports as valid.
private func valid(_ location: CLLocation) -> Bool {
    location.horizontalAccuracy >= 0
}

/// One `requestLocation()`.
@MainActor
private final class OneFix: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var done: (@MainActor (Result<CLLocation, DeviceCallError>) -> Void)?

    init(_ accuracy: LocationAccuracy) {
        super.init()
        manager.desiredAccuracy = accuracy.desired
    }

    func start(_ done: @escaping @MainActor (Result<CLLocation, DeviceCallError>) -> Void) {
        self.done = done
        manager.delegate = self
        manager.requestLocation()
    }

    func stop() {
        done = nil
        manager.stopUpdatingLocation()
        manager.delegate = nil
    }

    private func finish(_ result: Result<CLLocation, DeviceCallError>) {
        let done = self.done
        stop()
        done?(result)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let location = locations.last(where: valid) else { return }
            finish(.success(location))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            finish(.failure(SystemLocationProvider.error("location.current", error)))
        }
    }
}

/// `startUpdatingLocation()` until stopped.
@MainActor
private final class Watch: NSObject, CLLocationManagerDelegate, StreamSource {
    private let manager = CLLocationManager()
    private let update: @MainActor (CLLocation) -> Void
    private let failed: @MainActor (DeviceCallError) -> Void

    init(_ accuracy: LocationAccuracy, update: @escaping @MainActor (CLLocation) -> Void, failed: @escaping @MainActor (DeviceCallError) -> Void) {
        self.update = update
        self.failed = failed
        super.init()
        manager.desiredAccuracy = accuracy.desired
        manager.delegate = self
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.delegate = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for location in locations where valid(location) { update(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            // Not found yet: Core Location keeps trying.
            if (error as? CLError)?.code == .locationUnknown { return }
            stop()
            failed(SystemLocationProvider.error("location.watch", error))
        }
    }
}

extension DeviceBridge {
    /// Turns on `device.location`: `hello` lists the trio and
    /// `location.current`, `watch`, `geocode` and `reverseGeocode`.
    /// `provider` is Core Location by default. The app needs
    /// `NSLocationWhenInUseUsageDescription` in its Info.plist, and on the
    /// Mac with the hardened runtime, the location entitlement.
    public func addLocation(_ provider: LocationProvider? = nil) {
        // Made here, not as the default argument: defaults are evaluated
        // outside the main actor.
        let provider = provider ?? SystemLocationProvider()
        addPermission("location", provider)
        addMethod("location.current", permission: "location") { params, reply in
            do {
                let accuracy = try Self.accuracy(params, "location.current")
                return provider.current(accuracy) { result in
                    reply(result.map { Self.fixReply($0) as Any })
                }
            } catch {
                reply(.failure(error as? DeviceCallError ?? DeviceCallError("failed", "\(error)")))
                return nil
            }
        }
        addStream("location.watch", capacity: 16, permission: "location") { params, sink in
            let accuracy = try Self.accuracy(params, "location.watch")
            return provider.watch(accuracy, update: { sink.send(Self.fixReply($0)) }, failed: { sink.finish($0) })
        }
        addMethod("location.geocode") { params, reply in
            guard let address = params["address"] as? String, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reply(.failure(DeviceCallError("failed", "location.geocode needs an address")))
                return nil
            }
            return provider.geocode(address) { result in reply(result.map { $0.map(Self.placeReply) as Any }) }
        }
        addMethod("location.reverseGeocode") { params, reply in
            guard let latitude = (params["latitude"] as? NSNumber)?.doubleValue, (-90...90).contains(latitude),
                  let longitude = (params["longitude"] as? NSNumber)?.doubleValue, (-180...180).contains(longitude)
            else {
                reply(.failure(DeviceCallError(
                    "failed", "location.reverseGeocode needs a latitude (-90 to 90) and longitude (-180 to 180)")))
                return nil
            }
            return provider.reverseGeocode(latitude: latitude, longitude: longitude) { result in
                reply(result.map { $0.map(Self.placeReply) as Any })
            }
        }
    }

    private static func accuracy(_ params: [String: Any], _ method: String) throws -> LocationAccuracy {
        guard let value = params["accuracy"] else { return .best }
        guard let name = value as? String, let accuracy = LocationAccuracy(rawValue: name) else {
            throw DeviceCallError("failed", "\(method): accuracy must be \"best\", \"block\" or \"city\"")
        }
        return accuracy
    }

    /// A fix as the cell reads it (src/device.ts `LocationFix`): the
    /// optional parts only when Core Location knows them.
    static func fixReply(_ location: CLLocation) -> [String: Any] {
        var reply: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "timestamp": (location.timestamp.timeIntervalSince1970 * 1000).rounded(),
        ]
        if location.verticalAccuracy > 0 {
            reply["altitude"] = location.altitude
            reply["altitudeAccuracy"] = location.verticalAccuracy
        }
        if location.speed >= 0 { reply["speed"] = location.speed }
        if location.course >= 0 { reply["course"] = location.course }
        return reply
    }

    static func placeReply(_ place: GeoPlace) -> [String: Any] {
        var reply: [String: Any] = [:]
        let parts: [(String, String?)] = [
            ("name", place.name), ("street", place.street), ("city", place.city), ("region", place.region),
            ("postalCode", place.postalCode), ("country", place.country), ("countryCode", place.countryCode),
        ]
        for (key, value) in parts { if let value, !value.isEmpty { reply[key] = value } }
        if let latitude = place.latitude, let longitude = place.longitude {
            reply["latitude"] = latitude
            reply["longitude"] = longitude
        }
        return reply
    }
}
