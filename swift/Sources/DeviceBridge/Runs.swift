import Foundation

// A run's input and output (docs/phase-4.md, parts 3 and 4): what the
// share sheet or a Shortcut gave a script, and what it hands back.
// `EngineDevice.attachRun(_:output:)` connects them to one context.

/// A file a run was given or hands back.
public struct RunFile: Equatable, Sendable {
    public let name: String
    /// A MIME type, or "".
    public let type: String
    public let data: Data

    public init(name: String, type: String = "", data: Data) {
        self.name = name
        self.type = type
        self.data = data
    }
}

/// What a run was given: `device.input` in the script.
public struct RunInput: Equatable, Sendable {
    public var text: String?
    public var url: URL?
    public var files: [RunFile]

    public init(text: String? = nil, url: URL? = nil, files: [RunFile] = []) {
        self.text = text
        self.url = url
        self.files = files
    }

    func reply() throws -> [String: Any] {
        var reply: [String: Any] = [
            "files": try files.map { ["name": $0.name, "type": $0.type, "data": try DeviceBridge.binary($0.data)] as [String: Any] },
        ]
        if let text { reply["text"] = text }
        if let url { reply["url"] = url.absoluteString }
        return reply
    }
}

/// What a run handed back with `device.output(...)`.
public struct RunOutput: Equatable, Sendable {
    public let text: String?
    public let url: URL?
    public let files: [RunFile]

    public init(text: String? = nil, url: URL? = nil, files: [RunFile] = []) {
        self.text = text
        self.url = url
        self.files = files
    }

    /// `output`'s params: `{ text?, url?, files: [{ name, data }] }`.
    init(_ params: [String: Any]) throws {
        text = params["text"] as? String
        if let link = params["url"] as? String {
            guard let url = URL(string: link), url.scheme != nil else { throw DeviceCallError("failed", "url isn't a URL") }
            self.url = url
        } else {
            url = nil
        }
        let items = params["files"] as? [Any] ?? []
        files = try items.map { item in
            guard let file = item as? [String: Any], let name = file["name"] as? String, !name.isEmpty,
                  !name.contains("/"), name != ".", name != ".."
            else { throw DeviceCallError("failed", "each file needs a plain name") }
            return RunFile(name: name, data: try DeviceBridge.bytes(file["data"]))
        }
        guard files.reduce(0, { $0 + $1.data.count }) <= DeviceBridge.maxBinaryBytes else {
            throw DeviceCallError("failed", "files together are limited to \(DeviceBridge.maxBinaryBytes) bytes")
        }
        guard text != nil || url != nil || !files.isEmpty else { throw DeviceCallError("failed", "output needs text, a url or files") }
    }
}
