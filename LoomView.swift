import SwiftUI
#if os(macOS)
import AppKit
#endif

struct LoomView: View {
    enum OpticalMode: Equatable {
        case reading
        case skeleton
        case ladder
    }

    @State private var focusLevel: Double = 0

    private var mode: OpticalMode {
        if focusLevel > 0.5 {
            return .ladder
        }
        if focusLevel < -0.5 {
            return .skeleton
        }
        return .reading
    }

    private var gutterColor: Color {
        switch mode {
        case .reading:
            return Color.gray.opacity(0.7)
        case .skeleton:
            return Color(red: 0.89, green: 0.64, blue: 0.2) // amber
        case .ladder:
            return Color(red: 0.19, green: 0.44, blue: 0.92)
        }
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                gutter
                textBody
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .topLeading)
        }
        .background(Color(red: 0.96, green: 0.95, blue: 0.93).ignoresSafeArea())
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: focusLevel)
    }

    private var gutter: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(gutterColor)
                .frame(width: 6)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)
        }
        .frame(width: 22)
        .frame(minHeight: 460)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay {
            ScrollWheelHandler(value: $focusLevel)
        }
        .accessibilityLabel("Semantic lens gutter")
    }

    @ViewBuilder
    private var textBody: some View {
        if mode == .ladder {
            ladderBody
        } else {
            Text(styledReadingText)
                .font(.system(size: 24, design: .serif))
                .lineSpacing(8)
                .foregroundStyle(Color.black.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var styledReadingText: AttributedString {
        var output = AttributedString()
        let words = LoomDemoText.paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        for index in words.indices {
            let word = words[index]
            var token = AttributedString(word)

            if mode == .skeleton && !isCoreWord(word) {
                token.foregroundColor = Color.black.opacity(0.14)
            } else {
                token.foregroundColor = Color.black.opacity(0.92)
            }

            output.append(token)

            if index < words.count - 1 {
                output.append(AttributedString(" "))
            }
        }

        return output
    }

    private var ladderBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ladderSegments) { segment in
                Text(segment.text)
                    .font(.system(size: 23, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.9))
                    .padding(.leading, CGFloat(segment.indentLevel) * 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ladderSegments: [LadderSegment] {
        let clauses = LoomDemoText.paragraph
            .split(whereSeparator: { [",", ";", ".", ":"].contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return clauses.enumerated().map { index, clause in
            LadderSegment(id: index, text: clause, indentLevel: index % 3)
        }
    }

    private func isCoreWord(_ rawWord: String) -> Bool {
        let normalized = rawWord
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)

        guard !normalized.isEmpty else { return false }

        if normalized.count >= 6 {
            return true
        }

        let coreLexicon: Set<String> = [
            "loom", "semantic", "lens", "read", "text", "meaning",
            "focus", "mode", "shape", "core", "signal"
        ]

        return coreLexicon.contains(normalized)
    }

    private struct LadderSegment: Identifiable {
        let id: Int
        let text: String
        let indentLevel: Int
    }
}

#if os(macOS)
struct ScrollWheelHandler: NSViewRepresentable {
    @Binding var value: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = context.coordinator.handleScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        context.coordinator.value = $value
        nsView.onScroll = context.coordinator.handleScroll
    }

    final class Coordinator {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        func handleScroll(_ deltaY: CGFloat) {
            let previous = value.wrappedValue
            let dampedDelta = Double(deltaY) * 0.05
            let next = clamp(previous + dampedDelta)
            value.wrappedValue = next
            emitThresholdHapticIfNeeded(from: previous, to: next)
        }

        private func clamp(_ raw: Double) -> Double {
            min(1, max(-1, raw))
        }

        private func emitThresholdHapticIfNeeded(from previous: Double, to next: Double) {
            let crossedUpper = crossed(threshold: 0.5, from: previous, to: next)
            let crossedLower = crossed(threshold: -0.5, from: previous, to: next)

            if crossedUpper {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            } else if crossedLower {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }

        private func crossed(threshold: Double, from previous: Double, to next: Double) -> Bool {
            (previous <= threshold && next > threshold) || (previous >= threshold && next < threshold)
        }
    }
}

final class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        // This intercepts wheel input on the gutter only and prevents parent ScrollView capture.
        onScroll?(event.deltaY)
    }
}
#elseif os(iOS)
struct ScrollWheelHandler: View {
    @Binding var value: Double

    var body: some View {
        EmptyView()
    }
}
#else
struct ScrollWheelHandler: View {
    @Binding var value: Double

    var body: some View {
        EmptyView()
    }
}
#endif

private enum LoomDemoText {
    private static let seed =
    "Language behaves like weather: stable from afar, unstable up close. We read for continuity, yet every sentence carries hidden hinges. Pull one margin, and the paragraph opens into a workbench where meaning can be tested, stretched, and rebuilt."

    static let paragraph = Array(repeating: seed, count: 7).joined(separator: " ")
}

struct LoomView_Previews: PreviewProvider {
    static var previews: some View {
        LoomView()
    }
}
