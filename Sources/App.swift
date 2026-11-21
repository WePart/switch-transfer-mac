import SwiftUI
import AppKit

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
    // While transferring with the menu bar item, closing the window keeps the service running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Model.shared.showsMenuBar }
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
                Button("添加安装包…") { model.choose() }.keyboardShortcut("o").disabled(!model.canEdit)
                Button("添加文件夹…") { model.choose(folder: true) }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!model.canEdit)
            }
            CommandMenu("传输") {
                Button("开始传输") { model.start() }.keyboardShortcut(.return, modifiers: .command).disabled(!model.canStart)
                Button("停止传输") { model.stop() }.keyboardShortcut(".", modifiers: .command).disabled(!model.active)
                Divider()
                Button("重新检查连接") { model.refresh() }.keyboardShortcut("r").disabled(model.active)
                Button("传输记录") { model.showHistory = true }.keyboardShortcut("y")
            }
            CommandGroup(replacing: .help) {
                Button("连接与使用帮助") { model.showHelp = true }
                Button("查看传输记录") { model.showHistory = true }
                Button("查看诊断日志") { model.showLogs = true }
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 Switch 传输助手") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Switch 传输助手", .applicationVersion: appVersion, .version: appBuild, .credits: NSAttributedString(string: "适用于 Apple 芯片 Mac 的 DBI USB 传输工具。\n基于 GuangLun2000/DBI-backend-for-switch 与 DBI0 协议。\n原项目：CAI (Hanlin Cai) / dev#Mikami；DBI：duckbill。\n本工具不代表 Nintendo 官方。")])
                }
            }
        }

        Settings { SettingsView().environmentObject(model) }

        MenuBarExtra(isInserted: Binding(get: { model.showsMenuBar }, set: { _ in })) {
            MenuBarPanel().environmentObject(model)
        } label: {
            Image(systemName: model.state == "transferring" ? "arrow.up.circle.fill" : "cable.connector")
            if model.showsPercent { Text("\(Int(model.progress * 100))%").monospacedDigit() }
        }
        .menuBarExtraStyle(.window)
    }
}
