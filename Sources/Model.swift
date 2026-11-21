import SwiftUI
import AppKit
import IOKit.pwr_mgt
import UserNotifications

struct PackageFile: Identifiable, Codable, Equatable {
    var id: String { path }
    let path: String
    let size: Int64
    var added: Date? = nil
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var type: String { url.pathExtension.uppercased() }
    var exists: Bool { FileManager.default.isReadableFile(atPath: path) }
    var historyKey: String { "\(path)|\(size)" }
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    let name: String
    let path: String
    let size: Int64
    let finishedAt: Date
    let seconds: Double
    var speed: Double { seconds > 0 ? Double(size) / seconds : 0 }
    var historyKey: String { "\(path)|\(size)" }
}

enum SortOrder { case name, size, added }

final class Model: ObservableObject {
    static let shared = Model()
    // While the service waits between batches the list may change; edits apply to the next DBI session.
    static let editableStates: Set<String> = ["waiting", "handshake", "ended", "reconnecting"]
    static let linkedStates: Set<String> = ["connected", "ready", "transferring"]

    @Published var files: [PackageFile] = []
    @Published var selection: Set<String> = []
    @Published var present = false
    @Published var deviceMode = "unknown"
    @Published var workerReady = false
    @Published var active = false
    @Published var importing = false
    @Published var targeted = false
    @Published var state = "idle"
    @Published var status = "正在检查连接…"
    @Published var detail = "请用 USB 数据线连接 Switch 与 Mac。"
    @Published var issue: String?
    @Published var currentName = ""
    @Published var sent: Int64 = 0
    @Published var total: Int64 = 0
    @Published var speed: Double = 0
    @Published var sentByFile: [String: Int64] = [:]
    @Published var completed: Set<String> = []
    @Published var sessionSent: Int64 = 0
    @Published var lastProgressAt: Date?
    @Published var batches = 0
    @Published var connectCount = 0
    @Published var logs: [String] = []
    @Published var history: [HistoryEntry] = [] { didSet { lastSent = Dictionary(history.map { ($0.historyKey, $0.finishedAt) }, uniquingKeysWith: max) } }
    @Published private(set) var lastSent: [String: Date] = [:]
    @Published var historyQuery = ""
    @Published var showHelp = false
    @Published var showLogs = false
    @Published var showHistory = false

    @Published var keepServing: Bool { didSet { defaults.set(keepServing, forKey: "keepServing") } }
    @Published var notifyEnabled: Bool { didSet { defaults.set(notifyEnabled, forKey: "notifyEnabled") } }
    @Published var menuBarEnabled: Bool { didSet { defaults.set(menuBarEnabled, forKey: "menuBarEnabled") } }
    @Published var preventSleepEnabled: Bool { didSet { defaults.set(preventSleepEnabled, forKey: "preventSleepEnabled") } }

    private let defaults = UserDefaults.standard
    private var sessionStartedAt: Date?
    private var fileStartedAt: [String: Date] = [:]
    private var process: Process?
    private var input: Pipe?
    private var reader = Data()
    private var terminating = false
    private var assertion: IOPMAssertionID = 0
    private var preventSleep = false
    private var askedNotificationPermission = false
    private let storeURL: URL
    private let historyURL: URL
    private let logURL: URL
    private let dateFormatter: DateFormatter = {
        let result = DateFormatter(); result.dateFormat = "HH:mm:ss"; return result
    }()

    init() {
        defaults.register(defaults: ["keepServing": true, "notifyEnabled": true, "menuBarEnabled": true, "preventSleepEnabled": true])
        keepServing = defaults.bool(forKey: "keepServing")
        notifyEnabled = defaults.bool(forKey: "notifyEnabled")
        menuBarEnabled = defaults.bool(forKey: "menuBarEnabled")
        preventSleepEnabled = defaults.bool(forKey: "preventSleepEnabled")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwitchTransfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("files.json")
        historyURL = support.appendingPathComponent("history.json")
        logURL = support.appendingPathComponent("last-session.log")
        if let data = try? Data(contentsOf: storeURL), let saved = try? JSONDecoder().decode([PackageFile].self, from: data) {
            files = saved
        }
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = saved
            lastSent = Dictionary(saved.map { ($0.historyKey, $0.finishedAt) }, uniquingKeysWith: max)
        }
        try? Data().write(to: logURL, options: .atomic)
        log("应用已启动。版本 \(appVersion)（\(appBuild)）")
        if files.contains(where: { !$0.exists }) {
            issue = "部分文件已移动或删除，请移除标红的项目，再重新添加。"
        }
        launchWorker()
    }

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    var progress: Double { total > 0 ? min(1, Double(sent) / Double(total)) : 0 }
    var canStart: Bool { workerReady && !files.isEmpty && !active && !importing }
    var canEdit: Bool { !importing && (!active || Self.editableStates.contains(state)) }
    var linked: Bool { active && Self.linkedStates.contains(state) }
    var showsMenuBar: Bool { menuBarEnabled && active }
    var deviceLabel: String {
        if !workerReady { return "组件未就绪" }
        if linked { return "DBI 已连接" }
        if deviceMode == "mtp" { return "请切换 DBI 模式" }
        return present ? "检测到 Switch" : "未检测到 Switch"
    }
    var deviceColor: Color {
        if !workerReady || deviceMode == "error" { return .orange }
        if linked { return .green }
        return present ? accent : .secondary
    }
    var stateColor: Color {
        switch state {
        case "transferring", "connected", "ready": return accent
        case "ended": return .green
        case "reconnecting", "error": return .orange
        default: return active ? accent : .secondary
        }
    }
    var stateSymbol: String {
        switch state {
        case "connected", "ready": return "checkmark.circle.fill"
        case "transferring": return "arrow.up.circle.fill"
        case "ended": return "checkmark.seal.fill"
        case "reconnecting": return "bolt.horizontal.circle"
        case "error": return "exclamationmark.triangle.fill"
        case "stopped": return "pause.circle"
        default: return present || active ? "cable.connector" : "cable.connector.slash"
        }
    }
    var showsPercent: Bool { active && !currentName.isEmpty && Self.linkedStates.contains(state) }
    var stepsDone: Int {
        if state == "transferring" || (state == "ended" && sessionSent > 0) { return 3 }
        if linked { return 2 }
        return present ? 1 : 0
    }

    func log(_ value: String) {
        guard !value.isEmpty else { return }
        let text = "[\(dateFormatter.string(from: Date()))] \(value)"
        logs.append(text)
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
        // Bound the on-disk diagnostic log too; nothing is uploaded.
        try? logs.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }

    func save() {
        do { try JSONEncoder().encode(files).write(to: storeURL, options: .atomic) }
        catch { issue = "文件列表暂时无法保存，下次打开时可能需要重新添加。" }
    }

    func listChanged() {
        save()
        selection.formIntersection(files.map(\.id))
        if active { send(["command": "update", "paths": files.map(\.path)]) }
    }

    func saveHistory() {
        try? JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
    }

    func notify(_ title: String, _ body: String) {
        // The window already shows everything while the app is in front.
        guard notifyEnabled, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func launchWorker() {
        guard process == nil else { return }
        terminating = false; reader = Data(); workerReady = false
        status = "正在检查连接…"
        let worker = Bundle.main.resourceURL!.appendingPathComponent("backend/dbi-worker")
        let proc = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.executableURL = worker
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = stderr
        // Do not depend on Homebrew, a shell profile, or external Python.
        proc.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                DispatchQueue.main.async { self?.log("组件诊断：" + message.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil; self.workerReady = false; self.active = false; self.releaseSleep()
                NSApp.dockTile.badgeLabel = nil
                if !self.terminating {
                    self.state = "error"; self.status = "传输组件已停止"
                    self.detail = "点击“重新检查”即可重新启动组件。"
                    self.log("传输组件退出，状态码 \(proc.terminationStatus)。")
                }
            }
        }
        input = stdin; process = proc
        do { try proc.run() }
        catch {
            process = nil; state = "error"; status = "传输组件无法启动"
            detail = "请重新打开应用，或从完整安装包重新安装。"
            issue = detail; log(error.localizedDescription)
        }
    }

    func receive(_ data: Data) {
        reader.append(data)
        while let newline = reader.firstIndex(of: 10) {
            let line = Data(reader[..<newline]); reader.removeSubrange(...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(event)
        }
    }

    func handle(_ event: [String: Any]) {
        let kind = event["event"] as? String ?? ""
        let message = event["message"] as? String ?? ""
        switch kind {
        case "boot":
            workerReady = true; log("内置 USB 组件已就绪。")
        case "device":
            let wasPresent = present, previousMode = deviceMode
            present = event["present"] as? Bool ?? false
            deviceMode = event["mode"] as? String ?? "unknown"
            if !active && ["stopped", "ended"].contains(state) && (wasPresent != present || previousMode != deviceMode) { state = "idle" }
            if !active && ["idle", "error"].contains(state) {
                status = deviceMode == "mtp" ? "请切换 Switch 的连接模式" : (present ? "Switch 已识别，可以准备传输" : "先连接你的 Switch")
                detail = deviceMode == "mtp" ? "返回 DBI 主菜单，选择“从 DBIbackend 安装”。" : (present ? "添加安装包后点击“开始传输”，再到 Switch 上选择安装。" : "使用支持数据传输的 USB 线直连 Mac，然后打开 DBI 的后端安装模式。")
                if !message.isEmpty { detail = message }
            }
        case "state":
            state = event["state"] as? String ?? "idle"; detail = message
            switch state {
            case "waiting": status = batches > 0 ? "等待下一批" : "等待 Switch 连接"
            case "handshake": present = true; status = batches > 0 ? "等待下一批" : "等待 DBI 响应"
            case "connected": present = true; status = "DBI 已连接"; connectCount += 1
            case "ready": status = "请在 Switch 上开始安装"
            case "reconnecting":
                present = false; status = "连接已中断，等待重连"; speed = 0
                notify("与 Switch 的连接已中断", message)
            case "ended":
                batches += 1; speed = 0; connectCount += 1
                status = keepServing ? "第 \(batches) 批已结束" : "本次连接已结束"
                NSApp.requestUserAttention(.informationalRequest)
                notify(status, "已发送 \(completed.count) 个文件。安装结果请以 Switch 屏幕为准。")
            default: status = "准备传输"
            }
            log(message)
        case "progress":
            state = "transferring"; status = "正在向 Switch 发送文件"
            detail = "保持数据线连接，安装进度与结果请查看 Switch。"
            currentName = event["name"] as? String ?? ""
            sent = (event["sent"] as? NSNumber)?.int64Value ?? 0
            total = (event["size"] as? NSNumber)?.int64Value ?? 0
            speed = (event["speed"] as? NSNumber)?.doubleValue ?? 0
            sessionSent = (event["total_sent"] as? NSNumber)?.int64Value ?? sessionSent
            sentByFile[currentName] = sent; lastProgressAt = Date()
            if sessionStartedAt == nil { sessionStartedAt = Date() }
            if fileStartedAt[currentName] == nil { fileStartedAt[currentName] = Date() }
            NSApp.dockTile.badgeLabel = "\(Int(progress * 100))%"
        case "file_done":
            let name = event["name"] as? String ?? ""
            let size = (event["size"] as? NSNumber)?.int64Value ?? 0
            withAnimation(motion()) { _ = completed.insert(name) }
            log("发送完成：\(name)")
            if let file = files.first(where: { $0.name == name }) {
                let started = fileStartedAt.removeValue(forKey: name) ?? Date()
                history.append(HistoryEntry(name: name, path: file.path, size: size, finishedAt: Date(), seconds: Date().timeIntervalSince(started)))
                if history.count > 1000 { history.removeFirst(history.count - 1000) }
                saveHistory()
            }
            NSApp.requestUserAttention(.informationalRequest)
            notify("文件发送完成", "\(name) · \(bytes(size))")
        case "stopped":
            active = false; releaseSleep(); speed = 0; NSApp.dockTile.badgeLabel = nil
            if let started = sessionStartedAt, sessionSent > 0 {
                log("本次共发送 \(bytes(sessionSent))，完成 \(completed.count) 个文件，用时 \(duration(Date().timeIntervalSince(started)))。")
            }
            if !["ended", "error"].contains(state) {
                state = "stopped"; status = "传输服务已停止"
                detail = "可以继续添加文件。重新开始前，请在 Switch 退出并重新进入后端安装模式。"
            }
            log("传输服务已停止。")
        case "update_error":
            issue = message; log(message)
        case "error", "fatal":
            state = "error"; status = "需要处理后再继续"; detail = message; issue = message
            active = false; releaseSleep(); NSApp.dockTile.badgeLabel = nil
            if kind == "fatal" { workerReady = false }
            log(message)
            notify("传输需要处理", message)
        case "log": log(message)
        default: break
        }
    }

    func send(_ command: [String: Any]) {
        guard let input, process?.isRunning == true else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: command); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch { issue = "无法与传输组件通信，请关闭并重新打开应用。"; log(error.localizedDescription) }
    }

    func refresh() {
        if process == nil { launchWorker() }
        else { if !active { state = "idle" }; send(["command": "probe"]) }
    }

    func choose(folder: Bool = false) {
        guard canEdit else { return }
        let panel = NSOpenPanel()
        panel.title = folder ? "选择包含安装包的文件夹" : "添加 Switch 安装包"
        panel.prompt = "添加"
        panel.message = folder ? "会自动查找文件夹及子文件夹中的 NSP、NSZ、XCI、XCZ 文件。" : "支持 NSP、NSZ、XCI、XCZ。ZIP、RAR、7Z 请先解压。"
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        guard canEdit else { issue = "Switch 正在读取文件列表，请等本批结束或停止传输后再修改。"; return }
        importing = true
        DispatchQueue.global(qos: .userInitiated).async {
            var candidates: [URL] = [], ignored = 0, archives = 0, truncated = false
            let fm = FileManager.default
            for url in urls {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                        var visited = 0
                        for case let item as URL in enumerator {
                            visited += 1
                            if visited > 100000 || candidates.count >= 5000 { truncated = true; break }
                            let attributes = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            if attributes?.isRegularFile == true && attributes?.isSymbolicLink != true { candidates.append(item) }
                        }
                    }
                } else { candidates.append(url) }
            }
            var found: [PackageFile] = []
            for url in candidates {
                if !supported.contains(url.pathExtension.lowercased()) {
                    ignored += 1
                    if ["zip", "rar", "7z"].contains(url.pathExtension.lowercased()) { archives += 1 }
                    continue
                }
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                guard !canonical.lastPathComponent.hasPrefix("."), !canonical.lastPathComponent.contains("\n"), !canonical.lastPathComponent.contains("\r"),
                      fm.isReadableFile(atPath: canonical.path),
                      let values = try? canonical.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, let size = values.fileSize, size > 0 else { ignored += 1; continue }
                found.append(PackageFile(path: canonical.path, size: Int64(size), added: Date()))
            }
            DispatchQueue.main.async {
                var duplicateNames: [String] = [], fresh: [PackageFile] = []
                for file in found {
                    if (self.files + fresh).contains(where: { $0.path == file.path }) { continue }
                    if (self.files + fresh).contains(where: { $0.name == file.name }) { duplicateNames.append(file.name); continue }
                    fresh.append(file)
                }
                withAnimation(motion()) { self.files.append(contentsOf: fresh) }
                self.importing = false
                if !fresh.isEmpty { self.listChanged() }
                var notices: [String] = []
                if archives > 0 { notices.append("已跳过 \(archives) 个压缩包。ZIP / RAR / 7Z 请先解压，再添加里面的安装包；金手指或模组压缩包不能通过此工具安装。") }
                if ignored > archives { notices.append("已跳过 \(ignored - archives) 个不支持、为空或不可读取的文件。") }
                if !duplicateNames.isEmpty { notices.append("跳过同名文件：\(duplicateNames.prefix(3).joined(separator: "、"))。请重命名后添加，避免选错。") }
                if truncated { notices.append("文件夹过大，已停止扫描。请分批选择更具体的文件夹。") }
                if fresh.isEmpty && notices.isEmpty { notices.append("没有新增文件。文件可能已经在列表中，或所选文件夹没有支持的安装包。") }
                if !fresh.isEmpty && self.active { notices.append("文件列表已更新。若 Switch 已显示旧列表，请退出后端再重新进入。") }
                withAnimation(motion()) { self.issue = notices.isEmpty ? nil : notices.joined(separator: "\n") }
                self.log("添加了 \(fresh.count) 个安装包。" + notices.joined(separator: " "))
            }
        }
    }

    func remove(_ ids: Set<String>) {
        guard canEdit, !ids.isEmpty else { return }
        withAnimation(motion()) { files.removeAll { ids.contains($0.id) } }
        listChanged()
    }

    func clear() {
        guard canEdit else { return }
        withAnimation(motion()) { files.removeAll(); issue = nil }
        listChanged()
    }

    func sort(by order: SortOrder) {
        guard canEdit else { return }
        let indexed = files.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            switch order {
            case .name:
                let result = lhs.1.name.localizedStandardCompare(rhs.1.name)
                return result == .orderedSame ? lhs.0 < rhs.0 : result == .orderedAscending
            case .size: return lhs.1.size == rhs.1.size ? lhs.0 < rhs.0 : lhs.1.size > rhs.1.size
            case .added:
                let left = lhs.1.added ?? .distantPast, right = rhs.1.added ?? .distantPast
                return left == right ? lhs.0 < rhs.0 : left < right
            }
        }.map(\.1)
        withAnimation(motion()) { files = sorted }
        listChanged()
    }

    func reveal(_ ids: Set<String>) {
        let urls = files.filter { ids.contains($0.id) }.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func copyPaths(_ ids: Set<String>) {
        let paths = files.filter { ids.contains($0.id) }.map(\.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func start() {
        guard canStart else { return }
        let invalid = files.filter { !$0.exists }
        if !invalid.isEmpty { issue = "找不到或无法读取 \(invalid.count) 个文件，请移除标红项目后重新添加。"; return }
        // Refresh sizes and verify the files did not become empty since import.
        var updated: [PackageFile] = []
        for file in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = attrs[.size] as? NSNumber, size.int64Value > 0 else {
                issue = "文件已变为空文件或无法读取：\(file.name)"; return
            }
            updated.append(PackageFile(path: file.path, size: size.int64Value, added: file.added))
        }
        files = updated; save(); issue = nil; currentName = ""; sent = 0; total = 0; speed = 0
        sentByFile = [:]; completed = []; sessionSent = 0; lastProgressAt = nil; sessionStartedAt = nil
        fileStartedAt = [:]; batches = 0
        active = true; state = "waiting"; status = "正在启动传输服务…"
        if notifyEnabled && !askedNotificationPermission {
            askedNotificationPermission = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if preventSleepEnabled, IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                      IOPMAssertionLevel(kIOPMAssertionLevelOn), "Switch USB transfer" as CFString, &assertion) == kIOReturnSuccess { preventSleep = true }
        send(["command": "start", "paths": files.map(\.path), "keep_serving": keepServing])
    }

    func stop(confirm: Bool = true) {
        if confirm && state == "transferring" {
            let alert = NSAlert(); alert.messageText = "停止当前传输？"
            alert.informativeText = "Switch 上的本次安装可能中断。重新连接后，需要在 Switch 上重新选择安装。"
            alert.addButton(withTitle: "继续传输"); alert.addButton(withTitle: "停止传输")
            if alert.runModal() != .alertSecondButtonReturn { return }
        }
        status = "正在停止…"; send(["command": "stop"])
    }

    func releaseSleep() { if preventSleep { IOPMAssertionRelease(assertion); preventSleep = false } }

    func shutdown() {
        terminating = true; send(["command": "quit"])
        try? input?.fileHandleForWriting.close(); releaseSleep()
        // EOF requests graceful shutdown; process teardown closes USB resources.
        if process?.isRunning == true { process?.terminate() }
    }

    func clearHistory() {
        let alert = NSAlert(); alert.messageText = "清空全部传输记录？"
        alert.informativeText = "只删除记录，不会删除任何文件。此操作无法撤销。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空记录")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        withAnimation(motion()) { history.removeAll() }
        saveHistory()
    }

    func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Switch传输诊断.txt"
        panel.message = "日志保存在你选择的位置，不会自动上传。"
        if panel.runModal() == .OK, let url = panel.url {
            let header = "Switch 传输助手 \(appVersion)（\(appBuild)）\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\nUSB：\(deviceLabel)\n文件数：\(files.count)\n\n"
            do { try (header + logs.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8) }
            catch { issue = "日志保存失败：\(error.localizedDescription)" }
        }
    }
}
