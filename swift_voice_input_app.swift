import Cocoa
import AVFoundation
import ApplicationServices

private let logPath = "/tmp/local-voice-input-swift.log"
private let bundleIdentifier = "com.ms.localvoiceinput.swift"

private func normalizedHotkeyModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags.intersection([.command, .shift, .option, .control])
}

private func normalizedHotkeyModifiers(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
    var result: NSEvent.ModifierFlags = []
    if flags.contains(.maskCommand) {
        result.insert(.command)
    }
    if flags.contains(.maskShift) {
        result.insert(.shift)
    }
    if flags.contains(.maskAlternate) {
        result.insert(.option)
    }
    if flags.contains(.maskControl) {
        result.insert(.control)
    }
    return result
}

private func customDictionaryPath() -> String {
    let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/local-voice-input", isDirectory: true)
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let file = support.appendingPathComponent("custom_dictionary.txt")
    if !FileManager.default.fileExists(atPath: file.path) {
        let template = """
        # 自定义词库 / 错别字纠正
        # 每行一条，格式：识别结果 => 你想要的文字
        # 例子：
        # 閃電說 => 闪电说
        # open ai => OpenAI
        """
        try? template.write(to: file, atomically: true, encoding: .utf8)
    }
    return file.path
}

private func writeLog(_ message: String) {
    let line = message + "\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
                return
            }
        }
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

private func developmentRootCandidates() -> [URL] {
    var candidates: [URL] = []
    let fileManager = FileManager.default

    if let explicitRoot = ProcessInfo.processInfo.environment["LOCAL_VOICE_INPUT_PROJECT_ROOT"], !explicitRoot.isEmpty {
        candidates.append(URL(fileURLWithPath: explicitRoot, isDirectory: true))
    }

    candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))

    let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
    candidates.append(bundleParent)
    candidates.append(bundleParent.deletingLastPathComponent())
    candidates.append(bundleParent.deletingLastPathComponent().deletingLastPathComponent())

    if let resources = Bundle.main.resourceURL {
        let contents = resources.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        candidates.append(bundle.deletingLastPathComponent())
        candidates.append(bundle.deletingLastPathComponent().deletingLastPathComponent())
    }

    var seen = Set<String>()
    return candidates.compactMap { url in
        let standardized = url.standardizedFileURL
        guard seen.insert(standardized.path).inserted else {
            return nil
        }
        return standardized
    }
}

private func discoverBackendPythonExecutable(from infoDictionary: [String: Any]?) -> String? {
    if let explicitPath = infoDictionary?["BackendPythonExecutable"] as? String,
       FileManager.default.isExecutableFile(atPath: explicitPath) {
        return explicitPath
    }

    if let envPath = ProcessInfo.processInfo.environment["LOCAL_VOICE_INPUT_PYTHON"],
       FileManager.default.isExecutableFile(atPath: envPath) {
        return envPath
    }

    for root in developmentRootCandidates() {
        let candidate = root.appendingPathComponent(".venv/bin/python").path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }

    return nil
}

private func discoverHelperScript(named name: String) -> String? {
    if let path = Bundle.main.path(forResource: name, ofType: "py") {
        return path
    }

    for root in developmentRootCandidates() {
        let candidate = root.appendingPathComponent("\(name).py").path
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
    }

    return nil
}

private func userFacingErrorMessage(from rawMessage: String, fallback: String = "这次没完成，请再试一次。") -> String {
    let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return fallback
    }

    if let data = trimmed.data(using: .utf8),
       let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let nestedError = payload["error"] as? String {
        return userFacingErrorMessage(from: nestedError, fallback: fallback)
    }

    if trimmed.contains("ModuleNotFoundError") || trimmed.contains("ImportError") {
        return "本地语音环境没有准备完整，请重新打开 app 再试。"
    }

    if trimmed.contains("Traceback") {
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let summary = lines.reversed().first(where: { line in
            !line.hasPrefix("Traceback")
                && !line.hasPrefix("File ")
                && !line.hasPrefix("^")
        }) {
            return userFacingErrorMessage(from: summary, fallback: fallback)
        }
        return fallback
    }

    if trimmed.hasPrefix("RuntimeError: ") {
        return String(trimmed.dropFirst("RuntimeError: ".count))
    }

    if trimmed.hasPrefix("Error Domain=") {
        return fallback
    }

    return trimmed
}

private struct HotkeyConfiguration {
    private static let keyCodeKey = "hotkey.keyCode"
    private static let modifiersKey = "hotkey.modifiers"
    private static let modifierOnlyKey = "hotkey.isModifierOnly"

    let keyCode: Int
    let modifiers: NSEvent.ModifierFlags
    let isModifierOnly: Bool

    static let defaultValue = HotkeyConfiguration(keyCode: 54, modifiers: [.command], isModifierOnly: true)

    static func load() -> HotkeyConfiguration {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else {
            return defaultValue
        }
        let keyCode = defaults.integer(forKey: keyCodeKey)
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: modifiersKey)))
        let isModifierOnly = defaults.bool(forKey: modifierOnlyKey)
        return HotkeyConfiguration(
            keyCode: keyCode,
            modifiers: normalizedHotkeyModifiers(modifiers),
            isModifierOnly: isModifierOnly
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(keyCode, forKey: Self.keyCodeKey)
        defaults.set(Int(modifiers.rawValue), forKey: Self.modifiersKey)
        defaults.set(isModifierOnly, forKey: Self.modifierOnlyKey)
    }

    var displayString: String {
        if isModifierOnly {
            return Self.modifierOnlyDisplayName(for: keyCode)
        }

        var parts: [String] = []
        if modifiers.contains(.command) {
            parts.append("Command")
        }
        if modifiers.contains(.shift) {
            parts.append("Shift")
        }
        if modifiers.contains(.option) {
            parts.append("Option")
        }
        if modifiers.contains(.control) {
            parts.append("Control")
        }
        parts.append(Self.keyDisplayName(for: keyCode))
        return parts.joined(separator: " + ")
    }

    static func capture(from event: NSEvent) -> HotkeyConfiguration? {
        let keyCode = Int(event.keyCode)
        let modifiers = normalizedHotkeyModifiers(event.modifierFlags)

        if event.type == .flagsChanged, let modifier = modifierFlag(for: keyCode), modifiers == modifier {
            return HotkeyConfiguration(keyCode: keyCode, modifiers: modifier, isModifierOnly: true)
        }

        if event.type == .keyDown, !event.isARepeat {
            return HotkeyConfiguration(keyCode: keyCode, modifiers: modifiers, isModifierOnly: false)
        }

        return nil
    }

    static func modifierFlag(for keyCode: Int) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55:
            return .command
        case 56, 60:
            return .shift
        case 58, 61:
            return .option
        case 59, 62:
            return .control
        default:
            return nil
        }
    }

    private static func modifierOnlyDisplayName(for keyCode: Int) -> String {
        switch keyCode {
        case 54:
            return "右 Command"
        case 55:
            return "左 Command"
        case 56:
            return "左 Shift"
        case 60:
            return "右 Shift"
        case 58:
            return "左 Option"
        case 61:
            return "右 Option"
        case 59:
            return "左 Control"
        case 62:
            return "右 Control"
        default:
            return keyDisplayName(for: keyCode)
        }
    }

    private static func keyDisplayName(for keyCode: Int) -> String {
        let table: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3",
            21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
            31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "Space", 50: "`", 36: "Return",
            48: "Tab", 51: "Delete", 53: "Esc", 117: "Forward Delete", 123: "Left Arrow", 124: "Right Arrow",
            125: "Down Arrow", 126: "Up Arrow", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
            107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        return table[keyCode] ?? "Key \(keyCode)"
    }
}

private struct AudioInputDevice: Decodable {
    let index: Int
    let name: String
    let label: String
}

private struct AudioDevicesResponse: Decodable {
    let devices: [AudioInputDevice]
}

private enum TranscriptionModel: String, CaseIterable {
    case tiny
    case base
    case small

    static let defaultsKey = "transcription.model"

    static func load() -> TranscriptionModel {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else {
            return .base
        }
        return TranscriptionModel(rawValue: rawValue) ?? .base
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    var title: String {
        switch self {
        case .tiny:
            return "Tiny（更快）"
        case .base:
            return "Base（推荐）"
        case .small:
            return "Small（更准）"
        }
    }
}

private enum OutputMode: String, CaseIterable {
    case transcription
    case translationToEnglish
    case naturalEnglish

    static let defaultsKey = "output.mode"

    static func load() -> OutputMode {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else {
            return .transcription
        }
        return OutputMode(rawValue: rawValue) ?? .transcription
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    var title: String {
        switch self {
        case .transcription:
            return "原文转写"
        case .translationToEnglish:
            return "翻译成英文"
        case .naturalEnglish:
            return "自然英文润色"
        }
    }

    var cliTask: String {
        switch self {
        case .transcription:
            return "transcribe"
        case .translationToEnglish:
            return "translate"
        case .naturalEnglish:
            return "translate"
        }
    }

    var englishStyle: String {
        switch self {
        case .transcription, .translationToEnglish:
            return "literal"
        case .naturalEnglish:
            return "natural"
        }
    }

    var usesChineseScript: Bool {
        self == .transcription
    }
}

private enum ChineseOutputScript: String, CaseIterable {
    case simplified
    case traditional

    static let defaultsKey = "output.script"

    static func load() -> ChineseOutputScript {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else {
            return .simplified
        }
        return ChineseOutputScript(rawValue: rawValue) ?? .simplified
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    var title: String {
        switch self {
        case .simplified:
            return "简体中文"
        case .traditional:
            return "繁體中文"
        }
    }
}

private enum HUDState {
    case idle
    case recording
    case transcribing
    case success(String)
    case error(String)
}

private final class HUDView: NSVisualEffectView {
    let titleLabel = NSTextField(labelWithString: "本地语音输入")
    let subtitleLabel = NSTextField(labelWithString: "按住热键说话")
    let detailLabel = NSTextField(labelWithString: "松开后自动转写，并填回当前输入框。")
    let pulseView = NSView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true

        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white

        subtitleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        subtitleLabel.textColor = .white

        detailLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2

        pulseView.wantsLayer = true
        pulseView.layer?.cornerRadius = 8
        pulseView.layer?.backgroundColor = NSColor.systemBlue.cgColor

        [titleLabel, subtitleLabel, detailLabel, pulseView].forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        pulseView.frame = NSRect(x: 22, y: bounds.height - 39, width: 16, height: 16)
        titleLabel.frame = NSRect(x: 48, y: bounds.height - 44, width: bounds.width - 70, height: 22)
        subtitleLabel.frame = NSRect(x: 22, y: bounds.height - 88, width: bounds.width - 44, height: 30)
        detailLabel.frame = NSRect(x: 22, y: 22, width: bounds.width - 44, height: 36)
    }

    func apply(state: HUDState) {
        switch state {
        case .idle:
            pulseView.layer?.backgroundColor = NSColor.systemBlue.cgColor
            subtitleLabel.stringValue = "按住热键说话"
            detailLabel.stringValue = "松开后自动转写，并填回当前输入框。"
        case .recording:
            pulseView.layer?.backgroundColor = NSColor.systemRed.cgColor
            subtitleLabel.stringValue = "正在听你说话"
            detailLabel.stringValue = "继续说，松开热键就会结束并转写。"
        case .transcribing:
            pulseView.layer?.backgroundColor = NSColor.systemOrange.cgColor
            subtitleLabel.stringValue = "正在本地转写"
            detailLabel.stringValue = "模型正在整理语音，马上自动填回原来的输入框。"
        case .success(let text):
            pulseView.layer?.backgroundColor = NSColor.systemGreen.cgColor
            subtitleLabel.stringValue = "已经填回去了"
            detailLabel.stringValue = text
        case .error(let text):
            pulseView.layer?.backgroundColor = NSColor.systemYellow.cgColor
            subtitleLabel.stringValue = "这次没完成"
            detailLabel.stringValue = text
        }
    }
}

private final class HotkeySettingsController: NSWindowController, NSWindowDelegate {
    private let currentLabel = NSTextField(labelWithString: "")
    private let helperLabel = NSTextField(labelWithString: "")
    private let recordButton = NSButton(title: "录制新快捷键", target: nil, action: nil)
    private let resetButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    private let onSave: (HotkeyConfiguration) -> Void
    private let onCaptureStateChange: (Bool) -> Void

    private var captureMonitor: Any?
    private var isCapturing = false
    private var currentHotkey: HotkeyConfiguration

    init(
        hotkey: HotkeyConfiguration,
        onSave: @escaping (HotkeyConfiguration) -> Void,
        onCaptureStateChange: @escaping (Bool) -> Void
    ) {
        self.currentHotkey = hotkey
        self.onSave = onSave
        self.onCaptureStateChange = onCaptureStateChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "快捷键设置"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        buildUI()
        refreshUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopCapture()
    }

    func update(hotkey: HotkeyConfiguration) {
        currentHotkey = hotkey
        refreshUI()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopCapture()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        currentLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        currentLabel.textColor = .labelColor

        helperLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        helperLabel.textColor = .secondaryLabelColor
        helperLabel.lineBreakMode = .byWordWrapping
        helperLabel.maximumNumberOfLines = 3

        [currentLabel, helperLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        [recordButton, resetButton, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.bezelStyle = .rounded
            contentView.addSubview($0)
        }

        recordButton.target = self
        recordButton.action = #selector(startCaptureAction)
        resetButton.target = self
        resetButton.action = #selector(resetDefaultAction)
        closeButton.target = self
        closeButton.action = #selector(closeAction)

        NSLayoutConstraint.activate([
            currentLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            currentLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            currentLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            helperLabel.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 12),
            helperLabel.leadingAnchor.constraint(equalTo: currentLabel.leadingAnchor),
            helperLabel.trailingAnchor.constraint(equalTo: currentLabel.trailingAnchor),

            recordButton.leadingAnchor.constraint(equalTo: currentLabel.leadingAnchor),
            recordButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),

            resetButton.leadingAnchor.constraint(equalTo: recordButton.trailingAnchor, constant: 12),
            resetButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: currentLabel.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
        ])
    }

    private func refreshUI() {
        currentLabel.stringValue = "当前快捷键：\(currentHotkey.displayString)"
        if isCapturing {
            helperLabel.stringValue = "现在按下新的快捷键。支持单独修饰键，也支持组合键。按 Esc 取消。"
            recordButton.title = "正在录制..."
        } else {
            helperLabel.stringValue = "默认推荐右 Command。长按说话，松开后自动发送。"
            recordButton.title = "录制新快捷键"
        }
    }

    private func stopCapture() {
        if let captureMonitor {
            NSEvent.removeMonitor(captureMonitor)
        }
        captureMonitor = nil
        if isCapturing {
            onCaptureStateChange(false)
        }
        isCapturing = false
        refreshUI()
    }

    @objc private func startCaptureAction() {
        guard !isCapturing else { return }
        isCapturing = true
        onCaptureStateChange(true)
        refreshUI()

        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            guard self.isCapturing else { return event }

            if event.type == .keyDown, event.keyCode == 53, normalizedHotkeyModifiers(event.modifierFlags).isEmpty {
                self.stopCapture()
                return nil
            }

            guard let hotkey = HotkeyConfiguration.capture(from: event) else {
                return nil
            }

            self.currentHotkey = hotkey
            self.onSave(hotkey)
            self.stopCapture()
            return nil
        }
    }

    @objc private func resetDefaultAction() {
        currentHotkey = .defaultValue
        onSave(currentHotkey)
        refreshUI()
    }

    @objc private func closeAction() {
        window?.close()
    }
}

private final class HUDController {
    let panel: NSPanel
    let content: HUDView
    private var hideWorkItem: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        content = HUDView(frame: panel.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
    }

    func show(_ state: HUDState, autoHideAfter delay: TimeInterval? = nil) {
        hideWorkItem?.cancel()
        content.apply(state: state)
        positionPanel()
        panel.orderFrontRegardless()
        if let delay {
            let item = DispatchWorkItem { [weak self] in
                self?.panel.orderOut(nil)
            }
            hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func hide() {
        hideWorkItem?.cancel()
        panel.orderOut(nil)
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.origin.x + (visible.width - size.width) / 2
        let y = visible.origin.y + visible.height - size.height - 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class AudioRecorderController: NSObject, AVAudioRecorderDelegate {
    private(set) var process: Process?
    private(set) var outputURL: URL?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default:
            completion(false)
        }
    }

    func start(deviceIndex: Int) throws -> URL {
        if let process, process.isRunning {
            throw NSError(domain: "VoiceInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前已经在录音中了。"])
        }

        guard
            let python = backendPythonExecutablePath(),
            let helper = audioHelperPath()
        else {
            throw NSError(domain: "VoiceInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有找到音频输入后端。"])
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-input-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [helper, "record", "--device-index", String(deviceIndex), "--output", url.path]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        Thread.sleep(forTimeInterval: 0.4)

        if !process.isRunning {
            let errorText = combinedProcessOutput(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            throw NSError(
                domain: "VoiceInput",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "开始录音失败。" : errorText]
            )
        }

        self.process = process
        self.outputURL = url
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        return url
    }

    func stop() throws -> URL {
        guard let process, let outputURL else {
            throw NSError(domain: "VoiceInput", code: 4, userInfo: [NSLocalizedDescriptionKey: "当前没有正在进行的录音。"])
        }

        if let stdinPipe = process.standardInput as? Pipe {
            stdinPipe.fileHandleForWriting.write(Data("q\n".utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        let errorText = combinedProcessOutput(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        let status = process.terminationStatus

        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        self.outputURL = nil

        if status != 0 {
            throw NSError(
                domain: "VoiceInput",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "录音结束失败。" : errorText]
            )
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NSError(domain: "VoiceInput", code: 5, userInfo: [NSLocalizedDescriptionKey: "没有拿到录音文件。"])
        }
        return outputURL
    }

    private func backendPythonExecutablePath() -> String? {
        discoverBackendPythonExecutable(from: Bundle.main.infoDictionary)
    }

    private func audioHelperPath() -> String? {
        discoverHelperScript(named: "voice_input_audio_cli")
    }

    private func customDictionaryPath() -> String {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/local-voice-input", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let file = support.appendingPathComponent("custom_dictionary.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            let template = """
            # 自定义词库 / 错别字纠正
            # 每行一条，格式：识别结果 => 你想要的文字
            # 例子：
            # 閃電說 => 闪电说
            # open ai => OpenAI
            """
            try? template.write(to: file, atomically: true, encoding: .utf8)
        }
        return file.path
    }

    private func combinedProcessOutput(stdoutPipe: Pipe?, stderrPipe: Pipe?) -> String {
        let stdout = stdoutPipe.flatMap {
            String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } ?? ""
        let stderr = stderrPipe.flatMap {
            String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } ?? ""
        let parts = [stderr.trimmingCharacters(in: .whitespacesAndNewlines), stdout.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }
}

private struct TranscriptionResult: Decodable {
    let text: String?
    let raw_text: String?
    let language: String?
    let probability: Double?
    let task: String?
    let error: String?
}

private enum RecordingSource {
    case manual
    case hotkey
}

private enum HotkeyBackend: String {
    case accessibility
    case inputMonitoring
}

final class VoiceInputAppDelegate: NSObject, NSApplicationDelegate {
    private static let audioDeviceIndexDefaultsKey = "audio.deviceIndex"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let hud = HUDController()
    private let recorder = AudioRecorderController()
    private let statusMenu = NSMenu()
    private let hotkeyHoldDelay: TimeInterval = 0.12

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var settingsController: HotkeySettingsController?
    private var hotkey = HotkeyConfiguration.load()
    private var isCapturingHotkey = false
    private var hotkeyIsPressed = false
    private var hotkeyPressCancelled = false
    private var pendingHotkeyStart: DispatchWorkItem?
    private var isRecording = false
    private var isTranscribing = false
    private var recordingSource: RecordingSource?
    private var targetApp: NSRunningApplication?
    private var transcriptionTask: Process?
    private var currentHotkeyItem: NSMenuItem?
    private var hotkeyStatusItem: NSMenuItem?
    private var hotkeyBackend: HotkeyBackend?
    private var audioSourceMenuItem: NSMenuItem?
    private var audioSourceMenu = NSMenu()
    private var modelMenuItem: NSMenuItem?
    private var modelMenu = NSMenu()
    private var outputModeMenuItem: NSMenuItem?
    private var outputModeMenu = NSMenu()
    private var outputScriptMenuItem: NSMenuItem?
    private var outputScriptMenu = NSMenu()
    private var availableAudioDevices: [AudioInputDevice] = []
    private var selectedAudioDeviceIndex: Int?
    private var selectedModel = TranscriptionModel.load()
    private var selectedOutputMode = OutputMode.load()
    private var selectedOutputScript = ChineseOutputScript.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        writeLog("Swift native voice input starting")
        selectedAudioDeviceIndex = Self.loadSelectedAudioDeviceIndex()
        buildStatusItem()
        refreshHotkeyUI()
        refreshHotkeyPermissionState(promptIfMissing: true)
        refreshModelMenu()
        refreshOutputModeMenu()
        refreshOutputScriptMenu()
        refreshAudioSourceMenu()
        loadAudioDevices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelPendingHotkeyStart()
        removeHotkeyMonitor()
    }

    private func buildStatusItem() {
        statusItem.button?.title = "语"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleStatusItemClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusMenu.removeAllItems()
        statusMenu.addItem(withTitle: "开始或结束说话", action: #selector(toggleFromMenu), keyEquivalent: "")
        let currentHotkeyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        currentHotkeyItem.isEnabled = false
        statusMenu.addItem(currentHotkeyItem)
        self.currentHotkeyItem = currentHotkeyItem
        let hotkeyStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hotkeyStatusItem.isEnabled = false
        statusMenu.addItem(hotkeyStatusItem)
        self.hotkeyStatusItem = hotkeyStatusItem
        let audioSourceMenuItem = NSMenuItem(title: "语音输入源", action: nil, keyEquivalent: "")
        audioSourceMenuItem.submenu = audioSourceMenu
        statusMenu.addItem(audioSourceMenuItem)
        self.audioSourceMenuItem = audioSourceMenuItem
        let modelMenuItem = NSMenuItem(title: "识别模型", action: nil, keyEquivalent: "")
        modelMenuItem.submenu = modelMenu
        statusMenu.addItem(modelMenuItem)
        self.modelMenuItem = modelMenuItem
        let outputModeMenuItem = NSMenuItem(title: "输出模式", action: nil, keyEquivalent: "")
        outputModeMenuItem.submenu = outputModeMenu
        statusMenu.addItem(outputModeMenuItem)
        self.outputModeMenuItem = outputModeMenuItem
        let outputScriptMenuItem = NSMenuItem(title: "文字输出", action: nil, keyEquivalent: "")
        outputScriptMenuItem.submenu = outputScriptMenu
        statusMenu.addItem(outputScriptMenuItem)
        self.outputScriptMenuItem = outputScriptMenuItem
        statusMenu.addItem(withTitle: "打开自定义词库", action: #selector(openCustomDictionary), keyEquivalent: "")
        statusMenu.addItem(withTitle: "快捷键设置...", action: #selector(openHotkeySettings), keyEquivalent: ",")
        statusMenu.addItem(withTitle: "重新检查热键权限", action: #selector(recheckHotkeyPermission), keyEquivalent: "")
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(withTitle: "打开辅助功能", action: #selector(openAccessibility), keyEquivalent: "")
        statusMenu.addItem(withTitle: "打开输入监控", action: #selector(openInputMonitoring), keyEquivalent: "")
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        statusMenu.items.forEach { $0.target = self }
    }

    private func refreshHotkeyUI() {
        currentHotkeyItem?.title = "当前快捷键：\(hotkey.displayString)"
        if let hotkeyBackend {
            hotkeyStatusItem?.title = "热键状态：已启用（\(hotkeyBackend == .accessibility ? "辅助功能" : "输入监控")）"
        } else {
            hotkeyStatusItem?.title = "热键状态：未启用（缺少辅助功能/输入监控）"
        }
        settingsController?.update(hotkey: hotkey)
    }

    private static func loadSelectedAudioDeviceIndex() -> Int? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: audioDeviceIndexDefaultsKey) != nil else {
            return nil
        }
        return defaults.integer(forKey: audioDeviceIndexDefaultsKey)
    }

    private func saveSelectedAudioDeviceIndex(_ index: Int?) {
        let defaults = UserDefaults.standard
        if let index {
            defaults.set(index, forKey: Self.audioDeviceIndexDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.audioDeviceIndexDefaultsKey)
        }
    }

    private func refreshModelMenu() {
        modelMenu.removeAllItems()
        for model in TranscriptionModel.allCases {
            let item = NSMenuItem(title: model.title, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.rawValue
            item.state = model == selectedModel ? .on : .off
            modelMenu.addItem(item)
        }
    }

    private func refreshOutputModeMenu() {
        outputModeMenu.removeAllItems()
        for mode in OutputMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectOutputMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == selectedOutputMode ? .on : .off
            outputModeMenu.addItem(item)
        }
        outputScriptMenuItem?.title = selectedOutputMode.usesChineseScript ? "文字输出" : "文字输出（仅原文模式）"
        outputScriptMenuItem?.isEnabled = selectedOutputMode.usesChineseScript
    }

    private func refreshOutputScriptMenu() {
        outputScriptMenu.removeAllItems()
        for script in ChineseOutputScript.allCases {
            let item = NSMenuItem(title: script.title, action: #selector(selectOutputScript(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = script.rawValue
            item.state = script == selectedOutputScript ? .on : .off
            outputScriptMenu.addItem(item)
        }
    }

    private func refreshAudioSourceMenu() {
        audioSourceMenu.removeAllItems()

        if availableAudioDevices.isEmpty {
            let emptyItem = NSMenuItem(title: "正在读取输入源...", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            audioSourceMenu.addItem(emptyItem)
        } else {
            for device in availableAudioDevices {
                let item = NSMenuItem(title: device.label, action: #selector(selectAudioDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.index
                item.state = device.index == selectedAudioDeviceIndex ? .on : .off
                audioSourceMenu.addItem(item)
            }
        }

        audioSourceMenu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "重新读取输入源", action: #selector(refreshAudioDevicesFromMenu), keyEquivalent: "")
        refreshItem.target = self
        audioSourceMenu.addItem(refreshItem)
        audioSourceMenu.addItem(NSMenuItem.separator())
        let hintItem = NSMenuItem(title: "提示：BlackHole / Loopback / iPhone 麦克风等也会显示在这里", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        audioSourceMenu.addItem(hintItem)
    }

    private func loadAudioDevices() {
        guard
            let python = pythonExecutablePath(),
            let helper = audioHelperPath()
        else {
            availableAudioDevices = []
            refreshAudioSourceMenu()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: python)
            task.arguments = [helper, "list-devices"]
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardOutput = stdout
            task.standardError = stderr

            do {
                try task.run()
                task.waitUntilExit()
                let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                guard task.terminationStatus == 0 else {
                    DispatchQueue.main.async {
                        writeLog("Failed to load audio devices: \(stderrText.isEmpty ? stdoutText : stderrText)")
                        self.availableAudioDevices = []
                        self.refreshAudioSourceMenu()
                    }
                    return
                }

                let data = Data(stdoutText.utf8)
                guard let response = try? JSONDecoder().decode(AudioDevicesResponse.self, from: data) else {
                    DispatchQueue.main.async {
                        writeLog("Failed to decode audio devices response")
                        self.availableAudioDevices = []
                        self.refreshAudioSourceMenu()
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.availableAudioDevices = response.devices
                    if let selected = self.selectedAudioDeviceIndex,
                       !response.devices.contains(where: { $0.index == selected }) {
                        self.selectedAudioDeviceIndex = response.devices.first?.index
                        self.saveSelectedAudioDeviceIndex(self.selectedAudioDeviceIndex)
                    }
                    if self.selectedAudioDeviceIndex == nil {
                        self.selectedAudioDeviceIndex = response.devices.first?.index
                        self.saveSelectedAudioDeviceIndex(self.selectedAudioDeviceIndex)
                    }
                    self.refreshAudioSourceMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    writeLog("Failed to run audio device helper: \(error.localizedDescription)")
                    self.availableAudioDevices = []
                    self.refreshAudioSourceMenu()
                }
            }
        }
    }

    private func refreshHotkeyPermissionState(promptIfMissing: Bool) {
        let accessibilityTrusted = AXIsProcessTrusted()
        let inputMonitoringTrusted = CGPreflightListenEventAccess()

        if accessibilityTrusted {
            installAccessibilityHotkeyMonitor()
            return
        }

        if inputMonitoringTrusted {
            installInputMonitoringHotkeyMonitor()
            return
        }

        removeHotkeyMonitor()
        refreshHotkeyUI()
        writeLog("Hotkey monitor not enabled: accessibility and input monitoring permissions missing")
        if promptIfMissing {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            _ = CGRequestListenEventAccess()
            showPermissionAlertIfNeeded()
        }
    }

    private func installAccessibilityHotkeyMonitor() {
        removeHotkeyMonitor()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handle(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handle(event: event)
            return event
        }
        hotkeyBackend = .accessibility
        writeLog("Hotkey monitor enabled via accessibility: \(hotkey.displayString)")
        refreshHotkeyUI()
    }

    private func installInputMonitoringHotkeyMonitor() {
        removeHotkeyMonitor()

        let mask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let delegate = Unmanaged<VoiceInputAppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            delegate.handle(cgEvent: event, type: type)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            writeLog("Failed to create input monitoring event tap")
            refreshHotkeyUI()
            return
        }

        eventTap = tap
        eventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), eventTapRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        hotkeyBackend = .inputMonitoring
        writeLog("Hotkey monitor enabled via input monitoring: \(hotkey.displayString)")
        refreshHotkeyUI()
    }

    private func removeHotkeyMonitor() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), eventTapRunLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        globalMonitor = nil
        localMonitor = nil
        eventTap = nil
        eventTapRunLoopSource = nil
        hotkeyBackend = nil
    }

    private func handle(event: NSEvent) {
        if isCapturingHotkey {
            return
        }

        if hotkey.isModifierOnly {
            handleModifierOnlyHotkey(event)
        } else {
            handleStandardHotkey(event)
        }
    }

    private func handle(cgEvent: CGEvent, type: CGEventType) {
        if isCapturingHotkey {
            return
        }

        if hotkey.isModifierOnly {
            handleModifierOnlyHotkey(cgEvent, type: type)
        } else {
            handleStandardHotkey(cgEvent, type: type)
        }
    }

    private func handleModifierOnlyHotkey(_ event: NSEvent) {
        if event.type == .flagsChanged && Int(event.keyCode) == hotkey.keyCode {
            let isPressedNow = normalizedHotkeyModifiers(event.modifierFlags) == hotkey.modifiers
            if isPressedNow && !hotkeyIsPressed {
                hotkeyIsPressed = true
                hotkeyPressCancelled = false
                scheduleHotkeyRecordingStart()
                return
            }

            if !isPressedNow && hotkeyIsPressed {
                hotkeyIsPressed = false
                cancelPendingHotkeyStart()
                hotkeyPressCancelled = false
                stopHotkeyRecordingIfNeeded()
            }
            return
        }

        if hotkeyIsPressed, event.type == .keyDown, recordingSource != .hotkey {
            hotkeyPressCancelled = true
            cancelPendingHotkeyStart()
        }
    }

    private func handleModifierOnlyHotkey(_ event: CGEvent, type: CGEventType) {
        if type == .flagsChanged && Int(event.getIntegerValueField(.keyboardEventKeycode)) == hotkey.keyCode {
            let isPressedNow = normalizedHotkeyModifiers(event.flags) == hotkey.modifiers
            if isPressedNow && !hotkeyIsPressed {
                hotkeyIsPressed = true
                hotkeyPressCancelled = false
                scheduleHotkeyRecordingStart()
                return
            }

            if !isPressedNow && hotkeyIsPressed {
                hotkeyIsPressed = false
                cancelPendingHotkeyStart()
                hotkeyPressCancelled = false
                stopHotkeyRecordingIfNeeded()
            }
            return
        }

        if hotkeyIsPressed, type == .keyDown, recordingSource != .hotkey {
            hotkeyPressCancelled = true
            cancelPendingHotkeyStart()
        }
    }

    private func handleStandardHotkey(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        if event.type == .keyDown {
            if event.isARepeat {
                return
            }
            guard keyCode == hotkey.keyCode else { return }
            guard normalizedHotkeyModifiers(event.modifierFlags) == hotkey.modifiers else { return }
            guard !hotkeyIsPressed else { return }
            hotkeyIsPressed = true
            beginRecording(source: .hotkey)
            return
        }

        if event.type == .keyUp, keyCode == hotkey.keyCode, hotkeyIsPressed {
            hotkeyIsPressed = false
            stopHotkeyRecordingIfNeeded()
        }
    }

    private func handleStandardHotkey(_ event: CGEvent, type: CGEventType) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown {
            guard keyCode == hotkey.keyCode else { return }
            guard normalizedHotkeyModifiers(event.flags) == hotkey.modifiers else { return }
            guard !hotkeyIsPressed else { return }
            hotkeyIsPressed = true
            beginRecording(source: .hotkey)
            return
        }

        if type == .keyUp, keyCode == hotkey.keyCode, hotkeyIsPressed {
            hotkeyIsPressed = false
            stopHotkeyRecordingIfNeeded()
        }
    }

    private func scheduleHotkeyRecordingStart() {
        cancelPendingHotkeyStart()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.hotkeyIsPressed, !self.hotkeyPressCancelled else { return }
            self.beginRecording(source: .hotkey)
        }
        pendingHotkeyStart = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hotkeyHoldDelay, execute: workItem)
    }

    private func cancelPendingHotkeyStart() {
        pendingHotkeyStart?.cancel()
        pendingHotkeyStart = nil
    }

    private func stopHotkeyRecordingIfNeeded() {
        guard recordingSource == .hotkey, isRecording else { return }
        stopRecordingAndTranscribe()
    }

    private func toggleRecordingFlow() {
        if isTranscribing { return }
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            beginRecording(source: .manual)
        }
    }

    private func beginRecording(source: RecordingSource) {
        if isRecording || isTranscribing {
            return
        }
        guard let selectedAudioDeviceIndex else {
            loadAudioDevices()
            hud.show(.error("还没有可用的语音输入源，请稍后再试。"), autoHideAfter: 2.0)
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        recorder.requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if !granted {
                    self.hud.show(.error("请先允许麦克风权限。"), autoHideAfter: 2.0)
                    return
                }
                do {
                    _ = try self.recorder.start(deviceIndex: selectedAudioDeviceIndex)
                    self.isRecording = true
                    self.recordingSource = source
                    self.statusItem.button?.title = "录"
                    self.hud.show(.recording)
                    writeLog("Recording started by \(source == .hotkey ? "hotkey" : "manual") on device \(selectedAudioDeviceIndex)")
                } catch {
                    self.recordingSource = nil
                    self.statusItem.button?.title = "语"
                    self.hud.show(.error(userFacingErrorMessage(from: error.localizedDescription, fallback: "录音没能开始，请再试一次。")), autoHideAfter: 2.0)
                    writeLog("Recording failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopRecordingAndTranscribe() {
        let audioURL: URL
        do {
            audioURL = try recorder.stop()
        } catch {
            isRecording = false
            recordingSource = nil
            statusItem.button?.title = "语"
            hud.show(.error(userFacingErrorMessage(from: error.localizedDescription, fallback: "录音结束失败，请再试一次。")), autoHideAfter: 2.0)
            writeLog("Recording stop failed: \(error.localizedDescription)")
            return
        }
        isRecording = false
        recordingSource = nil
        isTranscribing = true
        statusItem.button?.title = "转"
        hud.show(.transcribing)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.intValue ?? 0
        writeLog("Recording stopped: \(audioURL.path) size=\(fileSize)")
        runTranscription(for: audioURL)
    }

    private func runTranscription(for audioURL: URL) {
        guard
            let helper = Bundle.main.path(forResource: "voice_input_transcribe_cli", ofType: "py"),
            let python = pythonExecutablePath()
        else {
            finishWithError("没有找到本地转写环境。")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [
            helper,
            "--audio",
            audioURL.path,
            "--model",
            selectedModel.rawValue,
            "--language",
            "zh",
            "--task",
            selectedOutputMode.cliTask,
            "--english-style",
            selectedOutputMode.englishStyle,
            "--script",
            selectedOutputMode.usesChineseScript ? selectedOutputScript.rawValue : "original",
            "--polish",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        transcriptionTask = task

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try task.run()
                task.waitUntilExit()
                let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                try? FileManager.default.removeItem(at: audioURL)
                guard let data = output.data(using: .utf8),
                      let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data) else {
                    DispatchQueue.main.async {
                        self.finishWithError(errOutput.isEmpty ? "转写输出不可解析。" : errOutput)
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.finishTranscription(result)
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishWithError(error.localizedDescription)
                }
            }
        }
    }

    private func finishTranscription(_ result: TranscriptionResult) {
        isTranscribing = false
        statusItem.button?.title = "语"
        if let error = result.error, !error.isEmpty {
            finishWithError(error)
            return
        }
        let text = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            finishWithError("没有听清楚，这次没出字。")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        autoFill(text: text)
    }

    private func autoFill(text: String) {
        guard let targetApp, targetApp.bundleIdentifier != bundleIdentifier else {
            statusItem.button?.title = "语"
            hud.show(.success(text), autoHideAfter: 2.0)
            return
        }

        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            statusItem.button?.title = "语"
            hud.show(.error("请允许“辅助功能”后再试自动填入。"), autoHideAfter: 2.0)
            return
        }

        _ = targetApp.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            guard
                let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
                let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
            else {
                self.hud.show(.success(text), autoHideAfter: 2.0)
                return
            }
            vDown.flags = .maskCommand
            vUp.flags = .maskCommand
            vDown.post(tap: .cghidEventTap)
            vUp.post(tap: .cghidEventTap)
            self.statusItem.button?.title = "语"
            self.hud.show(.success(text), autoHideAfter: 1.8)
            writeLog("Text pasted back to target app")
        }
    }

    private func finishWithError(_ message: String) {
        isRecording = false
        isTranscribing = false
        recordingSource = nil
        statusItem.button?.title = "语"
        hud.show(.error(userFacingErrorMessage(from: message)), autoHideAfter: 2.4)
        writeLog("Error: \(message)")
    }

    private func pythonExecutablePath() -> String? {
        discoverBackendPythonExecutable(from: Bundle.main.infoDictionary)
    }

    private func audioHelperPath() -> String? {
        discoverHelperScript(named: "voice_input_audio_cli")
    }

    private func showPermissionAlertIfNeeded() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要打开热键权限"
            alert.informativeText = "热键可以使用“辅助功能”或“输入监控”其中任意一种权限。自动填入仍然建议打开“辅助功能”。我已经帮你打开系统设置。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            self.hud.show(.error("先打开辅助功能或输入监控，再重新打开 app。"), autoHideAfter: 2.4)
        }
    }

    private func openPrivacyPane(anchor: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["x-apple.systempreferences:com.apple.preference.security?\(anchor)"]
        try? task.run()
    }

    @objc private func toggleFromMenu() {
        toggleRecordingFlow()
    }

    @objc private func openHotkeySettings() {
        if settingsController == nil {
            settingsController = HotkeySettingsController(
                hotkey: hotkey,
                onSave: { [weak self] hotkey in
                    guard let self else { return }
                    self.cancelPendingHotkeyStart()
                    self.hotkeyIsPressed = false
                    self.hotkeyPressCancelled = false
                    self.hotkey = hotkey
                    self.hotkey.save()
                    self.refreshHotkeyUI()
                    writeLog("Hotkey updated to \(hotkey.displayString)")
                },
                onCaptureStateChange: { [weak self] isCapturing in
                    self?.isCapturingHotkey = isCapturing
                }
            )
        }
        settingsController?.show()
    }

    @objc private func recheckHotkeyPermission() {
        refreshHotkeyPermissionState(promptIfMissing: true)
        if globalMonitor == nil {
            hud.show(.error("热键还没启用，请先打开辅助功能。"), autoHideAfter: 2.0)
        } else {
            hud.show(.success("热键已经可以用了"), autoHideAfter: 1.6)
        }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            refreshHotkeyPermissionState(promptIfMissing: false)
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        toggleRecordingFlow()
    }

    @objc private func openAccessibility() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    @objc private func openInputMonitoring() {
        openPrivacyPane(anchor: "Privacy_ListenEvent")
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let model = TranscriptionModel(rawValue: rawValue) else {
            return
        }
        selectedModel = model
        selectedModel.save()
        refreshModelMenu()
        hud.show(.success("识别模型已切到\(model.title)"), autoHideAfter: 1.4)
    }

    @objc private func selectAudioDevice(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        selectedAudioDeviceIndex = index
        saveSelectedAudioDeviceIndex(index)
        refreshAudioSourceMenu()
        if let device = availableAudioDevices.first(where: { $0.index == index }) {
            hud.show(.success("输入源已切到\(device.name)"), autoHideAfter: 1.6)
        }
    }

    @objc private func selectOutputMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let mode = OutputMode(rawValue: rawValue) else {
            return
        }
        selectedOutputMode = mode
        selectedOutputMode.save()
        refreshOutputModeMenu()
        refreshOutputScriptMenu()
        hud.show(.success("输出模式已切到\(mode.title)"), autoHideAfter: 1.4)
    }

    @objc private func selectOutputScript(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let script = ChineseOutputScript(rawValue: rawValue) else {
            return
        }
        selectedOutputScript = script
        selectedOutputScript.save()
        refreshOutputScriptMenu()
        hud.show(.success("文字输出已切到\(script.title)"), autoHideAfter: 1.4)
    }

    @objc private func refreshAudioDevicesFromMenu() {
        loadAudioDevices()
        hud.show(.success("正在刷新输入源"), autoHideAfter: 1.2)
    }

    @objc private func openCustomDictionary() {
        let path = customDictionaryPath()
        let url = URL(fileURLWithPath: path)
        if let textEditURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEditURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        hud.show(.success("已打开自定义词库"), autoHideAfter: 1.2)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

private let app = NSApplication.shared
private let delegate = VoiceInputAppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
