import AVFoundation
import Foundation

// `device.sound`: `play` starts a sound and answers at once; `player`
// opens a handle a cell controls with `sound.control` and closes with
// `sound.close` (docs/protocol.md). Players end with the page: `dropAll()`
// stops them all.

/// One sound loaded and ready, behind a protocol so tests needn't play any.
@MainActor
public protocol SoundPlayback: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    var volume: Float { get set }
    /// Called once each time the sound plays to its end, or fails to.
    var onFinish: (() -> Void)? { get set }
    /// False when the sound couldn't start.
    @discardableResult func play() -> Bool
    func pause()
}

/// Loads sounds from bytes.
@MainActor
public protocol SoundLoader {
    /// Throws when the bytes aren't audio this device can play.
    func load(_ data: Data) throws -> SoundPlayback
}

/// `AVAudioPlayer`: anything AVFoundation reads (WAV, AIFF, MP3, AAC/M4A,
/// CAF, FLAC). It follows the app's audio session; on iPhone the default
/// session is silenced by the ring/silent switch.
@MainActor
public struct SystemSoundLoader: SoundLoader {
    public init() {}
    public func load(_ data: Data) throws -> SoundPlayback {
        try SystemSound(data)
    }
}

@MainActor
private final class SystemSound: NSObject, SoundPlayback, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onFinish: (() -> Void)?

    init(_ data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }

    var duration: TimeInterval { player.duration }
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    var isPlaying: Bool { player.isPlaying }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    func play() -> Bool { player.play() }
    func pause() { player.pause() }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?()
    }
}

/// The sounds a bridge is playing and the players it has open.
@MainActor
final class Sounds {
    /// Players one page may have open at once, so a loop that forgets to
    /// close them fails rather than filling memory.
    static let maxPlayers = 32
    /// `sound.play` sounds one page may have playing at once, for the same reason.
    static let maxPlaying = 32

    private let loader: SoundLoader
    /// `sound.play` sounds, kept until they end.
    private var playing: [ObjectIdentifier: SoundPlayback] = [:]
    private var players: [Int: SoundPlayback] = [:]
    private var nextID = 1

    init(loader: SoundLoader) {
        self.loader = loader
    }

    func handle(_ method: String, _ params: [String: Any]) -> [String: Any] {
        switch method {
        case "sound.play":
            guard playing.count < Self.maxPlaying else {
                return DeviceBridge.error("failed", "sound.play: \(Self.maxPlaying) sounds are playing; wait for one to end")
            }
            let sound: SoundPlayback
            do {
                sound = try load(method, params)
                if let volume = try Self.volume(params) { sound.volume = volume }
            } catch {
                return DeviceBridge.error("failed", "\(error)")
            }
            let key = ObjectIdentifier(sound)
            playing[key] = sound
            sound.onFinish = { [weak self] in self?.playing[key] = nil }
            guard sound.play() else {
                playing[key] = nil
                return DeviceBridge.error("failed", "sound.play: the sound couldn't start")
            }
            return ["result": NSNull()]
        case "sound.player":
            guard players.count < Self.maxPlayers else {
                return DeviceBridge.error("failed", "sound.player: \(Self.maxPlayers) players are open; close one first")
            }
            let sound: SoundPlayback
            do {
                sound = try load(method, params)
            } catch {
                return DeviceBridge.error("failed", "\(error)")
            }
            let id = nextID
            nextID += 1
            players[id] = sound
            return ["result": ["player": id, "duration": sound.duration]]
        case "sound.control":
            guard let id = Self.number(params["player"]).flatMap({ Int(exactly: $0) }), let sound = players[id] else {
                return DeviceBridge.error("failed", "sound.control: no open player with that id")
            }
            do {
                if let volume = try Self.volume(params) { sound.volume = volume }
            } catch {
                return DeviceBridge.error("failed", "\(error)")
            }
            switch params["action"] as? String {
            case nil, "state":
                break
            case "play":
                sound.play()
            case "pause":
                sound.pause()
            case "stop":
                sound.pause()
                sound.currentTime = 0
            case "seek":
                guard let time = Self.number(params["time"]), time.isFinite, time >= 0 else {
                    return DeviceBridge.error("failed", "sound.control: seek needs a time in seconds")
                }
                sound.currentTime = min(time, sound.duration)
            default:
                return DeviceBridge.error("failed", "sound.control takes play, pause, stop, seek or state")
            }
            return ["result": ["playing": sound.isPlaying, "time": sound.currentTime, "duration": sound.duration]]
        case "sound.close":
            guard let id = Self.number(params["player"]).flatMap({ Int(exactly: $0) }) else {
                return DeviceBridge.error("failed", "sound.close needs a player id")
            }
            players.removeValue(forKey: id)?.pause()
            return ["result": NSNull()]
        default:
            return DeviceBridge.error("unavailable", "\(method) isn't available in this app")
        }
    }

    /// Stops every sound and closes every player.
    func stopAll() {
        for sound in playing.values { sound.pause() }
        for sound in players.values { sound.pause() }
        playing = [:]
        players = [:]
    }

    private func load(_ method: String, _ params: [String: Any]) throws -> SoundPlayback {
        let data: Data
        do {
            data = try DeviceBridge.bytes(params["data"])
        } catch {
            throw Dialog.ParamsError(description: "\(method): \(error)")
        }
        do {
            return try loader.load(data)
        } catch {
            throw Dialog.ParamsError(description: "\(method): this device can't play these bytes (\(error.localizedDescription))")
        }
    }

    /// A `volume` from 0 to 1, when given.
    private static func volume(_ params: [String: Any]) throws -> Float? {
        guard let value = params["volume"], !(value is NSNull) else { return nil }
        guard let n = number(value), n >= 0, n <= 1 else {
            throw Dialog.ParamsError(description: "volume must be a number from 0 to 1")
        }
        return Float(n)
    }

    /// A number, not a boolean, which WebKit also hands over as an NSNumber.
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}
