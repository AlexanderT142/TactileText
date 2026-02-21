import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private enum LoomInkBond {
    static let font = Font.system(size: 22, design: .serif)
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.93)
    static let gutterWidth: CGFloat = 4
    static let gutterLaneWidth: CGFloat = 22
    static let rowSpacing: CGFloat = 12
    static let wordSpacing: CGFloat = 6
    static let lineSpacing: CGFloat = 10
}

private struct WordInkStyle {
    let color: Color
    let showHairlineUnderline: Bool
}

private enum WorkbenchOpticalMode: Hashable {
    case reading
    case skeleton
    case ladder
}

struct ContentView: View {
    @StateObject private var engine = TactileTextEngine(
        sentences: MockData.sentences,
        fullText: MockData.paragraph
    )
    @Namespace private var modeSwitchNamespace

    var body: some View {
        ZStack {
            LoomInkBond.paper.ignoresSafeArea()

            ZStack {
                if engine.isWorkbenchMode {
                    WorkbenchView(
                        engine: engine,
                        namespace: modeSwitchNamespace
                    )
                        .transition(.opacity.combined(with: .scale(scale: 0.99)))
                } else {
                    ReadingView(engine: engine, namespace: modeSwitchNamespace)
                        .transition(.opacity.combined(with: .scale(scale: 1.01)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 26)
            .animation(.spring(response: 0.28, dampingFraction: 0.87), value: engine.isWorkbenchMode)
            .redacted(reason: engine.isIntelligenceLoading ? .placeholder : [])
            .overlay {
                if engine.isIntelligenceLoading {
                    LoomShimmerOverlay()
                        .allowsHitTesting(false)
                }
            }
        }
        .task {
            await engine.loadIntelligenceIfNeeded(text: engine.fullText)
        }
    }
}

private struct ReadingView: View {
    @ObservedObject var engine: TactileTextEngine
    let namespace: Namespace.ID

    private let coordinateSpaceName = "loom.reading.surface"
    @State private var wordFrames: [String: CGRect] = [:]
    @State private var isGutterHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            gutter
            paragraphSurface
        }
        .coordinateSpace(name: coordinateSpaceName)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .matchedGeometryEffect(id: "loom.surface", in: namespace, anchor: .topLeading)
        .highPriorityGesture(
            MagnificationGesture()
                .onEnded { scale in
                    guard scale > 1.04 else { return }
                    engine.enterWorkbench(triggeredBy: resolvedActiveSentenceID())
                }
        )
        .onHover { hovering in
            if !hovering {
                engine.clearWordFocus()
                isGutterHovering = false
            }
        }
    }

    private var paragraphSurface: some View {
        let tokens = engine.allWords()

        return ZStack(alignment: .topLeading) {
            WordWrapLayout(
                horizontalSpacing: 0,
                verticalSpacing: LoomInkBond.lineSpacing
            ) {
                ForEach(tokens) { token in
                    InteractiveWordView(
                        token: token,
                        style: style(for: token),
                        isLifted: engine.activeWord?.tokenID == token.id,
                        namespace: namespace,
                        coordinateSpaceName: coordinateSpaceName
                    ) {
                        engine.focusWord(token)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onPreferenceChange(WordFramePreferenceKey.self) { value in
            wordFrames = value
        }
    }

    private var gutter: some View {
        let sentenceFrame = activeSentenceFrame()
        let gutterHeight = max(paragraphFrame()?.height ?? 0, sentenceFrame.height + sentenceFrame.minY + 20)

        return GutterHandle(
            yOffset: sentenceFrame.minY,
            barHeight: sentenceFrame.height,
            scrollDepth: .constant(0),
            isHovering: isGutterHovering,
            onHoverChange: { hovering in
                isGutterHovering = hovering
            },
            onTap: {
                guard let sentenceID = resolvedActiveSentenceID() else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    engine.toggleSplit(for: sentenceID)
                }
            },
            onDragChanged: { value in
                guard let sentenceID = resolvedActiveSentenceID() else { return }
                if !engine.isGutterDragging {
                    engine.beginGutterDrag(on: sentenceID)
                }
                engine.updateGutterDrag(translationY: value.translation.height)
            },
            onDragEnded: { _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    engine.endGutterDrag()
                }
            },
            onScrollDelta: { _ in
                // Zone A (text body) retains normal scrolling behavior in reading mode.
            }
        )
        .frame(
            width: max(LoomInkBond.gutterLaneWidth, 54),
            height: max(gutterHeight, 120),
            alignment: .top
        )
    }

    private func resolvedActiveSentenceID() -> UUID? {
        engine.activeSentenceID ?? engine.sentences.first?.id
    }

    private func style(for token: TactileTextEngine.WordToken) -> WordInkStyle {
        if engine.activeWord?.tokenID == token.id {
            return WordInkStyle(color: .black, showHairlineUnderline: false)
        }
        if engine.tokenIsInActivePhrase(token) {
            // Phrase focus keeps color emphasis only; no sentence-wide underline.
            return WordInkStyle(color: .black, showHairlineUnderline: false)
        }

        let activeSentenceID = resolvedActiveSentenceID()
        if token.sentenceID == activeSentenceID {
            return WordInkStyle(color: Color.black.opacity(0.6), showHairlineUnderline: false)
        }
        return WordInkStyle(color: Color.black.opacity(0.3), showHairlineUnderline: false)
    }

    private func activeSentenceFrame() -> CGRect {
        guard let sentenceID = resolvedActiveSentenceID() else {
            return CGRect(x: 0, y: 0, width: 1, height: 34)
        }
        let rects = engine.words(for: sentenceID).compactMap { wordFrames[$0.id] }
        return union(of: rects) ?? CGRect(x: 0, y: 0, width: 1, height: 34)
    }

    private func paragraphFrame() -> CGRect? {
        union(of: Array(wordFrames.values))
    }
}

private struct WorkbenchView: View {
    @ObservedObject var engine: TactileTextEngine
    let namespace: Namespace.ID

    private let coordinateSpaceName = "loom.workbench.surface"
    @State private var sentenceFrames: [UUID: CGRect] = [:]
    @State private var isGutterHovering = false
    @State private var focusLevel: Double = 0
    @State private var wheelFocusLevel: Double = 0
    @State private var pinchFocusLevel: Double = 0
    @State private var selectedWordID: UUID?
    @State private var scrollDepthSentenceID: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            gutter
            sentenceStack
        }
        .coordinateSpace(name: coordinateSpaceName)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .matchedGeometryEffect(id: "loom.surface", in: namespace, anchor: .topLeading)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: engine.splitDragHeight)
        .onChange(of: engine.scrollDepth) { _, newDepth in
            if newDepth <= 0.0001 {
                scrollDepthSentenceID = nil
            }
        }
        .onHover { hovering in
            if !hovering {
                engine.clearWordFocus()
                isGutterHovering = false
            }
        }
    }

    private var sentenceStack: some View {
        VStack(alignment: .leading, spacing: LoomInkBond.rowSpacing) {
            ForEach(engine.sentences) { sentence in
                VStack(alignment: .leading, spacing: 0) {
                    sentenceRow(sentence)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: SentenceFramePreferenceKey.self,
                                    value: [sentence.id: proxy.frame(in: .named(coordinateSpaceName))]
                                )
                            }
                        )

                    let gapHeight = engine.splitHeight(for: sentence.id)
                    if gapHeight > 0.5 {
                        ShadowSentencesView(sentence: sentence)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: gapHeight, alignment: .topLeading)
                            .padding(.top, 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
        }
        .onPreferenceChange(SentenceFramePreferenceKey.self) { value in
            sentenceFrames = value
        }
    }

    private var gutter: some View {
        let activeID = engine.activeSentenceID ?? engine.sentences.first?.id
        let activeFrame = activeID.flatMap { sentenceFrames[$0] } ?? CGRect(x: 0, y: 0, width: 1, height: 34)
        let stackFrame = union(of: Array(sentenceFrames.values))
        let gutterHeight = max(stackFrame?.height ?? 0, activeFrame.maxY + 20)

        return GutterHandle(
            yOffset: activeFrame.minY,
            barHeight: activeFrame.height,
            scrollDepth: $engine.scrollDepth,
            isHovering: isGutterHovering,
            onHoverChange: { hovering in
                isGutterHovering = hovering
            },
            onTap: {
                guard let sentenceID = activeID else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    engine.toggleSplit(for: sentenceID)
                }
            },
            onDragChanged: { value in
                guard let sentenceID = activeID else { return }
                if !engine.isGutterDragging {
                    engine.beginGutterDrag(on: sentenceID)
                }
                engine.updateGutterDrag(translationY: value.translation.height)
            },
            onDragEnded: { _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    engine.endGutterDrag()
                }
            },
            onScrollDelta: { _ in
                scrollDepthSentenceID = activeID
            }
        )
        .frame(
            width: max(LoomInkBond.gutterLaneWidth, 54),
            height: max(gutterHeight, 160),
            alignment: .top
        )
    }

    @ViewBuilder
    private func sentenceRow(_ sentence: Sentence) -> some View {
        let activeID = engine.activeSentenceID ?? engine.sentences.first?.id
        let targetID = scrollDepthSentenceID ?? activeID
        let sentenceDepth = sentence.id == targetID ? engine.scrollDepth : 0
        let isActiveSentence = sentence.id == activeID

        SentenceView(
            sentence: sentence,
            emphasisOpacity: sentence.id == (engine.activeSentenceID ?? engine.sentences.first?.id) ? 1 : 0.5,
            isActiveSentence: isActiveSentence,
            focusLevel: $focusLevel,
            scrollDepth: sentenceDepth,
            selectedWordID: $selectedWordID,
            onPinchChanged: { value in
                applyPinchValue(value)
            },
            onPinchEnded: {
                endPinch()
            }
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { engine.focusSentence(sentence.id) }
        }
        .onTapGesture {
            engine.focusSentence(sentence.id)
        }
    }

    private func applyPinchValue(_ value: CGFloat) {
        pinchFocusLevel = clampFocus(Double((value - 1) * 5))
        recomputeFocusLevel()
    }

    private func endPinch() {
        pinchFocusLevel = 0
        recomputeFocusLevel()
    }

    private func applyWheelDelta(_ deltaY: CGFloat) {
        // Positive scroll delta maps toward ladder, negative toward skeleton.
        let focusDelta = Double(deltaY) / 120
        wheelFocusLevel = clampFocus(wheelFocusLevel + focusDelta)
        recomputeFocusLevel()
    }

    private func recomputeFocusLevel() {
        let previous = focusLevel
        let next = clampFocus(wheelFocusLevel + pinchFocusLevel)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            focusLevel = next
        }
        emitThresholdHapticIfNeeded(from: previous, to: next)
    }

    private func emitThresholdHapticIfNeeded(from previous: Double, to next: Double) {
        let crossedUpper = (previous <= 0.5 && next > 0.5) || (previous > 0.5 && next <= 0.5)
        let crossedLower = (previous >= -0.5 && next < -0.5) || (previous < -0.5 && next >= -0.5)
        if crossedUpper || crossedLower {
            ThresholdHaptics.pulse()
        }
    }

    private func clampFocus(_ value: Double) -> Double {
        min(1, max(-1, value))
    }
}

private struct InteractiveWordView: View {
    let token: TactileTextEngine.WordToken
    let style: WordInkStyle
    let isLifted: Bool
    let namespace: Namespace.ID
    let coordinateSpaceName: String
    let onActivate: () -> Void

    private var scale: CGFloat {
        isLifted ? 1.015 : 1
    }

    private var translationVisible: Bool {
        guard let translation = token.translation else { return false }
        return !translation.isEmpty && isLifted
    }

    var body: some View {
        Text(token.text)
            .font(LoomInkBond.font)
            .foregroundStyle(style.color)
            .padding(.horizontal, LoomInkBond.wordSpacing / 2)
            .background {
                if style.showHairlineUnderline {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(Color.black)
                            .frame(height: 1)
                    }
                }
            }
            .scaleEffect(scale, anchor: .center)
            .offset(y: isLifted ? -1.5 : 0)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(isLifted ? 0.26 : 0))
                    .frame(height: 1)
                    .offset(y: isLifted ? 3 : 0)
                    .opacity(isLifted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if let translation = token.translation, !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color.black.opacity(0.74))
                        .fixedSize(horizontal: true, vertical: false)
                        .opacity(translationVisible ? 1 : 0)
                        .offset(y: 18)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.2), value: translationVisible)
                }
            }
            .zIndex(isLifted ? 20 : 1)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    onActivate()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        onActivate()
                    }
            )
            .onTapGesture {
                onActivate()
            }
            .matchedGeometryEffect(
                id: "word.\(token.id)",
                in: namespace,
                anchor: .center
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WordFramePreferenceKey.self,
                        value: [token.id: proxy.frame(in: .named(coordinateSpaceName))]
                    )
                }
            )
    }
}

private struct GutterHandle: View {
    let yOffset: CGFloat
    let barHeight: CGFloat
    @Binding var scrollDepth: Double
    let isHovering: Bool
    let onHoverChange: (Bool) -> Void
    let onTap: () -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void
    let onScrollDelta: (CGFloat) -> Void

    #if os(macOS)
    @State private var hasCursorOverride = false
    #endif

    var body: some View {
        ZStack(alignment: .top) {
            // Full-height hit canvas so yOffset tracks sentence geometry correctly.
            Color.clear
            Capsule(style: .continuous)
                .fill(isHovering ? Color.black.opacity(0.72) : Color.gray.opacity(0.9))
                .frame(width: isHovering ? 6 : 4, height: max(barHeight, 30))
                .offset(x: 5, y: yOffset)
        }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .background(ScrollWheelCaptureLayer(isEnabled: isHovering, onScroll: handleScroll))
        .contentShape(Rectangle())
        .onHover { hovering in
            onHoverChange(hovering)
            #if os(macOS)
            if hovering, !hasCursorOverride {
                NSCursor.resizeUpDown.push()
                hasCursorOverride = true
            } else if !hovering, hasCursorOverride {
                NSCursor.pop()
                hasCursorOverride = false
            }
            #endif
        }
        .onTapGesture {
            onTap()
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged(onDragChanged)
                .onEnded(onDragEnded)
        )
        #if os(macOS)
        .onDisappear {
            if hasCursorOverride {
                NSCursor.pop()
                hasCursorOverride = false
            }
        }
        #endif
    }

    private func handleScroll(_ deltaY: CGFloat) {
        // Fine-grained wheel control in [0, 1].
        let nextDepth = clampDepth(scrollDepth + Double(deltaY) * 0.0025)
        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.9)) {
            scrollDepth = nextDepth
        }
        onScrollDelta(deltaY)
    }

    private func clampDepth(_ raw: Double) -> Double {
        min(1, max(0, raw))
    }
}

private struct LogicLadderView: View {
    let lines: [TactileTextEngine.LogicLine]
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.label)
                        .font(.system(size: 11, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.black.opacity(isActive ? 0.46 : 0.3))
                    Text(line.text)
                        .font(LoomInkBond.font)
                        .foregroundStyle(Color.black.opacity(isActive ? 0.72 : 0.3))
                }
                .padding(.leading, line.indent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if os(macOS)
private struct ScrollWheelCaptureLayer: NSViewRepresentable {
    let isEnabled: Bool
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCaptureNSView {
        let view = ScrollCaptureNSView()
        view.onScroll = onScroll
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.isEnabled = isEnabled
    }
}

private final class ScrollCaptureNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    var isEnabled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 12
        onScroll?(delta)
    }
}
#elseif os(iOS)
private struct ScrollWheelCaptureLayer: UIViewRepresentable {
    let isEnabled: Bool
    let onScroll: (CGFloat) -> Void

    func makeUIView(context: Context) -> ScrollCaptureUIView {
        let view = ScrollCaptureUIView()
        view.isEnabled = isEnabled
        view.onScroll = onScroll
        return view
    }

    func updateUIView(_ uiView: ScrollCaptureUIView, context: Context) {
        uiView.isEnabled = isEnabled
        uiView.onScroll = onScroll
    }
}

private final class ScrollCaptureUIView: UIView {
    var onScroll: ((CGFloat) -> Void)?
    var isEnabled = false {
        didSet {
            panRecognizer.isEnabled = isEnabled
            if !isEnabled {
                lastTranslationY = 0
            }
        }
    }

    private var lastTranslationY: CGFloat = 0
    private lazy var panRecognizer: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        if #available(iOS 13.4, *) {
            gesture.allowedScrollTypesMask = [.continuous, .discrete]
        }
        return gesture
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addGestureRecognizer(panRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isEnabled else { return }

        let y = gesture.translation(in: self).y
        let delta = y - lastTranslationY
        lastTranslationY = y

        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            lastTranslationY = 0
        }

        guard abs(delta) > 0.01 else { return }
        // Drag up => positive focus shift (towards ladder).
        onScroll?(-delta)
    }
}
#else
private struct ScrollWheelCaptureLayer: View {
    let isEnabled: Bool
    let onScroll: (CGFloat) -> Void

    var body: some View {
        Color.clear
    }
}
#endif

private enum ThresholdHaptics {
    static func pulse() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred(intensity: 0.45)
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }
}

private struct SentenceView: View {
    let sentence: Sentence
    let emphasisOpacity: CGFloat
    let isActiveSentence: Bool
    @Binding var focusLevel: Double
    let scrollDepth: Double
    @Binding var selectedWordID: UUID?
    let onPinchChanged: (CGFloat) -> Void
    let onPinchEnded: () -> Void

    @State private var opticalMode: WorkbenchOpticalMode = .reading
    @GestureState private var magnification: CGFloat = 1.0
    @State private var hoveredWordID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                readingLayer
                    .opacity(opticalMode == .ladder ? 0 : 1)
                    .blur(radius: opticalMode == .ladder ? 2 : 0)
                    .scaleEffect(opticalMode == .ladder ? 0.98 : 1, anchor: .center)

                if opticalMode == .ladder {
                    ladderLayer
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }

            if sentenceTranslationOpacity > 0 {
                Text(sentence.translation)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.black.opacity(0.66))
                    .opacity(sentenceTranslationOpacity)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: opticalMode)
        .animation(.easeOut(duration: 0.18), value: scrollDepth)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isActiveSentence)
        .gesture(magnificationGesture)
        .onChange(of: focusLevel) { _, newValue in
            opticalMode = mode(for: newValue)
        }
        .onChange(of: opticalMode) { _, newMode in
            if newMode == .ladder {
                hoveredWordID = nil
            }
        }
        .onAppear {
            opticalMode = mode(for: focusLevel)
        }
    }

    private var readingLayer: some View {
        let pinnedWord = sentence.wordData.first { $0.id == selectedWordID }
        let partnerIDs = Set(pinnedWord?.collocationPartners ?? [])
        let chunkPadding = max(0, CGFloat(scrollDepth - 0.3) * 20)
        let activeLineSpacing: CGFloat = isActiveSentence ? 20 : 5

        return WordWrapLayout(
            horizontalSpacing: 0,
            verticalSpacing: activeLineSpacing
        ) {
            ForEach(Array(sentence.wordData.enumerated()), id: \.element.id) { index, word in
                WordView(
                    word: word,
                    isCore: coreFlag(at: index),
                    opticalMode: opticalMode,
                    frequencyBand: word.frequencyBand,
                    scrollDepth: scrollDepth,
                    emphasisOpacity: emphasisOpacity,
                    isHovering: hoveredWordID == word.id && opticalMode != .ladder,
                    isPinned: selectedWordID == word.id,
                    isPartner: partnerIDs.contains(word.id) && selectedWordID != word.id,
                    onHoverChange: { hovering in
                        guard opticalMode != .ladder else { return }
                        if hovering {
                            hoveredWordID = word.id
                        } else if hoveredWordID == word.id {
                            hoveredWordID = nil
                        }
                    },
                    onTap: {
                        togglePin(for: word.id)
                    }
                )
                .padding(.trailing, sentence.chunkIndices.contains(index) ? chunkPadding : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, isActiveSentence ? 20 : 0)
    }

    private var ladderLayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sentence.ladderSegments) { segment in
                Text(segment.text)
                    .padding(.leading, CGFloat(segment.indentLevel * 20))
                    .font(.system(size: 22, design: .serif))
                    .foregroundStyle(Color.black.opacity(emphasisOpacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onChanged { value in
                onPinchChanged(value)
            }
            .onEnded { _ in
                onPinchEnded()
            }
    }

    private func coreFlag(at index: Int) -> Bool {
        guard index >= 0, index < sentence.isCoreWord.count else { return true }
        return sentence.isCoreWord[index]
    }

    private func togglePin(for wordID: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            if selectedWordID == wordID {
                selectedWordID = nil
            } else {
                selectedWordID = wordID
            }
        }
    }

    private func mode(for focusLevel: Double) -> WorkbenchOpticalMode {
        if focusLevel > 0.5 {
            return .ladder
        }
        if focusLevel < -0.5 {
            return .skeleton
        }
        return .reading
    }

    private var sentenceTranslationOpacity: Double {
        let value = (scrollDepth - 0.1) * 5
        return min(1, max(0, value))
    }
}

private struct WordView: View {
    let word: Word
    let isCore: Bool
    let opticalMode: WorkbenchOpticalMode
    let frequencyBand: FrequencyBand
    let scrollDepth: Double
    let emphasisOpacity: CGFloat
    let isHovering: Bool
    let isPinned: Bool
    let isPartner: Bool
    let onHoverChange: (Bool) -> Void
    let onTap: () -> Void

    private var isGhosted: Bool {
        opticalMode == .skeleton && !isCore
    }

    private var isLifted: Bool {
        isHovering || isPinned
    }

    private var wordOpacity: CGFloat {
        if isGhosted { return 0.1 }
        if opticalMode == .skeleton { return 1.0 }
        return emphasisOpacity
    }

    private var frequencyHeatIntensity: CGFloat {
        let normalized = (scrollDepth - 0.6) / 0.4
        return min(1, max(0, CGFloat(normalized)))
    }

    private var frequencyBandOpacity: CGFloat {
        switch frequencyBand {
        case .A:
            return 0.3
        case .B:
            return 0.45
        case .C:
            return 0.6
        case .D:
            return 0.8
        case .E:
            return 1.0
        }
    }

    private var finalWordOpacity: CGFloat {
        let blend = (1 - frequencyHeatIntensity) + (frequencyHeatIntensity * frequencyBandOpacity)
        return wordOpacity * blend
    }

    private var scale: CGFloat {
        if isLifted {
            return 1.015
        }
        if isPartner {
            return 1.02
        }
        return 1
    }

    private var translationText: String? {
        guard let translation = word.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translation.isEmpty else {
            return nil
        }
        return translation
    }

    private var synonymText: String? {
        guard let synonym = word.synonym?.trimmingCharacters(in: .whitespacesAndNewlines),
              !synonym.isEmpty else {
            return nil
        }
        return synonym
    }

    private var intelligenceVisible: Bool {
        guard translationText != nil || synonymText != nil else { return false }
        return isLifted
    }

    private var liftOffsetY: CGFloat {
        if isLifted {
            return -1.5
        }
        if isPartner {
            return -0.7
        }
        return 0
    }

    var body: some View {
        Text(word.text)
            .font(LoomInkBond.font)
            .fontWeight(opticalMode == .skeleton && isCore ? .semibold : .regular)
            .foregroundStyle(Color.black)
            .opacity(finalWordOpacity)
            .blur(radius: isGhosted ? 1 : 0)
            .padding(.horizontal, LoomInkBond.wordSpacing / 2)
            .scaleEffect(scale, anchor: .center)
            .offset(y: liftOffsetY)
            .zIndex((isHovering || isPinned) ? 20 : (isPartner ? 8 : 1))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(isLifted ? 0.26 : (isPartner ? 0.16 : 0)))
                    .frame(height: 1)
                    .offset(y: isLifted ? 3 : (isPartner ? 2 : 0))
                    .opacity((isLifted || isPartner) ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if translationText != nil || synonymText != nil {
                    VStack(spacing: 1.5) {
                        if let translationText {
                            Text(translationText)
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(Color.gray)
                        }
                        if let synonymText {
                            Text(synonymText)
                                .font(.system(size: 9, weight: .regular))
                                .italic()
                                .foregroundStyle(Color.blue.opacity(0.8))
                        }
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: true, vertical: false)
                    .zIndex(100)
                    .opacity(intelligenceVisible ? 1 : 0)
                    .offset(y: 32)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.2), value: intelligenceVisible)
                }
            }
            .contentShape(Rectangle())
            .onHover(perform: onHoverChange)
            .onTapGesture(perform: onTap)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isLifted)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isPartner)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: opticalMode)
    }
}

private struct ShadowSentencesView: View {
    let sentence: Sentence

    private var variations: [Sentence.ShadowVariation] {
        if sentence.shadowVariations.count == 3 {
            return sentence.shadowVariations
        }
        return [
            Sentence.ShadowVariation(tone: .kernel, text: sentence.text),
            Sentence.ShadowVariation(tone: .paraphrase, text: sentence.text),
            Sentence.ShadowVariation(tone: .lexical, text: sentence.text)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(variations) { variation in
                Text(variation.text)
            }
        }
        .font(.system(size: 17, design: .serif))
        .foregroundStyle(Color.black.opacity(0.34))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct LoomShimmerOverlay: View {
    @State private var phase: CGFloat = -0.8

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.16),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .rotationEffect(.degrees(18))
            .offset(x: phase * proxy.size.width * 2)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
        }
    }
}

private struct WordWrapLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let layout = arranged(in: proposal.width, subviews: subviews)
        return layout.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let layout = arranged(in: bounds.width, subviews: subviews)
        for item in layout.items {
            subviews[item.index].place(
                at: CGPoint(
                    x: bounds.minX + item.origin.x,
                    y: bounds.minY + item.origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func arranged(in proposedWidth: CGFloat?, subviews: Subviews) -> (size: CGSize, items: [PlacedItem]) {
        let maxWidth = (proposedWidth?.isFinite == true) ? max(1, proposedWidth ?? 1) : .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0
        var items: [PlacedItem] = []

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let shouldWrap = x > 0 && (x + size.width > maxWidth)

            if shouldWrap {
                maxLineWidth = max(maxLineWidth, x - horizontalSpacing)
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }

            items.append(
                PlacedItem(
                    index: index,
                    origin: CGPoint(x: x, y: y),
                    size: size
                )
            )

            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }

        maxLineWidth = max(maxLineWidth, x - horizontalSpacing)
        let measuredWidth = proposedWidth ?? max(maxLineWidth, 1)
        let measuredHeight = y + lineHeight

        return (CGSize(width: measuredWidth, height: max(measuredHeight, 1)), items)
    }

    private struct PlacedItem {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }
}

private struct WordFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SentenceFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private func union(of rects: [CGRect]) -> CGRect? {
    guard let first = rects.first else { return nil }
    return rects.dropFirst().reduce(first) { partial, rect in
        partial.union(rect)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

private enum DemoText {
    static let paragraph =
        "Language behaves like weather: stable from afar, unstable up close. We read for continuity, yet every sentence carries hidden hinges. Pull one margin, and the paragraph opens into a workbench where meaning can be tested, stretched, and rebuilt."
}
