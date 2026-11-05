import AVFoundation
import Foundation

// `device.sound`: `play` starts a sound and answers at once; `player`
// opens a handle a cell controls with `sound.control` and closes with
// `sound.close` (docs/protocol.md). Each sound belongs to the kernel that
// started it (the call's `owner`), and ends when that kernel's Worker
// restarts or its handler is released; `dropAll()` stops them all.

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
    /// Players one kernel may have open at once, so a loop that forgets to
    /// close them fails rather than filling memory.
    static let maxPlayers = 32
    /// `sound.play` sounds one kernel may have playing at once, for the same reason.
    static let maxPlaying = 32

    /// A sound and the kernel (`owner`) that started it; 0 when the page
    /// sent no owner.
    private struct Owned {
        let owner: Int
        let sound: SoundPlayback
    }

    private let loader: SoundLoader
    /// `sound.play` sounds, kept until they end.
    private var playing: [ObjectIdentifier: Owned] = [:]
    private var players: [Int: Owned] = [:]
    /// The player each `sound.player` call opened, by call id, so a cancel
    /// that arrives after the answer closes it: the page drops that answer,
    /// so nothing else would. Kept while the player is open.
    private var openedBy: [Int: Int] = [:]
    private var nextID = 1

    init(loader: SoundLoader) {
        self.loader = loader
    }

    /// `call` is the call's id, when the page sent one; `owner` the
    /// kernel's.
    func handle(_ method: String, _ params: [String: Any], call: Int? = nil, owner: Int = 0) -> [String: Any] {
        switch method {
        case "sound.play":
            // A sound an audio interruption paused never finishes; let it go.
            playing = playing.filter { $0.value.sound.isPlaying }
            guard playing.values.filter({ $0.owner == owner }).count < Self.maxPlaying else {
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
            playing[key] = Owned(owner: owner, sound: sound)
            sound.onFinish = { [weak self] in self?.playing[key] = nil }
            guard sound.play() else {
                playing[key] = nil
                return DeviceBridge.error("failed", "sound.play: the sound couldn't start")
            }
            return ["result": NSNull()]
        case "sound.player":
            guard players.values.filter({ $0.owner == owner }).count < Self.maxPlayers else {
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
            players[id] = Owned(owner: owner, sound: sound)
            if let call { openedBy[call] = id }
            return ["result": ["player": id, "duration": sound.duration]]
        case "sound.control":
            // Another kernel's player is not this one's to control.
            guard let id = Self.number(params["player"]).flatMap({ Int(exactly: $0) }),
                  let sound = players[id].flatMap({ $0.owner == owner ? $0.sound : nil })
            else {
                return DeviceBridge.error("failed", "sound.control: no open player with that id")
            }
            // Check everything before changing anything.
            let action = params["action"] == nil || params["action"] is NSNull ? "state" : params["action"] as? String ?? ""
            guard ["state", "play", "pause", "stop", "seek"].contains(action) else {
                return DeviceBridge.error("failed", "sound.control takes play, pause, stop, seek or state")
            }
            var time: Double?
            if action == "seek" {
                guard let t = Self.number(params["time"]), t.isFinite, t >= 0 else {
                    return DeviceBridge.error("failed", "sound.control: seek needs a time in seconds")
                }
                time = t
            }
            let volume: Float?
            do {
                volume = try Self.volume(params)
            } catch {
                return DeviceBridge.error("failed", "\(error)")
            }
            if let volume { sound.volume = volume }
            switch action {
            case "play":
                guard sound.play() else {
                    return DeviceBridge.error("failed", "sound.control: the sound couldn't start")
                }
            case "pause":
                sound.pause()
            case "stop":
                sound.pause()
                sound.currentTime = 0
            case "seek":
                sound.currentTime = min(time ?? 0, sound.duration)
            default:
                break
            }
            return ["result": ["playing": sound.isPlaying, "time": sound.currentTime, "duration": sound.duration]]
        case "sound.close":
            guard let id = Self.number(params["player"]).flatMap({ Int(exactly: $0) }) else {
                return DeviceBridge.error("failed", "sound.close needs a player id")
            }
            if players[id]?.owner == owner { close(id) }
            return ["result": NSNull()]
        default:
            return DeviceBridge.error("unavailable", "\(method) isn't available in this app")
        }
    }

    /// The page cancelled call `call`. If it opened a player, the page
    /// dropped the answer and has no handle to close it with.
    func cancel(_ call: Int) {
        if let id = openedBy[call] { close(id) }
    }

    /// Stops the sounds and closes the players `owner` started: its Worker
    /// restarted (a new `hello`) or its kernel shut down.
    func release(_ owner: Int) {
        for (key, entry) in playing where entry.owner == owner {
            entry.sound.pause()
            playing[key] = nil
        }
        for (id, entry) in players where entry.owner == owner {
            close(id)
        }
    }

    /// Stops every sound and closes every player.
    func stopAll() {
        for entry in playing.values { entry.sound.pause() }
        for entry in players.values { entry.sound.pause() }
        playing = [:]
        players = [:]
        openedBy = [:]
    }

    private func close(_ id: Int) {
        players.removeValue(forKey: id)?.sound.pause()
        openedBy = openedBy.filter { $0.value != id }
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
