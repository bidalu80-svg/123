import SwiftUI
import UIKit

struct CodeViewerEntry: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let language: String?
    let content: String

    var fileSizeText: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(content.lengthOfBytes(using: .utf8)),
            countStyle: .file
        )
    }
}

struct CodeViewerPayload: Identifiable {
    let id = UUID()
    let title: String
    let entries: [CodeViewerEntry]
    let initialIndex: Int
    let preferredTerminalCommand: String?

    init(
        title: String,
        entries: [CodeViewerEntry],
        initialIndex: Int,
        preferredTerminalCommand: String? = nil
    ) {
        self.title = title
        self.entries = entries
        self.initialIndex = initialIndex
        self.preferredTerminalCommand = preferredTerminalCommand
    }
}

struct CodeViewerSheet: View {
    let payload: CodeViewerPayload
    let codeThemeMode: CodeThemeMode
    let onRunTerminalCommand: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentIndex: Int
    @State private var copiedEntryID: UUID?

    init(
        payload: CodeViewerPayload,
        codeThemeMode: CodeThemeMode,
        onRunTerminalCommand: ((String) -> Void)? = nil
    ) {
        self.payload = payload
        self.codeThemeMode = codeThemeMode
        self.onRunTerminalCommand = onRunTerminalCommand
        let maxIndex = max(0, payload.entries.count - 1)
        _currentIndex = State(initialValue: min(max(payload.initialIndex, 0), maxIndex))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Divider()
                .overlay(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08))

            if payload.entries.isEmpty {
                emptyState
            } else {
                viewerCard(entry: currentEntry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                bottomPager
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            toolbarCircleButton(
                systemName: "xmark",
                isEnabled: true,
                isHighlighted: false
            ) {
                dismiss()
            }

            Spacer(minLength: 0)

            Text(payload.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if canRunTerminalCommand {
                    toolbarCircleButton(
                        systemName: "terminal",
                        isEnabled: true,
                        isHighlighted: false
                    ) {
                        runTerminalCommandFromPayload()
                    }
                }

                toolbarCircleButton(
                    systemName: isCurrentEntryCopied ? "checkmark" : "doc.on.doc",
                    isEnabled: !payload.entries.isEmpty,
                    isHighlighted: isCurrentEntryCopied
                ) {
                    copyCurrentEntryCode()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func viewerCard(entry: CodeViewerEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(entry.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("(\(entry.fileSizeText))")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(codeViewportBackgroundColor)

                GeometryReader { proxy in
                    let viewportHeight = max(220, proxy.size.height - 2)
                    SelectableCodeTextView(
                        text: entry.content,
                        textColor: codePrimaryTextColor,
                        font: .monospacedSystemFont(ofSize: 15.5, weight: .medium),
                        lineSpacing: 3.5,
                        language: entry.language,
                        codeThemeMode: codeThemeMode,
                        isDarkMode: colorScheme == .dark,
                        isScrollEnabled: true,
                        maximumHeight: viewportHeight
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.09), lineWidth: 0.8)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(colorScheme == .dark ? 0.15 : 0.06), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var bottomPager: some View {
        HStack(spacing: 14) {
            pagerButton(
                systemName: "backward.end.fill",
                isEnabled: currentIndex > 0
            ) {
                currentIndex = max(0, currentIndex - 1)
            }

            Spacer(minLength: 0)

            Text("\(currentIndex + 1) / \(payload.entries.count)")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()

            Spacer(minLength: 0)

            pagerButton(
                systemName: "forward.end.fill",
                isEnabled: currentIndex < payload.entries.count - 1
            ) {
                currentIndex = min(payload.entries.count - 1, currentIndex + 1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("没有可查看的代码")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var currentEntry: CodeViewerEntry {
        let safeIndex = min(max(currentIndex, 0), max(0, payload.entries.count - 1))
        return payload.entries[safeIndex]
    }

    private var isCurrentEntryCopied: Bool {
        guard !payload.entries.isEmpty else { return false }
        return copiedEntryID == currentEntry.id
    }

    private var normalizedPreferredTerminalCommand: String? {
        guard let raw = payload.preferredTerminalCommand else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canRunTerminalCommand: Bool {
        normalizedPreferredTerminalCommand != nil && onRunTerminalCommand != nil
    }

    private func copyCurrentEntryCode() {
        guard !payload.entries.isEmpty else { return }
        let entry = currentEntry
        UIPasteboard.general.string = entry.content
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copiedEntryID = entry.id

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard copiedEntryID == entry.id else { return }
            copiedEntryID = nil
        }
    }

    private func runTerminalCommandFromPayload() {
        guard let command = normalizedPreferredTerminalCommand else { return }
        onRunTerminalCommand?(command)
    }

    private func toolbarCircleButton(
        systemName: String,
        isEnabled: Bool,
        isHighlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isHighlighted ? Color.green : Color.primary)
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(Color(.secondarySystemGroupedBackground))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func pagerButton(
        systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.45))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var codeViewportBackgroundColor: Color {
        if usesDarkCodePalette {
            return Color.black.opacity(0.24)
        }
        return Color.black.opacity(0.03)
    }

    private var codePrimaryTextColor: UIColor {
        if usesDarkCodePalette {
            return UIColor(red: 0.83, green: 0.84, blue: 0.86, alpha: 1)
        }
        return UIColor(red: 0.14, green: 0.16, blue: 0.18, alpha: 1)
    }

    private var usesDarkCodePalette: Bool {
        switch codeThemeMode {
        case .vscodeDark:
            return true
        case .githubLight:
            return false
        case .followApp:
            return colorScheme == .dark
        }
    }
}
