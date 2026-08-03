#if os(macOS)
import AppKit
import AVFoundation
import ApplicationServices
import Foundation

private struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(_ board: NSPasteboard) -> ClipboardSnapshot {
        ClipboardSnapshot(items: (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        })
    }

    func restore(_ board: NSPasteboard) {
        board.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}

@MainActor
private final class Pill {
    private let panel: NSPanel
    private let text: NSTextField

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 210, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let visual = NSVisualEffectView(frame: panel.contentView!.bounds)
        visual.autoresizingMask = [.width, .height]
        visual.material = .hudWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 27
        text = NSTextField(labelWithString: "Listening...")
        text.alignment = .center
        text.font = .systemFont(ofSize: 15, weight: .semibold)
        text.frame = visual.bounds.insetBy(dx: 12, dy: 12)
        text.autoresizingMask = [.width, .height]
        visual.addSubview(text)
        panel.contentView = visual
    }

    func show(_ value: String) {
        text.stringValue = value
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - panel.frame.width / 2,
                y: screen.visibleFrame.minY + 72
            ))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

@MainActor
private final class Recorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?

    func start(in directory: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw FlowError.failed("invalid microphone format")
        }
        let name = "dictation-\(Int(Date().timeIntervalSince1970)).wav"
        let output = directory.appendingPathComponent(name)
        let audioFile = try AVAudioFile(forWriting: output, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            try? audioFile.write(from: buffer)
        }
        engine.prepare()
        try engine.start()
        file = audioFile
        url = output
    }

    func stop() throws -> URL {
        guard engine.isRunning, let output = url else {
            throw FlowError.failed("no recording is active")
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        url = nil
        return output
    }
}

private struct TranscriptionReply: Decodable { let text: String }
private struct ChatReply: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}

@MainActor
private final class Controller: NSObject, NSApplicationDelegate {
    private let paths: FlowPaths
    private var config: FlowConfig
    private let recorder = Recorder()
    private let pill = Pill()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var enabledItem: NSMenuItem?
    private var statusItem: NSStatusItem?
    private var pressed = false
    private var processing = false

    init(paths: FlowPaths, config: FlowConfig) {
        self.paths = paths
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        do {
            try installTap()
            publish(config.enabled ? "Ready - hold Command + Shift + Space" : "Disabled")
        } catch {
            publish("Startup failed: \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    private func publish(_ value: String) {
        let line = value.replacingOccurrences(of: "\n", with: " ")
        print(line)
        fflush(stdout)
        if let data = line.data(using: .utf8) { try? data.write(to: paths.status, options: .atomic) }
    }

    private func installMenu() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "FD"
        status.button?.toolTip = "Flow Dictation"
        let menu = NSMenu()
        let toggle = NSMenuItem(title: config.enabled ? "Disable Dictation" : "Enable Dictation", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open config.json", action: #selector(openConfigAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Exit Helper", action: #selector(quitAction), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        status.menu = menu
        enabledItem = toggle
        statusItem = status
    }

    @objc private func toggleEnabled() {
        config.enabled.toggle()
        enabledItem?.title = config.enabled ? "Disable Dictation" : "Enable Dictation"
        publish(config.enabled ? "Enabled" : "Disabled")
    }

    @objc private func openConfigAction() { NSWorkspace.shared.open(paths.config) }
    @objc private func quitAction() { NSApp.terminate(nil) }

    private func installTap() throws {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            throw FlowError.failed("Accessibility permission is required; grant it and restart")
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let controller = Unmanaged<Controller>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { controller.handle(type, event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { throw FlowError.failed("could not install the global shortcut") }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        tap = eventTap
        source = runLoopSource
    }

    private func expectedFlags() -> CGEventFlags {
        var result: CGEventFlags = []
        for name in config.hotkeyModifiers {
            switch name.lowercased() {
            case "command": result.insert(.maskCommand)
            case "shift": result.insert(.maskShift)
            case "option": result.insert(.maskAlternate)
            case "control": result.insert(.maskControl)
            default: break
            }
        }
        return result
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        guard config.enabled, !processing else { return }
        guard Int(event.getIntegerValueField(.keyboardEventKeycode)) == config.hotkeyKeyCode else { return }
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        guard event.flags.intersection(relevant) == expectedFlags() else { return }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !pressed {
            pressed = true
            Task { await begin() }
        } else if type == .keyUp, pressed {
            pressed = false
            Task { await finish() }
        }
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    private func begin() async {
        guard await microphoneAllowed() else {
            pressed = false
            publish("Microphone permission denied")
            return
        }
        do {
            try recorder.start(in: paths.recordings)
            pill.show("Listening...")
            publish("Listening - release to transcribe")
        } catch {
            pressed = false
            publish("Recording failed: \(error.localizedDescription)")
        }
    }

    private func finish() async {
        do {
            let audio = try recorder.stop()
            processing = true
            pill.show("Transcribing...")
            config = try loadConfig(paths: paths)
            let raw = try await transcribe(audio)
            let cleaned = try await cleanup(raw)
            pill.show("Pasting...")
            try await paste(cleaned)
            try? FileManager.default.removeItem(at: audio)
            pill.hide()
            publish("Pasted \(cleaned.count) characters")
        } catch {
            pill.hide()
            publish("Dictation failed: \(error.localizedDescription)")
        }
        processing = false
    }

    private func transcribe(_ audio: URL) async throws -> String {
        if config.transcriptionProvider.lowercased() == "local" {
            do { return try localTranscribe(audio) }
            catch {
                guard ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil else { throw error }
                publish("Local Whisper unavailable; using OpenAI")
            }
        }
        return try await apiTranscribe(audio)
    }

    private func localTranscribe(_ audio: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: config.whisperCliPath) else {
            throw FlowError.failed("whisper-cli not found at \(config.whisperCliPath)")
        }
        guard FileManager.default.fileExists(atPath: config.whisperModelPath) else {
            throw FlowError.failed("configure whisperModelPath in config.json")
        }
        let output = audio.deletingPathExtension().appendingPathExtension("transcript")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.whisperCliPath)
        process.arguments = ["-m", config.whisperModelPath, "-f", audio.path, "-of", output.path, "-otxt", "--no-prints", "-l", config.language]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FlowError.failed("whisper-cli failed") }
        let resultURL = URL(fileURLWithPath: output.path + ".txt")
        let result = try String(contentsOf: resultURL, encoding: .utf8)
        try? FileManager.default.removeItem(at: resultURL)
        return normalizedSpaces(result)
    }

    private func apiTranscribe(_ audio: URL) async throws -> String {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            throw FlowError.failed("OPENAI_API_KEY is not set")
        }
        let boundary = "flow-\(UUID().uuidString)"
        let body = multipartBody(
            fields: ["model": config.transcriptionModel, "language": config.language],
            fileField: "file",
            filename: audio.lastPathComponent,
            mimeType: "audio/wav",
            fileData: try Data(contentsOf: audio),
            boundary: boundary
        )
        let base = config.openAIBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/audio/transcriptions") else { throw FlowError.failed("invalid API URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FlowError.failed("transcription API failed")
        }
        return normalizedSpaces(try JSONDecoder().decode(TranscriptionReply.self, from: data).text)
    }

    private func cleanup(_ raw: String) async throws -> String {
        guard config.cleanupEnabled,
              let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            return cleanTranscriptLocally(raw)
        }
        let base = config.openAIBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else { return cleanTranscriptLocally(raw) }
        let payload: [String: Any] = [
            "model": config.cleanupModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": "Remove filler words, fix punctuation and casing, preserve meaning, and return only revised text."],
                ["role": "user", "content": raw]
            ]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = try? JSONDecoder().decode(ChatReply.self, from: data).choices.first?.message.content else {
            return cleanTranscriptLocally(raw)
        }
        return normalizedSpaces(text)
    }

    private func paste(_ value: String) async throws {
        let board = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(board)
        board.clearContents()
        guard board.setString(value, forType: .string) else { throw FlowError.failed("clipboard write failed") }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            snapshot.restore(board)
            throw FlowError.failed("could not synthesize Command-V")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: UInt64(max(100, config.restoreClipboardDelayMs)) * 1_000_000)
        snapshot.restore(board)
    }
}

func serve(paths: FlowPaths) throws {
    try paths.ensure()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = Controller(paths: paths, config: try loadConfig(paths: paths))
    app.delegate = controller
    app.run()
    _ = controller
}

func openConfig(paths: FlowPaths) throws {
    try paths.ensure()
    guard NSWorkspace.shared.open(paths.config) else { throw FlowError.failed("could not open config.json") }
    print("Opened \(paths.config.path)")
}
#endif
