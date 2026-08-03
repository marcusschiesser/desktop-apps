import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum FlowError: LocalizedError {
    case usage(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .failed(let message):
            return message
        }
    }
}

struct FlowConfig: Codable, Equatable {
    var enabled: Bool
    var hotkeyKeyCode: Int
    var hotkeyModifiers: [String]
    var transcriptionProvider: String
    var whisperCliPath: String
    var whisperModelPath: String
    var openAIBaseURL: String
    var transcriptionModel: String
    var cleanupEnabled: Bool
    var cleanupModel: String
    var language: String
    var restoreClipboardDelayMs: Int

    static let defaults = FlowConfig(
        enabled: true,
        hotkeyKeyCode: 49,
        hotkeyModifiers: ["command", "shift"],
        transcriptionProvider: "local",
        whisperCliPath: "/opt/homebrew/bin/whisper-cli",
        whisperModelPath: "",
        openAIBaseURL: "https://api.openai.com/v1",
        transcriptionModel: "whisper-1",
        cleanupEnabled: true,
        cleanupModel: "gpt-4.1-mini",
        language: "en",
        restoreClipboardDelayMs: 300
    )
}

struct FlowPaths {
    let root: URL
    let config: URL
    let status: URL
    let recordings: URL

    static func current(fileManager: FileManager = .default) -> FlowPaths {
        let home = fileManager.homeDirectoryForCurrentUser
        let root = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Flow Dictation", isDirectory: true)
        return FlowPaths(
            root: root,
            config: root.appendingPathComponent("config.json"),
            status: root.appendingPathComponent("status.txt"),
            recordings: root.appendingPathComponent("recordings", isDirectory: true)
        )
    }

    func ensure() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: config.path) {
            let data = try JSONEncoder.pretty.encode(FlowConfig.defaults)
            try data.write(to: config, options: .atomic)
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

func loadConfig(paths: FlowPaths) throws -> FlowConfig {
    try paths.ensure()
    let data = try Data(contentsOf: paths.config)
    do {
        return try JSONDecoder().decode(FlowConfig.self, from: data)
    } catch {
        throw FlowError.failed("Invalid config.json: \(error.localizedDescription)")
    }
}

func normalizedSpaces(_ value: String) -> String {
    value
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func cleanTranscriptLocally(_ value: String) -> String {
    let fillerWords = ["um", "uh", "erm", "ah"]
    let words = normalizedSpaces(value).split(separator: " ")
    let filtered = words.filter { word in
        let normalized = word
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
        return !fillerWords.contains(normalized)
    }
    var output = filtered.joined(separator: " ")
    if let first = output.first {
        output.replaceSubrange(output.startIndex...output.startIndex, with: String(first).uppercased())
    }
    if !output.isEmpty, !output.hasSuffix("."), !output.hasSuffix("!"), !output.hasSuffix("?") {
        output.append(".")
    }
    return output
}

func multipartBody(
    fields: [String: String],
    fileField: String,
    filename: String,
    mimeType: String,
    fileData: Data,
    boundary: String
) -> Data {
    var result = Data()
    let crlf = "\r\n"
    for key in fields.keys.sorted() {
        result.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        result.append("Content-Disposition: form-data; name=\"\(key)\"\(crlf)\(crlf)".data(using: .utf8)!)
        result.append(fields[key]!.data(using: .utf8)!)
        result.append(crlf.data(using: .utf8)!)
    }
    result.append("--\(boundary)\(crlf)".data(using: .utf8)!)
    result.append(
        "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\(crlf)".data(using: .utf8)!
    )
    result.append("Content-Type: \(mimeType)\(crlf)\(crlf)".data(using: .utf8)!)
    result.append(fileData)
    result.append(crlf.data(using: .utf8)!)
    result.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
    return result
}

func runSelfTest() throws {
    let encoded = try JSONEncoder.pretty.encode(FlowConfig.defaults)
    let decoded = try JSONDecoder().decode(FlowConfig.self, from: encoded)
    guard decoded == FlowConfig.defaults else {
        throw FlowError.failed("config round-trip failed")
    }

    let cleaned = cleanTranscriptLocally(" um   hello   world ")
    guard cleaned == "Hello world." else {
        throw FlowError.failed("local cleanup failed: \(cleaned)")
    }

    let boundary = "flow-test-boundary"
    let body = multipartBody(
        fields: ["model": "whisper-1"],
        fileField: "file",
        filename: "sample.wav",
        mimeType: "audio/wav",
        fileData: Data([0x01, 0x02]),
        boundary: boundary
    )
    let bodyText = String(decoding: body, as: UTF8.self)
    guard bodyText.contains("name=\"model\""),
          bodyText.contains("filename=\"sample.wav\""),
          bodyText.contains("--\(boundary)--") else {
        throw FlowError.failed("multipart construction failed")
    }

    print("ok: config, cleanup, and multipart tests passed")
}
