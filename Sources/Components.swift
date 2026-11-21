import SwiftUI
import AppKit

let accent = Color(red: 0.12, green: 0.39, blue: 0.87)
let supported: Set<String> = ["nsp", "nsz", "xci", "xcz"]
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

func duration(_ seconds: Double) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
    formatter.unitsStyle = .positional; formatter.zeroFormattingBehavior = .pad
    return formatter.string(from: max(0, seconds.rounded())) ?? "--"
}

/// Honours the system "Reduce motion" setting for every animation in the app.
var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
func motion(_ animation: Animation = .smooth(duration: 0.35)) -> Animation? { reduceMotion ? nil : animation }

struct ProgressRing: View {
    let progress: Double
    let color: Color
    let showsPercent: Bool
    let symbol: String
    let pulsing: Bool
    let bounce: Int
    var size: CGFloat = 112

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.14), lineWidth: size * 0.09)
            Circle().trim(from: 0, to: progress)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsPercent {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(progress * 100))").font(.system(size: size * 0.26, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText(value: progress))
                    Text("%").font(.system(size: size * 0.12, weight: .medium)).foregroundStyle(.secondary)
                }.monospacedDigit().transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.27, weight: .medium)).foregroundStyle(color)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: pulsing && !reduceMotion)
                    .symbolEffect(.bounce, value: reduceMotion ? 0 : bounce)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(width: size, height: size)
        .animation(motion(), value: progress)
        .animation(motion(), value: showsPercent)
        .animation(motion(), value: symbol)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsPercent ? "当前文件已发送 \(Int(progress * 100))%" : "传输状态")
    }
}

struct StepGuide: View {
    let steps: [(title: String, text: String)]
    let done: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        badge(index)
                        if index < steps.count - 1 {
                            ZStack(alignment: .top) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(Color.green.gradient)
                                    .scaleEffect(x: 1, y: index < done ? 1 : 0, anchor: .top)
                            }
                            .frame(width: 2).frame(minHeight: 22, maxHeight: .infinity)
                            .padding(.vertical, 5)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.title).font(.system(size: 14, weight: index == done ? .bold : .semibold))
                            .foregroundStyle(index > done ? .secondary : .primary)
                        Text(step.text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4).padding(.bottom, index < steps.count - 1 ? 20 : 0)
                    .opacity(index > done ? 0.7 : 1)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(motion(.smooth(duration: 0.5)), value: done)
    }

    func badge(_ index: Int) -> some View {
        ZStack {
            Circle().fill(index < done ? Color.green.opacity(0.14) : index == done ? accent.opacity(0.12) : Color.primary.opacity(0.05))
            if index == done { Circle().strokeBorder(accent, lineWidth: 2) }
            if index < done {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text("\(index + 1)").font(.system(size: 13, weight: .semibold)).foregroundStyle(index == done ? accent : .secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel(index < done ? "第 \(index + 1) 步已完成" : index == done ? "当前第 \(index + 1) 步" : "第 \(index + 1) 步")
    }
}
