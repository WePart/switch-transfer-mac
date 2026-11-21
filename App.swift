import SwiftUI
import AppKit
import UniformTypeIdentifiers
import IOKit.pwr_mgt

private let accent = Color(red: 0.12, green: 0.39, blue: 0.87)
private let supported: Set<String> = ["nsp", "nsz", "xci", "xcz"]
private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
private let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

struct PackageFile: Identifiable, Codable, Equatable {
    var id: String { path }
    let path: String
    let size: Int64
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var type: String { url.pathExtension.uppercased() }
    var exists: Bool { FileManager.default.isReadableFile(atPath: path) }
}

func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

func duration(_ seconds: Double) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
    formatter.unitsStyle = .positional; formatter.zeroFormattingBehavior = .pad
    return formatter.string(from: max(0, seconds.rounded())) ?? "--"
}

final class Model: ObservableObject {
    static let shared = Model()
    @Published var files: [PackageFile] = []
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
    private var sessionStartedAt: Date?
    @Published var logs: [String] = []
    @Published var showHelp = false
    @Published var showLogs = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errorPipe: Pipe?
    private var reader = Data()
    private var terminating = false
    private var assertion: IOPMAssertionID = 0
    private var preventSleep = false
    private let storeURL: URL
    private let logURL: URL
    private let dateFormatter: DateFormatter = {
        let result = DateFormatter(); result.dateFormat = "HH:mm:ss"; return result
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwitchTransfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("files.json")
        logURL = support.appendingPathComponent("last-session.log")
        if let data = try? Data(contentsOf: storeURL), let saved = try? JSONDecoder().decode([PackageFile].self, from: data) {
            files = saved
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
    var deviceLabel: String {
        if !workerReady { return "组件未就绪" }
        if active && ["connected", "ready", "transferring"].contains(state) { return "DBI 已连接" }
        if deviceMode == "mtp" { return "请切换 DBI 模式" }
        return present ? "检测到 Switch" : "未检测到 Switch"
    }
    var deviceColor: Color {
        if !workerReady || deviceMode == "error" { return .orange }
        if active && ["connected", "ready", "transferring"].contains(state) { return .green }
        return present ? accent : .secondary
    }

    func log(_ value: String) {
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
        input = stdin; output = stdout; errorPipe = stderr; process = proc
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
            case "waiting": status = "等待 Switch 连接"
            case "handshake": present = true; status = "等待 DBI 响应"
            case "connected": present = true; status = "DBI 已连接"
            case "ready": status = "请在 Switch 上开始安装"
            case "reconnecting": present = false; status = "连接已中断，等待重连"; speed = 0
            case "ended":
                status = "本次连接已结束"; speed = 0
                NSApp.requestUserAttention(.informationalRequest)
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
            NSApp.dockTile.badgeLabel = "\(Int(progress * 100))%"
        case "file_done":
            let name = event["name"] as? String ?? ""
            completed.insert(name); log("发送完成：\(name)")
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
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
        case "error", "fatal":
            state = "error"; status = "需要处理后再继续"; detail = message; issue = message
            active = false; releaseSleep(); NSApp.dockTile.badgeLabel = nil
            if kind == "fatal" { workerReady = false }
            log(message)
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
        guard !active, !importing else { return }
        let panel = NSOpenPanel()
        panel.title = folder ? "选择包含安装包的文件夹" : "添加 Switch 安装包"
        panel.prompt = "添加"
        panel.message = folder ? "会自动查找文件夹及子文件夹中的 NSP、NSZ、XCI、XCZ 文件。" : "支持 NSP、NSZ、XCI、XCZ。ZIP、RAR、7Z 请先解压。"
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        guard !active, !importing else { issue = "请先停止传输，再修改文件列表。"; return }
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
                found.append(PackageFile(path: canonical.path, size: Int64(size)))
            }
            DispatchQueue.main.async {
                var duplicateNames: [String] = [], added = 0
                for file in found {
                    if self.files.contains(where: { $0.path == file.path }) { continue }
                    if self.files.contains(where: { $0.name == file.name }) { duplicateNames.append(file.name); continue }
                    self.files.append(file); added += 1
                }
                self.importing = false; self.save()
                var notices: [String] = []
                if archives > 0 { notices.append("已跳过 \(archives) 个压缩包。ZIP / RAR / 7Z 请先解压，再添加里面的安装包；金手指或模组压缩包不能通过此工具安装。") }
                if ignored > archives { notices.append("已跳过 \(ignored - archives) 个不支持、为空或不可读取的文件。") }
                if !duplicateNames.isEmpty { notices.append("跳过同名文件：\(duplicateNames.prefix(3).joined(separator: "、"))。请重命名后添加，避免选错。") }
                if truncated { notices.append("文件夹过大，已停止扫描。请分批选择更具体的文件夹。") }
                if added == 0 && notices.isEmpty { notices.append("没有新增文件。文件可能已经在列表中，或所选文件夹没有支持的安装包。") }
                self.issue = notices.isEmpty ? nil : notices.joined(separator: "\n")
                self.log("添加了 \(added) 个安装包。" + notices.joined(separator: " "))
            }
        }
    }

    func remove(_ file: PackageFile) { guard !active, !importing else { return }; files.removeAll { $0.id == file.id }; save() }
    func clear() { guard !active, !importing else { return }; files.removeAll(); issue = nil; save() }

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
            updated.append(PackageFile(path: file.path, size: size.int64Value))
        }
        files = updated; save(); issue = nil; currentName = ""; sent = 0; total = 0; speed = 0
        sentByFile = [:]; completed = []; sessionSent = 0; lastProgressAt = nil; sessionStartedAt = nil
        active = true; state = "waiting"; status = "正在启动传输服务…"
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                      IOPMAssertionLevel(kIOPMAssertionLevelOn), "Switch USB transfer" as CFString, &assertion) == kIOReturnSuccess { preventSleep = true }
        send(["command": "start", "paths": files.map(\.path)])
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = Model.shared
        if model.active {
            let alert = NSAlert(); alert.messageText = "传输服务还在运行，确定退出？"
            alert.informativeText = "退出会断开与 Switch 的连接。"
            alert.addButton(withTitle: "留在应用"); alert.addButton(withTitle: "退出")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        model.shutdown(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) { Model.shared.add(urls) }
}

@main struct SwitchTransferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = Model.shared
    var body: some Scene {
        Window("Switch 传输助手", id: "main") {
            MainView().environmentObject(model)
                .frame(minWidth: 920, minHeight: 700)
                .onOpenURL { model.add([$0]) }
        }
        .defaultSize(width: 1100, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加安装包…") { model.choose() }.keyboardShortcut("o").disabled(model.active || model.importing)
                Button("添加文件夹…") { model.choose(folder: true) }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.active || model.importing)
            }
            CommandGroup(replacing: .help) {
                Button("连接与使用帮助") { model.showHelp = true }
                Button("查看诊断日志") { model.showLogs = true }
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 Switch 传输助手") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Switch 传输助手", .applicationVersion: appVersion, .version: appBuild, .credits: NSAttributedString(string: "适用于 Apple 芯片 Mac 的 DBI USB 传输工具。\n基于 GuangLun2000/DBI-backend-for-switch 与 DBI0 协议。\n原项目：CAI (Hanlin Cai) / dev#Mikami；DBI：duckbill。\n本工具不代表 Nintendo 官方。")])
                }
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var m: Model
        var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 24) {
                guide.frame(width: 235)
                VStack(alignment: .leading, spacing: 16) {
                    if let issue = m.issue { notice(issue) }
                    fileCard
                    transferCard
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }.padding(24)
            Divider()
            HStack {
                Label("仅通过 USB 传输 · 文件保留在你的 Mac", systemImage: "lock.shield")
                Spacer()
                Button("诊断日志") { m.showLogs = true }.buttonStyle(.plain)
                Text(appVersion).foregroundStyle(.tertiary)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .sheet(isPresented: $m.showHelp) { HelpView().environmentObject(m) }
        .sheet(isPresented: $m.showLogs) { LogView().environmentObject(m) }
    }

    var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.plus").font(.system(size: 25, weight: .medium)).foregroundStyle(.white)
                .frame(width: 52, height: 52).background(accent.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("Switch 传输助手").font(.system(size: 23, weight: .semibold))
                Text("三步，把安装包从 Mac 传到 Switch").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(m.deviceColor).frame(width: 7, height: 7)
                Text(m.deviceLabel).font(.system(size: 12, weight: .medium))
            }.padding(.horizontal, 13).padding(.vertical, 9).background(m.deviceColor.opacity(0.09), in: Capsule())
            Button { m.showHelp = true } label: { Image(systemName: "questionmark.circle").font(.system(size: 20)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("连接与使用帮助").accessibilityLabel("连接与使用帮助")
        }.padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 20)
    }

    var guide: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("开始之前").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            guideStep(1, "连接 Switch", "用支持数据传输的 USB 线直连 Mac。", done: m.present)
            guideStep(2, "打开 DBI 后端", "在 Switch 选择“从 DBIbackend 安装”，停留在等待后端的画面。", done: ["connected", "ready", "transferring"].contains(m.state))
            guideStep(3, "添加并开始传输", "添加安装包，点击下方按钮，再在 Switch 上选择文件并安装。", done: m.state == "transferring")
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Label("连接不上？", systemImage: "cable.connector").font(.system(size: 13, weight: .semibold))
                Text("先换一根数据线或一个 USB 接口。若系统询问是否允许配件连接，请选择允许。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                Button("查看排查步骤 →") { m.showHelp = true }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 12, weight: .medium))
            }
            Spacer(minLength: 0)
            Text("需要 Switch 已能运行 DBI。\n本应用负责发送文件；安装由 Switch 完成。").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    func guideStep(_ n: Int, _ title: String, _ text: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.12) : accent.opacity(0.09))
                if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green) }
                else { Text("\(n)").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent) }
            }.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 3)
        }
    }

    func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            ScrollView { Text(text).font(.system(size: 12)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 72)
            Button { m.issue = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }.buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
        }.padding(12).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    var fileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("待传输文件").font(.system(size: 16, weight: .semibold))
                    Text(m.files.isEmpty ? "支持 NSP / NSZ / XCI / XCZ" : "\(m.files.count) 个安装包 · 共 \(bytes(m.totalSize))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加文件夹") { m.choose(folder: true) }
                Button { m.choose() } label: { Label("添加文件", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }.padding(18).disabled(m.active || m.importing)
            Divider()
            ZStack {
                if m.files.isEmpty {
                    VStack(spacing: 13) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 39, weight: .light)).foregroundStyle(accent.opacity(0.75))
                        Text(m.targeted ? "松开即可添加" : "把安装包拖到这里").font(.system(size: 18, weight: .medium))
                        Text("也可以点击右上方“添加文件”\n压缩包请先解压，再添加里面的安装包").multilineTextAlignment(.center).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(m.files) { file in fileRow(file); Divider().padding(.leading, 64) }
                        }.padding(.vertical, 4)
                    }
                }
                if m.importing { Color(nsColor: .controlBackgroundColor).opacity(0.9); ProgressView("正在检查文件…") }
            }.frame(minHeight: 140, maxHeight: .infinity)
                .background(m.targeted ? accent.opacity(0.07) : Color.clear)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: $m.targeted) { providers in
                    guard !m.active, !m.importing else { m.issue = "请先停止传输，再添加文件。"; return false }
                    let group = DispatchGroup(), lock = NSLock()
                    var urls: [URL] = []
                    for provider in providers {
                        group.enter()
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                            if let data, let url = URL(dataRepresentation: data, relativeTo: nil) { lock.lock(); urls.append(url); lock.unlock() }
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) { m.add(urls) }
                    return true
                }
            Divider()
            HStack {
                Text(m.active ? "传输期间，文件列表暂时锁定" : "文件列表会自动记住，移除项目不会删除原文件").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("清空列表") { m.clear() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).disabled(m.active || m.importing || m.files.isEmpty)
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(m.targeted ? accent : Color.primary.opacity(0.07), lineWidth: m.targeted ? 2 : 1))
    }

    func fileRow(_ file: PackageFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.exists ? "doc.zipper" : "exclamationmark.triangle").font(.system(size: 21)).foregroundStyle(file.exists ? accent : .orange)
                .frame(width: 38, height: 42).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).foregroundStyle(file.exists ? Color.primary : .red)
                Text(file.exists ? "\(file.type) · \(bytes(file.size))" : "文件已移动、删除或无法读取").font(.system(size: 11)).foregroundStyle(.secondary)
                if let fileSent = m.sentByFile[file.name], !m.completed.contains(file.name) {
                    ProgressView(value: Double(fileSent), total: Double(max(file.size, 1))).controlSize(.small).frame(maxWidth: 260)
                }
            }.help(file.path)
            Spacer(minLength: 8)
            if m.completed.contains(file.name) {
                Label("已发送", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("在访达中显示").accessibilityLabel("在访达中显示 \(file.name)")
            Button { m.remove(file) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).disabled(m.active || m.importing).help("从列表移除，不删除原文件").accessibilityLabel("移除 \(file.name)")
        }.padding(.horizontal, 18).padding(.vertical, 11)
    }

    var transferCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: m.state == "transferring" ? "arrow.up.circle.fill" : "cable.connector")
                    .font(.system(size: 25)).foregroundStyle(accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(m.status).font(.system(size: 15, weight: .semibold))
                    Text(m.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
            if !m.currentName.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(m.currentName).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    ProgressView(value: m.progress)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let stalled = m.lastProgressAt.map { context.date.timeIntervalSince($0) > 3 } ?? true
                        HStack {
                            Text("已发送 \(bytes(m.sent)) / \(bytes(m.total)) · \(Int(m.progress * 100))%")
                            Spacer()
                            if !m.active || m.speed <= 0 { Text("传输已暂停或结束") }
                            else if stalled { Text("等待 Switch 请求数据…") }
                            else { Text("\(bytes(Int64(m.speed)))/秒 · 剩余约 \(duration(Double(max(0, m.total - m.sent)) / m.speed))") }
                        }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if m.sessionSent > 0 {
                        Text("本次共发送 \(bytes(m.sessionSent))\(m.completed.isEmpty ? "" : "，已完整发送 \(m.completed.count) 个文件")").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("此进度表示电脑已发送的文件数据，不代表 Switch 已完成安装。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("重新检查") { m.refresh() }.disabled(m.active)
                Spacer()
                if m.active {
                    Button("停止传输") { m.stop() }.buttonStyle(.bordered).controlSize(.large).keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { m.start() } label: { Label("开始传输", systemImage: "arrow.up.right").frame(minWidth: 112) }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!m.canStart).keyboardShortcut(.return, modifiers: .command)
                }
            }
        }.padding(18).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.12)))
    }
}

struct HelpView: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("连接与使用帮助").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    help("1. Switch 应该停在哪个画面？", "打开 Switch 上的 DBI，选择“从 DBIbackend 安装 / Install title from DBIbackend”。某些中文版写作“后端”。停留在等待后端连接的画面。\n“Run MTP responder / 运行 MTP 响应器”属于另一种模式，本应用使用 DBI 后端模式。")
                    help("2. Mac 一直识别不到 Switch", "先唤醒并解锁 Mac。使用支持数据传输的 USB 线直连电脑，暂时移除扩展坞。换一根线或另一个接口试试。若 macOS 弹出“允许配件连接”，选择允许，然后点击主界面的“重新检查”。")
                    help("3. 已识别，但没有文件列表", "添加安装包并点击“开始传输”。退出 OpenMTP、Android File Transfer 或其他 DBI 后端工具，避免多个程序占用 USB。再在 Switch 上退出并重新进入后端安装模式。")
                    help("4. 压缩包、金手指和模组怎么办？", "本应用发送 NSP、NSZ、XCI、XCZ 安装包。ZIP、RAR、7Z 需要先解压。金手指、模组、存档等普通文件需要通过 SD 卡或其他文件管理方式复制到对应位置，不能当作安装包发送。")
                    help("5. 中断后会自动续传吗？", "应用会等待 USB 重新连接，但不会自动续传或重新安装。重新连接后，请在 Switch 重新进入后端模式，并重新选择要安装的文件。传输过程中不要移动、修改或删除电脑上的源文件。")
                    help("6. 显示发送完成，就安装好了吗？", "这里的进度是电脑已发送的文件数据。Switch 还会处理和验证文件，最终是否安装成功请以 Switch 屏幕为准。")
                    help("文件与隐私", "文件列表保存在本机，下次启动会自动恢复。清空列表只会移除记录，不会删除文件。应用不会上传文件或日志。日志仅在你点击“导出”并选择位置时保存一份副本。")
                    Divider()
                    Text("Switch 传输助手 \(appVersion) · Apple 芯片 Mac\n基于 DBI0 协议与 GuangLun2000/DBI-backend-for-switch 改进。原项目：CAI (Hanlin Cai)、dev#Mikami；DBI：duckbill。").font(.system(size: 11)).foregroundStyle(.secondary)
                    Link("查看原项目", destination: URL(string: "https://github.com/GuangLun2000/DBI-backend-for-switch")!)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(26).frame(width: 650, height: 650)
    }
    func help(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(body).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LogView: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("诊断日志").font(.title2.bold()); Spacer(); Button("导出…") { m.exportLogs() }; Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            Text("遇到问题时可以查看或导出。日志只保存在本机，不会自动上传。").font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView { Text(m.logs.joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }.padding(24).frame(width: 720, height: 500)
    }
}
