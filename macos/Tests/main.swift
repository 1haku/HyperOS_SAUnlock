import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message) }
}

@discardableResult
func expectError(_ fragment: String, _ body: () throws -> Void) throws -> String {
    do { try body() }
    catch {
        let message = String(describing: error)
        try check(fragment.isEmpty || message.contains(fragment), "Expected '\(fragment)', got: \(message)")
        return message
    }
    throw TestFailure("Expected an error containing '\(fragment)'")
}

let visibleKey = "system/5g_network_mode_selection_visiable"
let disabledKey = "system/5g_sa_mode_disabled"
let modeKey = "global/fiveg_network_mode"
let dualKey = "global/dual_sa_enabled"

final class FakeADB {
    var enabled = false
    var enabledSlot1 = false
    var dataSlot = 0
    var settings: [String: String] = [:]
    var devices = "TEST\tdevice\n"
    var stateOutput: String?
    var commands: [[String]] = []
    var intercept: (([String]) throws -> CommandResult?)?

    func run(_ args: [String]) throws -> CommandResult {
        commands.append(args)
        if let result = try intercept?(args) { return result }
        func ok(_ output: String = "") -> CommandResult {
            CommandResult(status: 0, stdout: output, stderr: "")
        }
        if args == ["devices"] { return ok("List of devices attached\n" + devices) }
        guard args.count >= 4, args[0] == "-s", devices.hasPrefix(args[1] + "\t") else {
            throw TestFailure("Unexpected ADB command: \(args)")
        }
        let command = Array(args.dropFirst(2))
        if command[0] == "push" { return ok() }
        if command.count == 2, command[0] == "shell", command[1].contains("app_process") {
            let words = command[1].split(separator: " ")
            let action = words[words.count - 2]
            let slot = Int(words.last!)!
            if action == "state" {
                return ok(stateOutput ?? "STATE slot=\(slot)\nSTATE isUserFiveGSaEnabled=\(slot == 0 ? enabled : enabledSlot1)\nSTATE fiveGNetworkMode=null\n")
            }
            guard action == "enable-sa" || action == "disable-sa" else {
                throw TestFailure("Unexpected probe action: \(action)")
            }
            let value = action == "enable-sa"
            if slot == 0 { enabled = value } else { enabledSlot1 = value }
            settings[slot == dataSlot ? modeKey : dualKey] = value ? "2" : "0"
            return ok()
        }
        if command.starts(with: ["shell", "getprop"]) { return ok(command.last == "persist.security.adbinput" ? "1" : (enabled ? "1" : "0")) }
        if command.count >= 5, command.starts(with: ["shell", "settings"]) {
            let key = command[3] + "/" + command[4]
            switch command[2] {
            case "get": return ok((settings[key] ?? "null") + "\n")
            case "put": settings[key] = command[5]
            case "delete": settings[key] = nil
            default: throw TestFailure("Unexpected settings command: \(command)")
            }
            return ok()
        }
        throw TestFailure("Unexpected ADB command: \(args)")
    }

    var writes: [[String]] {
        commands.filter { args in
            args.contains("put") || args.contains("delete") ||
                args.contains(where: { $0.contains("SaProbe enable-sa ") || $0.contains("SaProbe disable-sa ") })
        }
    }
}

final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sa-unlock-tests-" + UUID().uuidString)
    let adb = FakeADB()
    let slot: Int
    var backup: URL { directory.appendingPathComponent("devices/54455354/slot-\(slot)/backup.json") }
    var recovery: URL { backup.deletingLastPathComponent().appendingPathComponent("recovery.json") }
    var tool: ADBTool!

    init(slot: Int = 0) throws {
        self.slot = slot
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tool = try ADBTool(slot: slot, executablePath: "/mock/adb", probeResourceURL: directory.appendingPathComponent("probe.jar"),
                           backupURL: directory.appendingPathComponent("backup.json"), command: adb.run)
    }

    func saveOriginal(enabled: Bool = false, serial: String = "TEST") throws {
        let data = try JSONSerialization.data(withJSONObject: ["serial": serial, "savedAt": "test", "saEnabled": enabled])
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: backup)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

let failure = CommandResult(status: 1, stdout: "", stderr: "Injected failure")
var passed = 0
var failed = 0
func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passed += 1
        print("PASS \(name)")
    } catch {
        failed += 1
        print("FAIL \(name): \(error)")
    }
}

test("unlock saves original state and restore removes previously unset keys") {
    let f = try Fixture()
    _ = try f.tool.unlockWithBackup()
    try check(f.adb.enabled && f.adb.settings[visibleKey] == "1" && f.adb.settings[disabledKey] == "0", "Unlock state")
    try check(FileManager.default.fileExists(atPath: f.backup.path), "Missing original backup")
    try check(!FileManager.default.fileExists(atPath: f.recovery.path), "Stale recovery")
    _ = try f.tool.restore()
    try check(!f.adb.enabled && f.adb.settings.isEmpty, "Original state not restored")
    try check(FileManager.default.fileExists(atPath: f.backup.path), "Original backup removed")
}

for slot in [0, 1] {
    for dataSlot in [0, 1] {
        test("slot \(slot), default data slot \(dataSlot): enable and restore") {
            let f = try Fixture(slot: slot)
            f.adb.dataSlot = dataSlot
            f.adb.settings = [modeKey: "8", dualKey: "9"]
            let before = f.adb.settings
            _ = try f.tool.unlockWithBackup()
            try check(f.adb.enabled == (slot == 0) && f.adb.enabledSlot1 == (slot == 1), "Wrong slot enabled")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: f.backup)) as! [String: Any]
            try check(saved["slot"] as? Int == slot && saved["formatVersion"] as? Int == 2, "Missing slot metadata")
            _ = try f.tool.restore()
            try check(!f.adb.enabled && !f.adb.enabledSlot1 && f.adb.settings == before, "Slot or settings not restored")
        }
    }
}

test("legacy backup cannot enable or restore slot 1") {
    let f = try Fixture(slot: 1)
    try f.saveOriginal()
    try expectError("backup targets SIM 1") { _ = try f.tool.unlockWithBackup() }
    try expectError("backup targets SIM 1") { _ = try f.tool.restore() }
    try check(f.adb.writes.isEmpty, "Wrong-slot mutation")
}

test("legacy restore does not delete the unrecorded secondary setting") {
    let f = try Fixture()
    try f.saveOriginal()
    f.adb.settings[dualKey] = "7"
    _ = try f.tool.restore()
    try check(f.adb.settings == [dualKey: "7"], "Legacy restore altered secondary setting")
}

test("wrong slot in probe output cannot be used for backup") {
    let f = try Fixture(slot: 1)
    f.adb.stateOutput = "STATE slot=0\nSTATE isUserFiveGSaEnabled=false\n"
    try expectError("") { _ = try f.tool.unlockWithBackup() }
    try check(f.adb.writes.isEmpty && !FileManager.default.fileExists(atPath: f.backup.path), "Accepted wrong-slot state")
}

test("slot 1 failure restores both original mode settings") {
    let f = try Fixture(slot: 1)
    f.adb.settings = [modeKey: "8", dualKey: "9"]
    let before = f.adb.settings
    f.adb.intercept = { args in args.last?.hasSuffix("enable-sa 1") == true ? failure : nil }
    try expectError("Restored the state from before this attempt") { _ = try f.tool.unlockWithBackup() }
    try check(!f.adb.enabledSlot1 && f.adb.settings == before, "Secondary-slot rollback failed")
}

test("repeated unlock failure rolls back to this attempt, preserving original backup") {
    let f = try Fixture()
    try f.saveOriginal()
    let original = try Data(contentsOf: f.backup)
    f.adb.enabled = true
    f.adb.settings = [visibleKey: "7", disabledKey: "8", modeKey: "9"]
    let before = f.adb.settings
    var injected = false
    f.adb.intercept = { args in
        if !injected && args.contains("put") && args.contains("5g_sa_mode_disabled") {
            injected = true
            return failure
        }
        return nil
    }
    try expectError("Restored the state from before this attempt") { _ = try f.tool.unlockWithBackup() }
    try check(f.adb.enabled && f.adb.settings == before, "Restored historical state instead of attempt state")
    let retained = try Data(contentsOf: f.backup)
    try check(retained == original, "Original backup changed")
}

test("first unlock failure restores disabled state") {
    let f = try Fixture()
    f.adb.intercept = { args in args.last?.hasSuffix("enable-sa 0") == true ? failure : nil }
    try expectError("Restored the state from before this attempt") { _ = try f.tool.unlockWithBackup() }
    try check(!f.adb.enabled && f.adb.settings.isEmpty, "Partial settings left behind")
}

test("failed automatic rollback remains recoverable after reopening") {
    let f = try Fixture()
    try f.saveOriginal()
    f.adb.enabled = true
    f.adb.settings = [visibleKey: "7", disabledKey: "8", modeKey: "9"]
    let before = f.adb.settings
    f.adb.intercept = { args in
        if args.last?.hasSuffix("enable-sa 0") == true { f.adb.enabled = false; return failure }
        return nil
    }
    let message = try expectError("Automatic rollback also failed") { _ = try f.tool.unlockWithBackup() }
    try check(message.contains("Verified:"), "Missing per-item verification")
    try check(f.adb.settings == before, "Binder failure skipped setting restoration")
    try check(FileManager.default.fileExists(atPath: f.recovery.path), "Recovery snapshot lost")
    try expectError("Click Restore first") { _ = try f.tool.unlockWithBackup() }
    f.adb.intercept = nil
    let reopened = try ADBTool(slot: 0, executablePath: "/mock/adb", probeResourceURL: f.directory.appendingPathComponent("probe.jar"),
                               backupURL: f.directory.appendingPathComponent("backup.json"), command: f.adb.run)
    let status = try reopened.statusSummary()
    try check(status.contains("Recovery pending"), "Pending recovery not displayed")
    _ = try reopened.restore()
    try check(f.adb.enabled && f.adb.settings == before, "Pending snapshot not used")
    try check(!FileManager.default.fileExists(atPath: f.recovery.path), "Recovery not cleared")
    _ = try reopened.restore()
    try check(!f.adb.enabled && f.adb.settings.isEmpty, "Original backup no longer usable")
}

test("restore continues writes and reads after individual failures") {
    let f = try Fixture()
    try f.saveOriginal()
    f.adb.enabled = true
    f.adb.settings = [visibleKey: "1", disabledKey: "0", modeKey: "2"]
    f.adb.intercept = { args in
        if args.contains("delete") && args.contains("5g_sa_mode_disabled") { return failure }
        if args.contains("get") && args.contains("5g_network_mode_selection_visiable") { return failure }
        return nil
    }
    let message = try expectError("Restore incomplete") { _ = try f.tool.restore() }
    try check(f.adb.settings[modeKey] == nil && f.adb.settings[visibleKey] == nil, "Later settings skipped")
    try check(message.contains("global/fiveg_network_mode") && message.contains("verification"), "Missing verification details")
    try check(f.adb.commands.contains { $0.contains("get") && $0.contains("fiveg_network_mode") }, "Later verification skipped")
    f.adb.intercept = nil
    _ = try f.tool.restore()
    try check(!f.adb.enabled && f.adb.settings.isEmpty, "Retry failed")
}

for output in ["STATE isUserFiveGSaEnabled=unavailable\n", "STATE fiveGNetworkMode=null\n",
               "STATE isUserFiveGSaEnabled=STATE isUserFiveGSaEnabled=true\n",
               "STATE isUserFiveGSaEnabled=false\nSTATE isUserFiveGSaEnabled=true\n"] {
    test("invalid, missing or duplicate state cannot create a backup: \(output.debugDescription)") {
        let f = try Fixture()
        f.adb.stateOutput = output
        try expectError("state") { _ = try f.tool.unlockWithBackup() }
        try check(f.adb.writes.isEmpty, "Mutated phone after invalid state")
        try check(!FileManager.default.fileExists(atPath: f.backup.path), "Invalid state backed up")
    }
}

test("stderr cannot supply the authoritative SA state") {
    let f = try Fixture()
    f.adb.intercept = { args in
        args.last?.hasSuffix("SaProbe state 0") == true
            ? CommandResult(status: 0, stdout: "", stderr: "STATE isUserFiveGSaEnabled=false\n") : nil
    }
    try expectError("Could not parse") { _ = try f.tool.unlockWithBackup() }
    try check(f.adb.writes.isEmpty, "Accepted state from stderr")
}

test("successful exit without actual state change triggers rollback") {
    let f = try Fixture()
    f.adb.intercept = { args in
        args.last?.hasSuffix("enable-sa 0") == true ? CommandResult(status: 0, stdout: "ok", stderr: "") : nil
    }
    try expectError("read-back state is unexpected") { _ = try f.tool.unlockWithBackup() }
    try check(!f.adb.enabled && f.adb.settings.isEmpty, "Failed read-back left partial state")
}

test("backup write failure prevents device changes") {
    let f = try Fixture()
    let notDirectory = f.directory.appendingPathComponent("not-a-directory")
    try Data().write(to: notDirectory)
    let tool = try ADBTool(slot: 0, executablePath: "/mock/adb", probeResourceURL: f.directory.appendingPathComponent("probe.jar"),
                           backupURL: notDirectory.appendingPathComponent("backup.json"), command: f.adb.run)
    try expectError("Could not save the backup") { _ = try tool.unlockWithBackup() }
    try check(f.adb.writes.isEmpty, "Wrote to device without a backup")
}

test("permission preflight explains security debugging without writes or snapshots") {
    let f = try Fixture()
    f.adb.intercept = { args in args.last == "persist.security.adbinput" ? CommandResult(status: 0, stdout: "0", stderr: "") : nil }
    try expectError("USB debugging (Security settings)") { _ = try f.tool.unlockWithBackup() }
    try check(f.adb.writes.isEmpty && !FileManager.default.fileExists(atPath: f.backup.path), "Permission failure mutated state")
}

test("permission exception with zero exit status is actionable and rollback skips unchanged values") {
    let f = try Fixture()
    f.adb.intercept = { args in
        if args.contains("put") || args.contains("delete") {
            return CommandResult(status: 0, stdout: "java.lang.SecurityException: android.permission.WRITE_SETTINGS", stderr: "")
        }
        return nil
    }
    let message = try expectError("USB debugging (Security settings)") { _ = try f.tool.unlockWithBackup() }
    try check(message.contains("Restored the state") && !message.contains("rollback also failed"), "False recovery failure")
    try check(f.adb.writes.count == 1 && !FileManager.default.fileExists(atPath: f.recovery.path), "Unnecessary rollback writes")
}

test("different device and slot backups coexist with a legacy backup") {
    let f = try Fixture()
    let legacy = f.directory.appendingPathComponent("backup.json")
    try JSONSerialization.data(withJSONObject: ["serial": "OTHER", "savedAt": "old", "saEnabled": false]).write(to: legacy)
    _ = try f.tool.unlockWithBackup()
    let first = try Data(contentsOf: f.backup)
    let second = try ADBTool(slot: 1, executablePath: "/mock/adb", probeResourceURL: f.directory.appendingPathComponent("probe.jar"), backupURL: legacy, command: f.adb.run)
    _ = try second.unlockWithBackup()
    let retained = try Data(contentsOf: f.backup)
    try check(retained == first, "Slot 0 backup overwritten")
    try check(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("devices/4f54484552/slot-0/backup.json").path), "Legacy device backup lost")
    _ = try second.restore()
    _ = try f.tool.restore()
    try check(!f.adb.enabled && !f.adb.enabledSlot1 && f.adb.settings.isEmpty, "Reverse slot restore failed")
}

test("pending recovery blocks the other slot on the same phone only") {
    let f = try Fixture()
    try f.saveOriginal()
    try FileManager.default.copyItem(at: f.backup, to: f.recovery)
    let second = try ADBTool(slot: 1, executablePath: "/mock/adb", probeResourceURL: f.directory.appendingPathComponent("probe.jar"), backupURL: f.directory.appendingPathComponent("backup.json"), command: f.adb.run)
    try expectError("pending recovery on this phone") { _ = try second.unlockWithBackup() }
    try check(f.adb.writes.isEmpty, "Other slot modified during recovery")
    f.adb.devices = "OTHER\tdevice\n"
    _ = try second.unlockWithBackup()
}

test("switching connected phones selects independent backups") {
    let f = try Fixture()
    _ = try f.tool.unlockWithBackup()
    let first = try Data(contentsOf: f.backup)
    f.adb.devices = "OTHER\tdevice\n"
    f.adb.enabled = false
    f.adb.settings = [:]
    _ = try f.tool.unlockWithBackup()
    _ = try f.tool.restore()
    try check(!f.adb.enabled && f.adb.settings.isEmpty, "Other device restore failed")
    let retained = try Data(contentsOf: f.backup)
    try check(first == retained, "First device backup overwritten")
}

test("another device's backup blocks unlock and restore") {
    let f = try Fixture()
    try f.saveOriginal(serial: "OTHER")
    try expectError("another device") { _ = try f.tool.unlockWithBackup() }
    try expectError("another device") { _ = try f.tool.restore() }
    try check(f.adb.writes.isEmpty, "Wrong-device mutation")
}

for devices in ["", "TEST\tunauthorized\n", "TEST\tdevice\nOTHER\tdevice\n"] {
    test("reject unavailable or ambiguous device: \(devices.debugDescription)") {
        let f = try Fixture()
        f.adb.devices = devices
        try expectError("") { _ = try f.tool.unlockWithBackup() }
        try check(f.adb.commands.count == 1, "Commands sent without a selected device")
    }
}

test("probe timeout follows the same rollback path") {
    let f = try Fixture()
    f.adb.intercept = { args in
        if args.last?.hasSuffix("enable-sa 0") == true { throw ProcessRunError.timedOut(30) }
        return nil
    }
    try expectError("timed out") { _ = try f.tool.unlockWithBackup() }
    try check(!f.adb.enabled && f.adb.settings.isEmpty, "Timeout rollback failed")
}

test("process runner preserves exit status and separate output streams") {
    let result = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 7"])
    try check(result.status == 7 && result.stdout == "out" && result.stderr == "err", "Lost output or exit status")
}

test("process runner handles missing executable and empty output") {
    try expectError("") {
        _ = try ProcessRunner.run(executable: "/nonexistent/sa-unlock-test-command", arguments: [])
    }
    let result = try ProcessRunner.run(executable: "/usr/bin/true", arguments: [])
    try check(result.status == 0 && result.output.isEmpty, "Unexpected empty-command result")
}

test("process runner drains simultaneous large output with bounded capture") {
    let result = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c",
        "/usr/bin/head -c 2097152 /dev/zero & /usr/bin/head -c 2097152 /dev/zero >&2 & wait"], timeout: 5)
    try check(result.status == 0, "Flood process failed")
    for output in [result.stdout, result.stderr] {
        try check(output.hasSuffix("[Output truncated]") && output.utf8.count < 1_100_000, "Output limit not enforced")
    }
}

test("process runner kills a command that ignores termination") {
    let started = ProcessInfo.processInfo.systemUptime
    try expectError("timed out") {
        _ = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
    }
    try check(ProcessInfo.processInfo.systemUptime - started < 3, "Timeout failed to bound execution")
}

test("inherited output descriptors cannot hang the runner") {
    let started = ProcessInfo.processInfo.systemUptime
    try expectError("timed out") {
        _ = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "sleep 2 & exit 0"], timeout: 0.2)
    }
    try check(ProcessInfo.processInfo.systemUptime - started < 1.5, "Waited for inherited output pipe")
}

print("\(passed) passed; \(failed) failed")
exit(failed == 0 ? 0 : 1)
