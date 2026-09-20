import Cocoa
import Foundation

private enum ToolError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value):
            return value
        }
    }
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var output: String {
        let standardOutput = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let standardError = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if standardOutput.isEmpty {
            return standardError
        }
        if standardError.isEmpty {
            return standardOutput
        }
        return standardOutput + "\n" + standardError
    }
}

private struct Device {
    let serial: String
    let state: String
}

private struct ProbeState {
    let saEnabled: Bool
    let networkMode: String?
}

private struct DeviceState {
    let visible: String?
    let saDisabled: String?
    let fiveGNetworkMode: String?
    let saEnabled: Bool
    let networkMode: String?
    let property: String?
    let dualSaEnabled: String?
}

private struct Backup: Codable {
    let serial: String
    let savedAt: String
    let visible: String?
    let saDisabled: String?
    let fiveGNetworkMode: String?
    let saEnabled: Bool
    let formatVersion: Int?
    let slot: Int?
    let dualSaEnabled: String?
    var deviceName: String? = nil

    var targetSlot: Int { slot ?? 0 }
}

final class ADBTool {
    private let executablePath: String
    private let probeResourceURL: URL

    private let legacyBackupURL: URL
    private var selectedBackupURL: URL?
    private let execute: ([String]) throws -> CommandResult
    private let slot: Int

    init(slot: Int, executablePath: String? = nil, probeResourceURL: URL? = nil,
         backupURL: URL? = nil,
         command: (([String]) throws -> CommandResult)? = nil) throws {
        guard slot == 0 || slot == 1 else { throw ToolError.message("Select SIM 1 (slot 0) or SIM 2 (slot 1).") }
        self.slot = slot
        guard let path = executablePath ?? Self.findADB() else {
            throw ToolError.message("adb was not found. Install Android platform-tools or place adb at /opt/homebrew/bin/adb or /usr/local/bin/adb.")
        }
        guard let probe = probeResourceURL ?? Bundle.main.url(forResource: "sa-probe", withExtension: "jar") else {
            throw ToolError.message("sa-probe.jar is missing from the app. Rebuild the app.")
        }
        self.executablePath = path
        self.probeResourceURL = probe
        self.legacyBackupURL = backupURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HyperOSSAUnlock", isDirectory: true)
            .appendingPathComponent("backup.json")
        self.execute = command ?? { arguments in
            try ProcessRunner.run(executable: path, arguments: arguments)
        }
    }

    var description: String {
        executablePath
    }

    var backupURL: URL { selectedBackupURL ?? legacyBackupURL }

    private static let permissionHint = "Settings access was denied. On the phone, open Settings > Additional settings > Developer options and enable USB debugging (Security settings), then retry. This is separate from USB debugging."

    private func selectBackup(for serial: String) throws {
        let root = legacyBackupURL.deletingLastPathComponent()
        func target(_ serial: String, _ slot: Int, _ name: String) -> URL {
            let id = serial.utf8.map { String(format: "%02x", $0) }.joined()
            return root.appendingPathComponent("devices/\(id)/slot-\(slot)/\(name)")
        }
        // Move old single-device files using their own identity, never the connected phone's.
        for name in ["backup.json", "recovery.json"] {
            let old = root.appendingPathComponent(name)
            if let saved = try loadBackup(from: old) {
                let destination = target(saved.serial, saved.targetSlot, name)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw ToolError.message("Both legacy and device-specific backups exist. Keep both files and resolve the duplicate before continuing: \(old.path)")
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: old, to: destination)
            }
        }
        selectedBackupURL = target(serial, slot, "backup.json")
    }

    private var recoveryURL: URL {
        backupURL.deletingLastPathComponent().appendingPathComponent("recovery.json")
    }

    private func requireNoOtherSlotRecovery() throws {
        let other = backupURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("slot-\(1 - slot)/recovery.json")
        if FileManager.default.fileExists(atPath: other.path) {
            throw ToolError.message("SIM \(2 - slot) has a pending recovery on this phone. Select that slot and click Restore first; some settings are shared by both slots.")
        }
    }

    func statusSummary() throws -> String {
        let device = try requireDevice()
        try selectBackup(for: device.serial)
        try pushProbe(to: device.serial)
        let state = try readState(from: device.serial)
        let backupMessage: String
        if let backup = try loadBackup() {
            backupMessage = "Backup: \(backup.savedAt), device \(shortSerial(backup.serial))"
        } else {
            backupMessage = "Backup: none"
        }
        let recoveryMessage = FileManager.default.fileExists(atPath: recoveryURL.path)
            ? "\nRecovery pending. Restore will recover the last operation." : ""
        let model = try getProperty("ro.product.model", on: device.serial) ?? "Android"
        return "Device: \(model) (\(shortSerial(device.serial)))\n" +
            "Target: SIM \(slot + 1) (slot \(slot))\n" +
            "SA user switch: \(state.saEnabled ? "Enabled" : "Disabled")\n" +
            "SA network mode: \(state.networkMode ?? "Unknown")\n" +
            "Visibility setting: \(state.visible ?? "unset")\n" +
            "SA disabled setting: \(state.saDisabled ?? "unset")\n" +
            "fiveg_network_mode: \(state.fiveGNetworkMode ?? "unset")\n" +
            "dual_sa_enabled: \(state.dualSaEnabled ?? "unset")\n" +
            "persist.radio.sa.user.enabled: \(state.property ?? "unset")\n" +
            backupMessage + recoveryMessage
    }

    func unlockWithBackup() throws -> String {
        let device = try requireDevice()
        try selectBackup(for: device.serial)
        try requireNoOtherSlotRecovery()
        guard !FileManager.default.fileExists(atPath: recoveryURL.path) else {
            throw ToolError.message("A previous operation needs recovery. Click Restore first.")
        }
        if try getProperty("persist.security.adbinput", on: device.serial) == "0" {
            throw ToolError.message(Self.permissionHint)
        }
        try pushProbe(to: device.serial)
        let before = try readState(from: device.serial)
        let existingBackup = try loadBackup()

        if let existingBackup, existingBackup.serial != device.serial {
            throw ToolError.message("The backup belongs to another device (\(shortSerial(existingBackup.serial))). Operation stopped to prevent a wrong restore. Restore that device first or move the backup file: \(backupURL.path)")
        }
        if let existingBackup { try requireMatchingSlot(existingBackup) }

        let snapshot = Backup(
            serial: device.serial,
            savedAt: Self.timestamp(),
            visible: before.visible,
            saDisabled: before.saDisabled,
            fiveGNetworkMode: before.fiveGNetworkMode,
            saEnabled: before.saEnabled,
            formatVersion: 2,
            slot: slot,
            dualSaEnabled: before.dualSaEnabled,
            deviceName: try getProperty("ro.product.model", on: device.serial)
        )
        if existingBackup == nil {
            try saveBackup(snapshot, to: backupURL)
        }
        // Preserve the state immediately before this attempt, separately from the original backup.
        try saveBackup(snapshot, to: recoveryURL)

        do {
            try putSetting(scope: "system", key: "5g_network_mode_selection_visiable", value: "1", on: device.serial)
            try putSetting(scope: "system", key: "5g_sa_mode_disabled", value: "0", on: device.serial)
            try runProbe(action: "enable-sa", on: device.serial)

            let after = try readState(from: device.serial)
            guard after.visible == "1", after.saDisabled == "0", after.saEnabled else {
                throw ToolError.message("The command returned successfully, but the read-back state is unexpected: SA=\(after.saEnabled), visible=\(after.visible ?? "unset"), disabled=\(after.saDisabled ?? "unset")")
            }

            try FileManager.default.removeItem(at: recoveryURL)
            let backupNote = existingBackup == nil ? "original state saved" : "existing backup kept"
            return "Unlock completed (\(backupNote))\n" +
                "SA user switch: Enabled\n" +
                "fiveg_network_mode: \(after.fiveGNetworkMode ?? "unset")"
        } catch {
            let failure = String(describing: error)
            do {
                try restoreCore(snapshot, on: device.serial)
                try FileManager.default.removeItem(at: recoveryURL)
            } catch let rollbackError {
                throw ToolError.message("Unlock failed: \(failure)\nAutomatic rollback also failed: \(String(describing: rollbackError))\nRecovery snapshot kept at: \(recoveryURL.path). Click Restore to retry.")
            }
            throw ToolError.message("Unlock failed: \(failure)\nRestored the state from before this attempt. The original backup is unchanged.")
        }
    }

    func restore() throws -> String {
        let device = try requireDevice()
        try selectBackup(for: device.serial)
        try requireNoOtherSlotRecovery()
        let pendingRecovery = FileManager.default.fileExists(atPath: recoveryURL.path)
        guard let backup = try loadBackup(from: pendingRecovery ? recoveryURL : backupURL) else {
            throw ToolError.message("No backup is available. Click Unlock (Backup) first.")
        }
        guard backup.serial == device.serial else {
            throw ToolError.message("The backup belongs to another device (\(shortSerial(backup.serial))); the current device is \(shortSerial(device.serial)). Operation stopped.")
        }
        try requireMatchingSlot(backup)

        try pushProbe(to: device.serial)
        try restoreCore(backup, on: device.serial)
        if pendingRecovery {
            try FileManager.default.removeItem(at: recoveryURL)
        }
        return "\(pendingRecovery ? "Recovery" : "Restore") completed\nSA user switch: \(backup.saEnabled ? "Enabled" : "Disabled")\n" +
            "Visibility setting: \(backup.visible ?? "unset")\n" +
            "SA disabled setting: \(backup.saDisabled ?? "unset")\n" +
            "Original backup kept at: \(backupURL.path)"
    }

    private func restoreCore(_ backup: Backup, on serial: String) throws {
        try requireMatchingSlot(backup)
        var errors: [String] = []
        var verified: [String] = []
        func attempt(_ label: String, _ action: () throws -> Void) {
            do { try action() }
            catch { errors.append("\(label): \(error)") }
        }

        let action = backup.saEnabled ? "enable-sa" : "disable-sa"
        attempt("SA user switch write") {
            if (try? readProbeState(on: serial).saEnabled) != backup.saEnabled {
                try runProbe(action: action, on: serial)
            }
        }
        var settings: [(String, String, String?)] = [
            ("system", "5g_network_mode_selection_visiable", backup.visible),
            ("system", "5g_sa_mode_disabled", backup.saDisabled),
            ("global", "fiveg_network_mode", backup.fiveGNetworkMode)
        ]
        if backup.formatVersion == 2 {
            settings.append(("global", "dual_sa_enabled", backup.dualSaEnabled))
        }
        for (scope, key, value) in settings {
            attempt("\(scope)/\(key) write") {
                var matches = false
                do { matches = try getSetting(scope: scope, key: key, on: serial) == value }
                catch { /* The write and final verification below still run. */ }
                if !matches { try putSetting(scope: scope, key: key, value: value, on: serial) }
            }
        }

        // Check each item independently, even when another write or read failed.
        attempt("SA user switch verification") {
            let actual = try readProbeState(on: serial).saEnabled
            guard actual == backup.saEnabled else {
                throw ToolError.message("expected \(backup.saEnabled), read \(actual)")
            }
            verified.append("SA user switch")
        }
        for (scope, key, expected) in settings {
            attempt("\(scope)/\(key) verification") {
                let actual = try getSetting(scope: scope, key: key, on: serial)
                guard actual == expected else {
                    throw ToolError.message("expected \(expected ?? "unset"), read \(actual ?? "unset")")
                }
                verified.append("\(scope)/\(key)")
            }
        }
        if verified.count != settings.count + 1 {
            throw ToolError.message("Restore incomplete.\nVerified: \(verified.isEmpty ? "none" : verified.joined(separator: ", "))\n" +
                                    errors.joined(separator: "\n"))
        }
    }

    private func readState(from serial: String) throws -> DeviceState {
        let visible = try getSetting(scope: "system", key: "5g_network_mode_selection_visiable", on: serial)
        let saDisabled = try getSetting(scope: "system", key: "5g_sa_mode_disabled", on: serial)
        let fiveGNetworkMode = try getSetting(scope: "global", key: "fiveg_network_mode", on: serial)
        let probe = try readProbeState(on: serial)
        let property = try getProperty("persist.radio.sa.user.enabled", on: serial)
        let dualSaEnabled = try getSetting(scope: "global", key: "dual_sa_enabled", on: serial)
        return DeviceState(visible: visible,
                           saDisabled: saDisabled,
                           fiveGNetworkMode: fiveGNetworkMode,
                           saEnabled: probe.saEnabled,
                           networkMode: probe.networkMode,
                           property: property,
                           dualSaEnabled: dualSaEnabled)
    }

    private func readProbeState(on serial: String) throws -> ProbeState {
        let result = try runProbe(action: "state", on: serial)
        var saEnabled: Bool?
        var networkMode: String?
        var reportedSlot: Int?
        for line in result.stdout.split(whereSeparator: { $0.isNewline }) {
            let value = String(line)
            if value.hasPrefix("STATE slot=") {
                guard reportedSlot == nil, value == "STATE slot=\(slot)" else {
                    throw ToolError.message("Unexpected or duplicate slot in state output.")
                }
                reportedSlot = slot
            } else if value.hasPrefix("STATE isUserFiveGSaEnabled=") {
                let raw = String(value.dropFirst("STATE isUserFiveGSaEnabled=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard saEnabled == nil, raw == "true" || raw == "false" else {
                    throw ToolError.message("Invalid or duplicate SA state: \(raw)")
                }
                saEnabled = raw == "true"
            } else if value.hasPrefix("STATE fiveGNetworkMode=") {
                networkMode = value.replacingOccurrences(of: "STATE fiveGNetworkMode=", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if networkMode == "null" || networkMode?.isEmpty == true {
                    networkMode = nil
                }
            }
        }
        guard let enabled = saEnabled, reportedSlot == slot else {
            throw ToolError.message("Could not parse SaProbe state output: \(result.output)")
        }
        return ProbeState(saEnabled: enabled, networkMode: networkMode)
    }

    @discardableResult
    private func runProbe(action: String, on serial: String) throws -> CommandResult {
        let command = "CLASSPATH=/data/local/tmp/sa-unlock-probe.jar app_process /system/bin SaProbe \(action) \(slot)"
        let result = try runOnDevice(serial, ["shell", command])
        guard result.status == 0 else {
            throw ToolError.message("SaProbe \(action) failed (exit code \(result.status)):\n\(result.output)")
        }
        return result
    }

    private func pushProbe(to serial: String) throws {
        let result = try runOnDevice(serial, ["push", probeResourceURL.path, "/data/local/tmp/sa-unlock-probe.jar"])
        guard result.status == 0 else {
            throw ToolError.message("Could not copy the probe to the phone:\n\(result.output)")
        }
    }

    private func getSetting(scope: String, key: String, on serial: String) throws -> String? {
        let result = try runOnDevice(serial, ["shell", "settings", "get", scope, key])
        guard result.status == 0 else {
            throw ToolError.message("Could not read \(scope)/\(key):\n\(result.output)")
        }
        return normalize(result.stdout)
    }

    private func getProperty(_ key: String, on serial: String) throws -> String? {
        let result = try runOnDevice(serial, ["shell", "getprop", key])
        guard result.status == 0 else {
            throw ToolError.message("Could not read property \(key):\n\(result.output)")
        }
        return normalize(result.stdout)
    }

    private func putSetting(scope: String, key: String, value: String?, on serial: String) throws {
        let arguments: [String]
        if let value {
            arguments = ["shell", "settings", "put", scope, key, value]
        } else {
            arguments = ["shell", "settings", "delete", scope, key]
        }
        let result = try runOnDevice(serial, arguments)
        if result.output.contains("SecurityException") &&
            (result.output.contains("WRITE_SETTINGS") || result.output.contains("WRITE_SECURE_SETTINGS")) {
            throw ToolError.message(Self.permissionHint)
        }
        guard result.status == 0 else {
            let operation = value == nil ? "delete" : "write"
            throw ToolError.message("Could not \(operation) \(scope)/\(key):\n\(result.output)")
        }
    }

    private func requireDevice() throws -> Device {
        let allDevices = try listDevices()
        let ready = allDevices.filter { $0.state == "device" }
        if ready.count == 1 {
            return ready[0]
        }
        if ready.count > 1 {
            throw ToolError.message("Multiple authorized devices were found. Leave only the target phone connected and try again.")
        }
        if let pending = allDevices.first {
            throw ToolError.message("The phone is in the \"\(pending.state)\" state. Unlock it and allow USB debugging on the phone.")
        }
        throw ToolError.message("No ADB device was found. Connect the phone by USB, keep USB debugging enabled, and use a data-capable cable.")
    }

    private func listDevices() throws -> [Device] {
        let result = try run(["devices"])
        guard result.status == 0 else {
            throw ToolError.message("adb devices failed:\n\(result.output)")
        }
        return result.stdout.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard String(line).contains("\t") else {
                return nil
            }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] != "List" else {
                return nil
            }
            return Device(serial: String(fields[0]), state: String(fields[1]))
        }
    }

    private func runOnDevice(_ serial: String, _ arguments: [String]) throws -> CommandResult {
        try run(["-s", serial] + arguments)
    }

    private func run(_ arguments: [String]) throws -> CommandResult {
        try execute(arguments)
    }

    private func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "null" ? nil : trimmed
    }

    private func requireMatchingSlot(_ backup: Backup) throws {
        guard backup.targetSlot == slot else {
            throw ToolError.message("The backup targets SIM \(backup.targetSlot + 1) (slot \(backup.targetSlot)). Select that slot to restore it, or move the original backup somewhere safe before using a different slot. Backup: \(backupURL.path)")
        }
    }

    private func loadBackup(from url: URL? = nil) throws -> Backup? {
        let source = url ?? backupURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: source)
            let backup = try JSONDecoder().decode(Backup.self, from: data)
            guard (backup.formatVersion == nil && backup.slot == nil) ||
                    (backup.formatVersion == 2 && (backup.slot == 0 || backup.slot == 1)) else {
                throw ToolError.message("Unsupported backup version or invalid slot.")
            }
            return backup
        } catch {
            throw ToolError.message("Could not read the backup file: \(source.path)\n\(String(describing: error))")
        }
    }

    private func saveBackup(_ backup: Backup, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            let data = try encoder.encode(backup)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ToolError.message("Could not save the backup: \(destination.path)\n\(String(describing: error))")
        }
    }

    private static func findADB() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [String] = []

        for variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdkRoot = environment[variable], !sdkRoot.isEmpty {
                candidates.append(URL(fileURLWithPath: sdkRoot)
                    .appendingPathComponent("platform-tools/adb")
                    .path)
            }
        }

        candidates += [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/local/bin/adb",
            homeDirectory.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path,
            homeDirectory.appendingPathComponent("Android/Sdk/platform-tools/adb").path
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathEntries {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("adb").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: Date())
    }

    private func shortSerial(_ serial: String) -> String {
        guard serial.count > 8 else { return serial }
        return String(serial.prefix(4)) + "…" + String(serial.suffix(4))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var logView: NSTextView!
    private var statusLabel: NSTextField!
    private var checkButton: NSButton!
    private var unlockButton: NSButton!
    private var restoreButton: NSButton!
    private var slotSelector: NSPopUpButton!
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        appendLog("Ready.")
    }

    @objc private func checkStatus() {
        perform { tool in
            "ADB: \(tool.description)\n\n" + (try tool.statusSummary())
        }
    }

    @objc private func unlock() {
        perform { tool in
            try tool.unlockWithBackup()
        }
    }

    @objc private func restore() {
        perform { tool in
            try tool.restore()
        }
    }

    private func perform(_ operation: @escaping (ADBTool) throws -> String) {
        guard !busy else { return }
        let slot = slotSelector.indexOfSelectedItem - 1
        guard slot == 0 || slot == 1 else {
            appendLog("Select a SIM slot first.")
            return
        }
        busy = true
        setButtonsEnabled(false)
        statusLabel.stringValue = "Running..."
        appendLog("Running...")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tool = try ADBTool(slot: slot)
                let result = try operation(tool)
                DispatchQueue.main.async {
                    self.busy = false
                    self.setButtonsEnabled(true)
                    self.statusLabel.stringValue = "Done"
                    self.appendLog(result)
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.setButtonsEnabled(true)
                    self.statusLabel.stringValue = "Failed"
                    self.appendLog("Error: \(String(describing: error))")
                }
            }
        }
    }

    private func buildWindow() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "HyperOS_SAUnlock")
        title.font = NSFont.boldSystemFont(ofSize: 20)

        statusLabel = NSTextField(labelWithString: "Not checked")
        statusLabel.textColor = .secondaryLabelColor

        slotSelector = NSPopUpButton(frame: .zero, pullsDown: false)
        slotSelector.addItems(withTitles: ["Select SIM slot", "SIM 1 (slot 0)", "SIM 2 (slot 1)"])

        checkButton = NSButton(title: "Check Status", target: self, action: #selector(checkStatus))
        unlockButton = NSButton(title: "Unlock (Backup)", target: self, action: #selector(unlock))
        restoreButton = NSButton(title: "Restore", target: self, action: #selector(restore))
        for button in [checkButton!, unlockButton!, restoreButton!] {
            button.bezelStyle = .rounded
        }

        let buttons = NSStackView(views: [checkButton, unlockButton, restoreButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        logView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 220))
        logView.isEditable = false
        logView.isSelectable = true
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.backgroundColor = NSColor.textBackgroundColor
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = logView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, slotSelector, statusLabel, buttons, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 220)
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "HyperOS_SAUnlock"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setButtonsEnabled(_ enabled: Bool) {
        slotSelector.isEnabled = enabled
        checkButton.isEnabled = enabled
        unlockButton.isEnabled = enabled
        restoreButton.isEnabled = enabled
    }

    private func appendLog(_ message: String) {
        guard logView != nil else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        logView.textStorage?.append(NSAttributedString(string: line))
        logView.scrollToEndOfDocument(nil)
    }
}

#if !TESTING
@main
struct HyperOSSAUnlockApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
#endif
