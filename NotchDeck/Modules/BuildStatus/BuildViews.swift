import SwiftUI
import AppKit

private func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

private func compactCount(_ n: Int) -> String {
    n >= 10_000 ? "\(n / 1000)k" : (n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)")
}

// MARK: - Compact

struct BuildCompactLeading: View {
    let module: BuildStatusModule

    var body: some View {
        if let b = module.primaryBuild {
            BuildGlyph(status: b.status, size: 15)
        } else {
            Image(systemName: "hammer.fill").font(.system(size: 13)).foregroundStyle(NotchTheme.secondaryText)
        }
    }
}

struct BuildGlyph: View {
    let status: BuildStatus
    var size: CGFloat = 16

    var body: some View {
        switch status {
        case .running:
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Image(systemName: "hammer.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .rotationEffect(.degrees(-18 * max(0, sin(t * 7)) ), anchor: .bottomLeading)
                    .opacity(0.75 + 0.25 * (0.5 + 0.5 * sin(t * 3)))
            }
        case .succeeded, .warnings:
            Image(systemName: "checkmark.circle.fill").font(.system(size: size, weight: .semibold)).foregroundStyle(NotchTheme.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: size, weight: .semibold)).foregroundStyle(NotchTheme.danger)
        }
    }
}

struct BuildCompactTrailing: View {
    let module: BuildStatusModule

    var body: some View {
        if let b = module.primaryBuild {
            switch b.status {
            case .running:
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    label(clock(b.elapsed(at: tl.date)), NotchTheme.primaryText, mono: true)
                }
            case .failed:
                label(b.errors > 0 ? "\(compactCount(b.errors)) err" : "Failed", NotchTheme.danger)
            case .succeeded, .warnings:
                label(b.duration.map(buildDuration) ?? "Done", NotchTheme.success)
            }
        } else {
            EmptyView()
        }
    }

    private func label(_ t: String, _ c: Color, mono: Bool = false) -> some View {
        Text(t)
            .font(mono ? NotchTheme.monoFont : .system(size: 11, weight: .semibold))
            .foregroundStyle(c)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: 62, alignment: .trailing)
    }
}

// MARK: - Expanded

struct BuildExpandedView: View {
    let module: BuildStatusModule

    var body: some View {
        let rows = module.recentBuilds
        VStack(spacing: 6) {
            HStack {
                Text("BUILDS").font(.system(size: 9.5, weight: .bold)).tracking(0.8)
                    .foregroundStyle(NotchTheme.tertiaryText)
                Spacer()
                if module.hasFinished {
                    Button("Clear") { withAnimation(NotchTheme.spring) { module.clear() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(NotchTheme.secondaryText)
                }
            }
            .padding(.horizontal, 4)

            if rows.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(rows) { BuildRow(build: $0, module: module) }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "hammer.fill").font(.system(size: 24)).foregroundStyle(NotchTheme.tertiaryText)
            Text("No builds yet").font(NotchTheme.titleFont).foregroundStyle(NotchTheme.primaryText)
            Text("Xcode builds appear automatically. For terminal builds run: ndrun <command>")
                .font(NotchTheme.bodyFont).foregroundStyle(NotchTheme.secondaryText)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BuildRow: View {
    let build: BuildRecord
    let module: BuildStatusModule
    @State private var copied = false

    private var canCopy: Bool { build.isFailed && (build.logTail ?? build.message) != nil }

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 10) {
                Image(systemName: build.source.glyph)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(build.source.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(build.project).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NotchTheme.primaryText).lineLimit(1)
                        statusChip
                    }
                    Text(copied ? "Copied log tail to clipboard" : subtitle)
                        .font(NotchTheme.captionFont)
                        .foregroundStyle(copied ? NotchTheme.success : (build.isFailed ? NotchTheme.danger.opacity(0.9) : NotchTheme.secondaryText))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(alignment: .bottom) { progressBar }
            .background(RoundedRectangle(cornerRadius: 10).fill(NotchTheme.surface))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(canCopy ? "Click to copy the log tail" : "")
    }

    private var subtitle: String {
        if build.isFailed { return build.message ?? build.title }
        return build.title
    }

    @ViewBuilder private var progressBar: some View {
        if build.isRunning {
            TimelineView(.periodic(from: .now, by: 0.5)) { tl in
                GeometryReader { g in
                    if let p = module.progress(for: build, at: tl.date) {
                        Rectangle().fill(Color.orange.opacity(0.9))
                            .frame(width: g.size.width * p, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .animation(.easeOut(duration: 0.4), value: p)
                    } else {
                        // No history yet: indeterminate sweep so a running build never looks idle.
                        let t = tl.date.timeIntervalSinceReferenceDate
                        let x = (t.truncatingRemainder(dividingBy: 1.6) / 1.6)
                        Rectangle().fill(Color.orange.opacity(0.85))
                            .frame(width: g.size.width * 0.25, height: 3)
                            .offset(x: (g.size.width * 1.25) * x - g.size.width * 0.25)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if build.isRunning {
            VStack(alignment: .trailing, spacing: 1) {
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    Text(clock(build.elapsed(at: tl.date))).font(NotchTheme.monoFont).foregroundStyle(NotchTheme.primaryText)
                }
                if let n = build.tasksDone {
                    Text("\(n) tasks").font(.system(size: 9.5, weight: .medium)).foregroundStyle(NotchTheme.tertiaryText)
                } else if let avg = module.averageDuration(for: build) {
                    Text("avg \(clock(avg))").font(.system(size: 9.5, weight: .medium)).foregroundStyle(NotchTheme.tertiaryText)
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(build.duration.map(buildDuration) ?? "--").font(NotchTheme.monoFont).foregroundStyle(NotchTheme.secondaryText)
                if let end = build.endedAt {
                    Text(end, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(NotchTheme.tertiaryText)
                }
            }
        }
    }

    private var statusChip: some View {
        let (text, color): (String, Color) = {
            switch build.status {
            case .running: return ("Building", .orange)
            case .succeeded: return ("Succeeded", NotchTheme.success)
            case .warnings: return ("\(compactCount(build.warnings)) warning\(build.warnings == 1 ? "" : "s")", NotchTheme.warning)
            case .failed: return (build.errors > 0 ? "\(compactCount(build.errors)) error\(build.errors == 1 ? "" : "s")" : "Failed", NotchTheme.danger)
            }
        }()
        return Text(text).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    private func copy() {
        guard canCopy else { return }
        module.copyLog(of: build)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}

// MARK: - Settings

struct BuildSettingsView: View {
    @Bindable var module: BuildStatusModule

    var body: some View {
        Group {
            Toggle("Detect Xcode builds", isOn: $module.xcodeDetection)
            Stepper(value: $module.peekThreshold, in: 0...120, step: 1) {
                HStack {
                    Text("Peek when a build takes longer than")
                    Spacer()
                    Text("\(Int(module.peekThreshold))s").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("Failures always peek.").font(.caption).foregroundStyle(.secondary)
            Toggle("Notify when a build over 30s finishes", isOn: $module.notifyOnFinish)

            Divider()

            installRow(title: "Terminal wrapper (ndrun)",
                       installed: module.ndrunInstalled,
                       updateAvailable: module.ndrunInstalled && !module.ndrunUpToDate,
                       install: { module.perform("ndrun installed.", BuildInstallers.installNdrun) },
                       uninstall: { module.perform("ndrun removed.", BuildInstallers.uninstallNdrun) })
            snippet("Add to ~/.zshrc (pick one):", BuildInstallers.pathSnippet + "\n" + BuildInstallers.aliasSnippet)
            Text("Usage: ndrun xcodebuild …, ndrun ./gradlew assembleDebug, ndrun pod install, ndrun eas build --local. Output and exit code pass through unchanged.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            installRow(title: "Gradle hook (Android Studio + CLI)",
                       installed: module.gradleInstalled,
                       updateAvailable: false,
                       install: { module.perform("Gradle hook installed. It applies to the next Gradle build.", BuildInstallers.installGradleHook) },
                       uninstall: { module.perform("Gradle hook removed.", BuildInstallers.uninstallGradleHook) })
            Text("Writes ~/.gradle/init.d/notchdeck.gradle (+ ~/.gradle/notchdeck/). Uses the Flow API on Gradle 8.1+ (configuration-cache safe); older versions use a best-effort buildFinished listener. Builds with no tasks (IDE sync) are ignored.")
                .font(.caption).foregroundStyle(.secondary)

            if let m = module.installMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { module.refreshInstallStatus() }
    }

    private func installRow(title: String, installed: Bool, updateAvailable: Bool,
                            install: @escaping () -> Void, uninstall: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(installed ? (updateAvailable ? "Update available" : "Installed") : "Not installed")
                .foregroundStyle(installed ? (updateAvailable ? Color.orange : Color.green) : Color.secondary)
            if installed {
                Button("Uninstall", action: uninstall)
                Button(updateAvailable ? "Update" : "Reinstall", action: install)
            } else {
                Button("Install", action: install)
            }
        }
    }

    private func snippet(_ caption: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        }
    }
}

// MARK: - Compact peek row

struct BuildPeekRow: View {
    let build: BuildRecord

    var body: some View {
        let title: String = {
            if build.isFailed {
                return build.errors > 0 ? "Build failed \u{00B7} \(build.errors) error\(build.errors == 1 ? "" : "s")" : "Build failed"
            }
            return build.duration.map { "Build succeeded \u{00B7} " + buildDuration($0) } ?? "Build succeeded"
        }()
        HStack(spacing: 8) {
            BuildGlyph(status: build.status, size: 14)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(NotchTheme.primaryText)
                .lineLimit(1).fixedSize()
            Text(build.project)
                .font(.system(size: 12))
                .foregroundStyle(NotchTheme.secondaryText)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}
