import SwiftUI
import AppKit

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
                    help("5. 怎样连续安装多批？", "勾选“本批结束后继续等待下一批”（也可在“设置”里修改）。Switch 退出后端后，应用会继续等待；在等待期间可以增删文件：Switch 尚未读取列表时立即生效，已显示旧列表时请退出后端再重新进入。")
                    help("6. 中断后会自动续传吗？", "应用会等待 USB 重新连接，但不会自动续传或重新安装。重新连接后，请在 Switch 重新进入后端模式，并重新选择要安装的文件。传输过程中不要移动、修改或删除电脑上的源文件。")
                    help("7. 显示发送完成，就安装好了吗？", "这里的进度是电脑已发送的文件数据。Switch 还会处理和验证文件，最终是否安装成功请以 Switch 屏幕为准。")
                    help("8. 快捷键", "⌘O 添加文件 · ⇧⌘O 添加文件夹 · ⌘↩ 开始传输 · ⌘. 停止传输 · ⌘Y 传输记录 · ⌘, 设置。在文件列表中可用 ⌘ / ⇧ 多选，按 Delete 移除，右键查看更多操作。")
                    help("文件与隐私", "文件列表和传输记录保存在本机，下次启动会自动恢复。清空列表或记录只会移除记录，不会删除文件。应用不会上传文件或日志。日志仅在你点击“导出”并选择位置时保存一份副本。")
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

struct HistoryView: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) var dismiss

    var groups: [(day: Date, entries: [HistoryEntry])] {
        let query = m.historyQuery.trimmingCharacters(in: .whitespaces)
        let matches = m.history.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return Dictionary(grouping: matches) { Calendar.current.startOfDay(for: $0.finishedAt) }
            .map { ($0.key, $0.value.sorted { $0.finishedAt > $1.finishedAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("传输记录").font(.title2.bold())
                Spacer()
                Button("清空记录…") { m.clearHistory() }.disabled(m.history.isEmpty)
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文件名", text: $m.historyQuery).textFieldStyle(.plain)
            }.padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            Text("记录完整发送到 Switch 的文件，只保存在本机，最多保留 1000 条。安装结果以 Switch 屏幕为准。").font(.system(size: 11)).foregroundStyle(.secondary)
            if groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text(m.history.isEmpty ? "还没有传输记录" : "没有匹配的记录").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.day) { group in
                        Section(group.day.formatted(.dateTime.year().month().day().weekday(.wide))) {
                            ForEach(group.entries) { entry in row(entry) }
                        }
                    }
                }.listStyle(.inset)
            }
        }
        .padding(24).frame(width: 720, height: 540)
        .animation(motion(), value: m.history)
    }

    func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(bytes(entry.size)) · 用时 \(duration(entry.seconds)) · 平均 \(bytes(Int64(entry.speed)))/秒")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }.help(entry.path)
            Spacer()
            Text(entry.finishedAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).disabled(!FileManager.default.fileExists(atPath: entry.path))
                .help("在访达中显示").accessibilityLabel("在访达中显示 \(entry.name)")
        }.padding(.vertical, 3)
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        Form {
            Section("传输") {
                Toggle("本批结束后继续等待下一批", isOn: $m.keepServing)
                Text("Switch 退出后端后应用继续等待，可在等待期间增删文件。下次开始传输时生效。").font(.caption).foregroundStyle(.secondary)
                Toggle("传输期间防止 Mac 睡眠", isOn: $m.preventSleepEnabled)
            }
            Section("提醒") {
                Toggle("发送完成、连接中断时发送系统通知", isOn: $m.notifyEnabled)
                Text("仅在应用不在前台时通知。首次开始传输时会请求通知权限，可在“系统设置 › 通知”中修改。").font(.caption).foregroundStyle(.secondary)
                Toggle("传输期间在菜单栏显示进度", isOn: $m.menuBarEnabled)
                Text("开启后，传输期间关闭主窗口不会退出应用，可从菜单栏查看进度或停止。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 460).fixedSize(horizontal: false, vertical: true)
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var m: Model
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressRing(progress: m.showsPercent ? m.progress : 0, color: m.stateColor, showsPercent: m.showsPercent,
                             symbol: m.stateSymbol, pulsing: false, bounce: m.connectCount, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.status).font(.system(size: 13, weight: .semibold))
                    Text(m.currentName.isEmpty ? m.detail : m.currentName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
            }
            if m.showsPercent {
                Text("\(bytes(m.sent)) / \(bytes(m.total))\(m.speed > 0 ? " · \(bytes(Int64(m.speed)))/秒" : "")").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Divider()
            HStack {
                Button("显示主窗口") { openWindow(id: "main"); NSApp.activate() }
                Spacer()
                Button("停止传输") { NSApp.activate(); m.stop() }.disabled(!m.active)
            }
        }.padding(14).frame(width: 300)
    }
}
