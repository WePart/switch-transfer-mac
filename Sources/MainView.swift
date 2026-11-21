import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 24) {
                guide.frame(width: 235)
                VStack(alignment: .leading, spacing: 16) {
                    if let issue = m.issue {
                        notice(issue).transition(.move(edge: .top).combined(with: .opacity))
                    }
                    fileCard
                    transferCard
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .animation(motion(), value: m.issue)
            }.padding(24)
            Divider()
            HStack(spacing: 16) {
                Label("仅通过 USB 传输 · 文件保留在你的 Mac", systemImage: "lock.shield")
                Spacer()
                Button("传输记录") { m.showHistory = true }.buttonStyle(.plain)
                Button("诊断日志") { m.showLogs = true }.buttonStyle(.plain)
                Text(appVersion).foregroundStyle(.tertiary)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .sheet(isPresented: $m.showHelp) { HelpView().environmentObject(m) }
        .sheet(isPresented: $m.showLogs) { LogView().environmentObject(m) }
        .sheet(isPresented: $m.showHistory) { HistoryView().environmentObject(m) }
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
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Circle().fill(m.deviceColor).frame(width: 7, height: 7)
                        Text(m.deviceLabel).font(.system(size: 12, weight: .medium)).contentTransition(.interpolate)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassEffect(.regular.tint(m.deviceColor.opacity(0.18)), in: .capsule)
                    .animation(motion(), value: m.deviceLabel)
                    Button { m.showHelp = true } label: { Image(systemName: "questionmark").font(.system(size: 13, weight: .semibold)).frame(width: 18, height: 18) }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                        .help("连接与使用帮助").accessibilityLabel("连接与使用帮助")
                }
            }
        }.padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 20)
    }

    var guide: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("开始之前").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            StepGuide(steps: [
                ("连接 Switch", "用支持数据传输的 USB 线直连 Mac。"),
                ("打开 DBI 后端", "在 Switch 选择“从 DBIbackend 安装”，停留在等待后端的画面。"),
                ("添加并开始传输", "添加安装包，点击下方按钮，再在 Switch 上选择文件并安装。"),
            ], done: m.stepsDone)
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

    func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            ScrollView { Text(text).font(.system(size: 12)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 72)
            Button { withAnimation(motion()) { m.issue = nil } } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
        }.padding(12).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    var fileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("待传输文件").font(.system(size: 16, weight: .semibold))
                    Text(m.files.isEmpty ? "支持 NSP / NSZ / XCI / XCZ" : "\(m.files.count) 个安装包 · 共 \(bytes(m.totalSize))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).contentTransition(.numericText()).animation(motion(), value: m.files.count)
                }
                Spacer()
                Menu {
                    Button("按名称") { m.sort(by: .name) }
                    Button("按大小（从大到小）") { m.sort(by: .size) }
                    Button("按添加顺序") { m.sort(by: .added) }
                } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(m.files.count < 2)
                    .help("列表顺序就是 Switch 上显示的顺序")
                Button("添加文件夹") { m.choose(folder: true) }
                Button { m.choose() } label: { Label("添加文件", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }.padding(18).disabled(!m.canEdit)
            Divider()
            ZStack {
                if m.files.isEmpty {
                    VStack(spacing: 13) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 39, weight: .light)).foregroundStyle(accent.opacity(0.75))
                            .symbolEffect(.bounce, value: reduceMotion ? false : m.targeted)
                        Text(m.targeted ? "松开即可添加" : "把安装包拖到这里").font(.system(size: 18, weight: .medium)).contentTransition(.opacity)
                        Text("也可以点击右上方“添加文件”\n压缩包请先解压，再添加里面的安装包").multilineTextAlignment(.center).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity)
                } else {
                    List(selection: $m.selection) {
                        ForEach(m.files) { file in fileRow(file).tag(file.id) }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden).alternatingRowBackgrounds(.disabled)
                    .onDeleteCommand { m.remove(m.selection) }
                    .contextMenu(forSelectionType: String.self) { ids in
                        Button("在访达中显示") { m.reveal(ids) }
                        Button(ids.count > 1 ? "复制 \(ids.count) 个路径" : "复制路径") { m.copyPaths(ids) }
                        Divider()
                        Button(ids.count > 1 ? "从列表移除 \(ids.count) 项" : "从列表移除") { m.remove(ids) }.disabled(!m.canEdit)
                    } primaryAction: { ids in m.reveal(ids) }
                    .transition(.opacity)
                }
                if m.importing {
                    Color(nsColor: .controlBackgroundColor).opacity(0.9)
                    ProgressView("正在检查文件…")
                }
            }.frame(minHeight: 140, maxHeight: .infinity)
                .background(m.targeted ? accent.opacity(0.07) : Color.clear)
                .contentShape(Rectangle())
                .animation(motion(), value: m.targeted)
                .animation(motion(), value: m.files.isEmpty)
                .onDrop(of: [.fileURL], isTargeted: $m.targeted) { providers in
                    guard m.canEdit else { m.issue = "Switch 正在读取文件列表，请等本批结束或停止传输后再修改。"; return false }
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
                Text(footerHint).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if !m.selection.isEmpty {
                    Button("移除所选 (\(m.selection.count))") { m.remove(m.selection) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .disabled(!m.canEdit).transition(.opacity)
                }
                Button("清空列表") { m.clear() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).disabled(!m.canEdit || m.files.isEmpty)
            }.padding(.horizontal, 18).padding(.vertical, 12).animation(motion(), value: m.selection.isEmpty)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(m.targeted ? accent : Color.primary.opacity(0.07), lineWidth: m.targeted ? 2 : 1))
    }

    var footerHint: String {
        if m.active && m.canEdit { return "可以继续增删文件；若 Switch 已显示旧列表，重新进入后端即可" }
        if m.active { return "Switch 正在使用文件列表，暂时锁定" }
        return "右键或按 Delete 管理所选文件；移除不会删除原文件"
    }

    func fileRow(_ file: PackageFile) -> some View {
        let done = m.completed.contains(file.name)
        return HStack(spacing: 12) {
            Image(systemName: file.exists ? "doc.zipper" : "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(file.exists ? accent : .orange)
                .frame(width: 38, height: 42).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).foregroundStyle(file.exists ? Color.primary : .red)
                HStack(spacing: 6) {
                    Text(file.exists ? "\(file.type) · \(bytes(file.size))" : "文件已移动、删除或无法读取")
                    if let date = m.lastSent[file.historyKey] {
                        Text("曾于 \(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))) 发送")
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if let fileSent = m.sentByFile[file.name], !done {
                    ProgressView(value: Double(fileSent), total: Double(max(file.size, 1))).controlSize(.small).frame(maxWidth: 260)
                        .animation(motion(), value: fileSent).transition(.opacity)
                }
            }.help(file.path)
            Spacer(minLength: 8)
            if done {
                Label("已发送", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).help("在访达中显示").accessibilityLabel("在访达中显示 \(file.name)")
            Button { m.remove([file.id]) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain).disabled(!m.canEdit).help("从列表移除，不删除原文件").accessibilityLabel("移除 \(file.name)")
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .animation(motion(), value: done)
    }

    var transferCard: some View {
        HStack(alignment: .center, spacing: 22) {
            ProgressRing(progress: m.showsPercent ? m.progress : (m.state == "ended" ? 1 : 0), color: m.stateColor,
                         showsPercent: m.showsPercent, symbol: m.stateSymbol,
                         pulsing: ["waiting", "handshake", "reconnecting"].contains(m.state) && m.active, bounce: m.connectCount)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(m.status).font(.system(size: 16, weight: .semibold)).contentTransition(.opacity)
                    Text(m.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                if !m.currentName.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(m.currentName).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let stalled = m.lastProgressAt.map { context.date.timeIntervalSince($0) > 3 } ?? true
                            HStack(spacing: 10) {
                                Text("\(bytes(m.sent)) / \(bytes(m.total))").contentTransition(.numericText())
                                if !m.active || m.speed <= 0 { Text("传输已暂停或结束") }
                                else if stalled { Text("等待 Switch 请求数据…") }
                                else {
                                    Text("\(bytes(Int64(m.speed)))/秒").contentTransition(.numericText())
                                    Text("剩余约 \(duration(Double(max(0, m.total - m.sent)) / m.speed))").contentTransition(.numericText())
                                }
                            }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                                .animation(motion(), value: m.sent)
                        }
                        if m.sessionSent > 0 {
                            Text("本次共发送 \(bytes(m.sessionSent))\(m.completed.isEmpty ? "" : "，已完整发送 \(m.completed.count) 个文件")\(m.batches > 0 ? " · 已完成 \(m.batches) 批" : "")")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text("进度表示电脑已发送的数据，安装结果以 Switch 屏幕为准。").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.transition(.opacity)
                }
                HStack {
                    Button("重新检查") { m.refresh() }.disabled(m.active)
                    if !m.active {
                        Toggle("本批结束后继续等待下一批", isOn: $m.keepServing).toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if m.active {
                        Button { m.stop() } label: { Label("停止传输", systemImage: "stop.fill").frame(minWidth: 96) }
                            .buttonStyle(.glass).controlSize(.large).keyboardShortcut(".", modifiers: .command)
                    } else {
                        Button { m.start() } label: { Label("开始传输", systemImage: "arrow.up.right").frame(minWidth: 112) }
                            .buttonStyle(.glassProminent).controlSize(.large).disabled(!m.canStart).keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            .animation(motion(), value: m.currentName.isEmpty)
            .animation(motion(), value: m.active)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(m.stateColor.opacity(0.08)), in: .rect(cornerRadius: 20))
        .animation(motion(), value: m.state)
    }
}
