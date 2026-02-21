import Foundation
import SwiftUI

enum FrequencyBand: String, Codable, CaseIterable {
    case A
    case B
    case C
    case D
    case E
}

struct Word: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    var definition: String?
    var synonym: String?
    var translation: String?
    var frequencyBand: FrequencyBand
    var collocationPartners: [UUID]

    init(
        id: UUID = UUID(),
        text: String,
        definition: String? = nil,
        synonym: String? = nil,
        translation: String? = nil,
        frequencyBand: FrequencyBand = .B,
        collocationPartners: [UUID] = []
    ) {
        self.id = id
        self.text = text
        self.definition = definition
        self.synonym = synonym
        self.translation = translation
        self.frequencyBand = frequencyBand
        self.collocationPartners = collocationPartners
    }
}

struct Sentence: Identifiable, Equatable {
    struct ShadowVariation: Identifiable, Equatable, Codable {
        enum Tone: String, Codable, CaseIterable {
            case kernel
            case paraphrase
            case lexical
        }

        let id: UUID
        let tone: Tone
        let text: String

        init(id: UUID = UUID(), tone: Tone, text: String) {
            self.id = id
            self.tone = tone
            self.text = text
        }
    }

    let id: UUID
    let rawText: String
    let wordData: [Word]
    let translation: String
    let chunkIndices: [Int]
    let shadowVariations: [ShadowVariation]
    let isCoreWord: [Bool]
    let ladderSegments: [LadderSegment]
    var isExpanded: Bool
    var isReflowed: Bool

    struct LadderSegment: Identifiable, Equatable {
        let id: UUID
        let text: String
        let indentLevel: Int

        init(id: UUID = UUID(), text: String, indentLevel: Int) {
            self.id = id
            self.text = text
            self.indentLevel = indentLevel
        }
    }

    init(
        id: UUID = UUID(),
        rawText: String,
        wordData: [Word] = [],
        translation: String? = nil,
        chunkIndices: [Int] = [],
        shadowVariations: [ShadowVariation] = [],
        isCoreWord: [Bool],
        ladderSegments: [LadderSegment],
        isExpanded: Bool = false,
        isReflowed: Bool = false
    ) {
        let resolvedWords = wordData.isEmpty ? Self.buildDefaultWords(from: rawText) : wordData

        self.id = id
        self.rawText = rawText
        self.wordData = resolvedWords
        self.translation = translation ?? rawText
        self.chunkIndices = chunkIndices
        self.shadowVariations = shadowVariations
        self.isCoreWord = isCoreWord
        self.ladderSegments = ladderSegments
        self.isExpanded = isExpanded
        self.isReflowed = isReflowed
    }

    var words: [String] {
        if !wordData.isEmpty {
            return wordData.map(\.text)
        }
        return rawText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    // Compatibility for existing rendering logic.
    var text: String {
        rawText
    }

    private static func buildDefaultWords(from rawText: String) -> [Word] {
        rawText
            .split(whereSeparator: { $0.isWhitespace })
            .map { Word(text: String($0)) }
    }
}

@MainActor
final class TactileTextEngine: ObservableObject {
    struct WordToken: Identifiable, Equatable, Hashable {
        let id: String
        let wordID: UUID?
        let sentenceID: UUID
        let indexInSentence: Int
        let text: String
        let translation: String?
        let collocationPartners: [UUID]
    }

    struct ActiveWord: Equatable {
        let sentenceID: UUID
        let tokenID: String
        let wordIndex: Int
        let text: String
    }

    struct ActivePhrase: Equatable {
        let sentenceID: UUID
        let range: ClosedRange<Int>
    }

    struct LogicLine: Identifiable, Equatable {
        let id: Int
        let label: String
        let text: String
        let indent: CGFloat
    }

    @Published private(set) var fullText: String
    @Published var sentences: [Sentence]
    @Published var isWorkbenchMode = false
    @Published var activeSentenceID: UUID?
    @Published var activeWord: ActiveWord?
    @Published var activePhrase: ActivePhrase?
    @Published var isGutterDragging = false
    @Published var splitDragHeight: CGFloat = 0
    @Published var scrollDepth: Double = 0
    @Published var isIntelligenceLoading = false
    @Published var intelligenceError: String?

    let splitActivationThreshold: CGFloat = 24
    let splitCloseDragThreshold: CGFloat = -18
    let maxSplitDragHeight: CGFloat = 240
    let restingSplitHeight: CGFloat = 132
    let splitTapThreshold: CGFloat = 4

    private var sentenceTokens: [UUID: [WordToken]] = [:]
    private var sentenceIndexByID: [UUID: Int] = [:]
    private var latestGutterTranslationY: CGFloat = 0
    private let intelligence = LoomIntelligence()
    private var hasRequestedIntelligence = false

    init(fullText: String) {
        self.fullText = fullText
        self.sentences = Self.parseSentences(from: fullText)
        rebuildCaches()
        activeSentenceID = sentences.first?.id
    }

    init(sentences: [Sentence], fullText: String? = nil) {
        self.sentences = sentences
        self.fullText = fullText ?? sentences.map(\.rawText).joined(separator: " ")
        rebuildCaches()
        activeSentenceID = sentences.first?.id
    }

    func reload(text: String) {
        fullText = text
        sentences = Self.parseSentences(from: text)
        rebuildCaches()
        activeSentenceID = sentences.first?.id
        activeWord = nil
        activePhrase = nil
        isWorkbenchMode = false
        isGutterDragging = false
        splitDragHeight = 0
        scrollDepth = 0
        intelligenceError = nil
        hasRequestedIntelligence = false
    }

    func loadIntelligenceIfNeeded(text: String) async {
        guard !hasRequestedIntelligence else { return }
        guard LoomSecrets.hasAPIKey else { return }
        hasRequestedIntelligence = true
        await loadIntelligence(text: text)
    }

    func loadIntelligence(text: String) async {
        isIntelligenceLoading = true
        intelligenceError = nil
        defer { isIntelligenceLoading = false }

        do {
            let analyzed = try await intelligence.analyze(rawText: text)
            guard !analyzed.isEmpty else {
                intelligenceError = "LoomIntelligence returned no sentences."
                return
            }
            fullText = text
            sentences = analyzed
            rebuildCaches()
            if let activeSentenceID, sentenceIndexByID[activeSentenceID] == nil {
                self.activeSentenceID = sentences.first?.id
            } else if self.activeSentenceID == nil {
                self.activeSentenceID = sentences.first?.id
            }
        } catch {
            intelligenceError = error.localizedDescription
        }
    }

    nonisolated static func parseSentences(from raw: String) -> [Sentence] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let pattern = #"[^.!?]+(?:[.!?]+["'”’)]*)?"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = regex?.matches(in: trimmed, options: [], range: nsRange) ?? []

        let parsed = matches.compactMap { match -> Sentence? in
            guard let range = Range(match.range, in: trimmed) else { return nil }
            let text = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let words = tokenizeWords(from: text)
            let coreMask = buildCoreWordMask(from: words)
            let ladder = buildLadderSegments(from: text, words: words)
            return Sentence(
                rawText: text,
                isCoreWord: coreMask,
                ladderSegments: ladder
            )
        }

        if parsed.isEmpty {
            let words = tokenizeWords(from: trimmed)
            return [
                Sentence(
                    rawText: trimmed,
                    isCoreWord: buildCoreWordMask(from: words),
                    ladderSegments: buildLadderSegments(from: trimmed, words: words)
                )
            ]
        }
        return parsed
    }

    func words(for sentenceID: UUID) -> [WordToken] {
        sentenceTokens[sentenceID] ?? []
    }

    func allWords() -> [WordToken] {
        sentences.flatMap { sentenceTokens[$0.id] ?? [] }
    }

    func focusSentence(_ sentenceID: UUID) {
        guard sentenceTokens[sentenceID] != nil else { return }
        activeSentenceID = sentenceID
        if activeWord?.sentenceID != sentenceID {
            activeWord = nil
            activePhrase = nil
        }
    }

    func focusWord(_ token: WordToken) {
        activeSentenceID = token.sentenceID
        activeWord = ActiveWord(
            sentenceID: token.sentenceID,
            tokenID: token.id,
            wordIndex: token.indexInSentence,
            text: token.text
        )
        activePhrase = ActivePhrase(
            sentenceID: token.sentenceID,
            range: phraseRange(sentenceID: token.sentenceID, around: token.indexInSentence)
        )
    }

    func clearWordFocus() {
        activeWord = nil
        activePhrase = nil
    }

    func tokenIsInActivePhrase(_ token: WordToken) -> Bool {
        guard let phrase = activePhrase, phrase.sentenceID == token.sentenceID else { return false }
        return phrase.range.contains(token.indexInSentence)
    }

    func enterWorkbench(triggeredBy sentenceID: UUID?) {
        if let sentenceID {
            focusSentence(sentenceID)
        } else if activeSentenceID == nil {
            activeSentenceID = sentences.first?.id
        }
        isWorkbenchMode = true
    }

    func exitWorkbench() {
        isWorkbenchMode = false
        isGutterDragging = false
        splitDragHeight = 0
        latestGutterTranslationY = 0
        scrollDepth = 0
        collapseAllSplits()
    }

    func beginGutterDrag(on sentenceID: UUID) {
        focusSentence(sentenceID)
        isGutterDragging = true
        latestGutterTranslationY = 0
        if isExpanded(sentenceID) {
            splitDragHeight = max(restingSplitHeight, splitDragHeight)
        } else {
            splitDragHeight = 0
        }
    }

    func updateGutterDrag(translationY: CGFloat) {
        latestGutterTranslationY = translationY
        guard let activeSentenceID else { return }

        if isExpanded(activeSentenceID) {
            let draftHeight = restingSplitHeight + translationY
            splitDragHeight = max(0, min(maxSplitDragHeight, draftHeight))
            return
        }

        splitDragHeight = max(0, min(maxSplitDragHeight, translationY))
    }

    func endGutterDrag() {
        defer {
            isGutterDragging = false
            latestGutterTranslationY = 0
        }
        guard let activeSentenceID else {
            splitDragHeight = 0
            return
        }

        let isTap = abs(latestGutterTranslationY) <= splitTapThreshold

        if isExpanded(activeSentenceID) {
            if isTap || latestGutterTranslationY <= splitCloseDragThreshold {
                collapseSplit(for: activeSentenceID)
                splitDragHeight = 0
            } else {
                splitDragHeight = restingSplitHeight
            }
            return
        }

        if isTap || splitDragHeight >= splitActivationThreshold || latestGutterTranslationY >= splitActivationThreshold {
            setExpandedSentence(activeSentenceID)
            splitDragHeight = max(restingSplitHeight, splitDragHeight)
            isWorkbenchMode = true
            return
        }

        splitDragHeight = 0
    }

    func toggleSplit(for sentenceID: UUID) {
        focusSentence(sentenceID)
        if isExpanded(sentenceID) {
            collapseSplit(for: sentenceID)
            splitDragHeight = 0
            return
        }

        setExpandedSentence(sentenceID)
        splitDragHeight = restingSplitHeight
        isWorkbenchMode = true
    }

    func splitHeight(for sentenceID: UUID) -> CGFloat {
        if isExpanded(sentenceID) {
            if activeSentenceID == sentenceID, isGutterDragging {
                return max(0, splitDragHeight)
            }
            if activeSentenceID == sentenceID {
                return max(restingSplitHeight, splitDragHeight)
            }
            return restingSplitHeight
        }
        if isGutterDragging, activeSentenceID == sentenceID {
            return splitDragHeight
        }
        return 0
    }

    func collapseSplit(for sentenceID: UUID) {
        updateSentence(sentenceID) { sentence in
            sentence.isExpanded = false
        }
        if activeSentenceID == sentenceID {
            splitDragHeight = 0
        }
    }

    func collapseAllSplits() {
        for idx in sentences.indices {
            sentences[idx].isExpanded = false
        }
        splitDragHeight = 0
        latestGutterTranslationY = 0
    }

    func applyPinch(scale: CGFloat, sentenceID: UUID) {
        focusSentence(sentenceID)
        if scale > 1.05 {
            isWorkbenchMode = true
            updateSentence(sentenceID) { sentence in
                sentence.isReflowed = true
            }
        } else if scale < 0.95 {
            updateSentence(sentenceID) { sentence in
                sentence.isReflowed = false
            }
        }
    }

    func logicLadderLines(for sentenceID: UUID) -> [LogicLine] {
        guard let sentence = sentences.first(where: { $0.id == sentenceID }) else {
            return []
        }

        let clauses = splitClauses(in: sentence.text)
        let line1 = clauses[safe: 0] ?? sentence.text
        let line2 = clauses[safe: 1] ?? fallbackSubClause(in: sentence.text)
        let line3 = clauses.dropFirst(2).joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = line3.isEmpty ? fallbackDetail(in: sentence.text) : line3

        return [
            LogicLine(id: 0, label: "Main Clause", text: line1, indent: 0),
            LogicLine(id: 1, label: "Sub-clause", text: line2, indent: 20),
            LogicLine(id: 2, label: "Detail", text: detail, indent: 40)
        ]
    }

    private func setExpandedSentence(_ sentenceID: UUID) {
        for idx in sentences.indices {
            sentences[idx].isExpanded = sentences[idx].id == sentenceID
        }
    }

    private func isExpanded(_ sentenceID: UUID) -> Bool {
        guard let idx = sentenceIndexByID[sentenceID] else { return false }
        return sentences[idx].isExpanded
    }

    private func updateSentence(_ sentenceID: UUID, update: (inout Sentence) -> Void) {
        guard let idx = sentenceIndexByID[sentenceID] else { return }
        update(&sentences[idx])
    }

    private func rebuildCaches() {
        sentenceIndexByID = Dictionary(uniqueKeysWithValues: sentences.enumerated().map { ($1.id, $0) })
        sentenceTokens.removeAll(keepingCapacity: true)

        for sentence in sentences {
            sentenceTokens[sentence.id] = Self.tokenize(sentence: sentence)
        }
    }

    private func phraseRange(sentenceID: UUID, around wordIndex: Int) -> ClosedRange<Int> {
        guard let tokens = sentenceTokens[sentenceID], !tokens.isEmpty else {
            return wordIndex ... wordIndex
        }

        let clampedIndex = min(max(wordIndex, 0), tokens.count - 1)
        var lower = clampedIndex
        var upper = clampedIndex

        while lower > 0 {
            let boundaryCandidate = tokens[lower - 1].text
            if endsPhrase(boundaryCandidate) { break }
            lower -= 1
        }

        while upper < tokens.count - 1 {
            let boundaryCandidate = tokens[upper].text
            if endsPhrase(boundaryCandidate) { break }
            upper += 1
        }

        if lower == upper, tokens.count > 1 {
            let fallbackLower = max(0, clampedIndex - 1)
            let fallbackUpper = min(tokens.count - 1, clampedIndex + 1)
            return fallbackLower ... fallbackUpper
        }

        return lower ... upper
    }

    private func endsPhrase(_ word: String) -> Bool {
        let punctuation = [",", ";", ":", "—", "–"]
        return punctuation.contains { word.hasSuffix($0) }
    }

    private static func tokenize(sentence: Sentence) -> [WordToken] {
        let pieces = sentence.words

        return pieces.enumerated().map { index, piece in
            let wordMetadata: Word? = index < sentence.wordData.count ? sentence.wordData[index] : nil
            return WordToken(
                id: "\(sentence.id.uuidString)-\(index)",
                wordID: wordMetadata?.id,
                sentenceID: sentence.id,
                indexInSentence: index,
                text: piece,
                translation: wordMetadata?.translation,
                collocationPartners: wordMetadata?.collocationPartners ?? []
            )
        }
    }

    private func splitClauses(in sentence: String) -> [String] {
        let pieces = sentence
            .split(whereSeparator: { ",;:".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if pieces.isEmpty {
            return [sentence.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return pieces
    }

    private func fallbackSubClause(in sentence: String) -> String {
        let words = sentence
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard words.count > 4 else { return sentence }

        let middleStart = min(2, words.count - 1)
        let middleEnd = min(words.count - 2, middleStart + 5)
        return words[middleStart ... middleEnd].joined(separator: " ")
    }

    private func fallbackDetail(in sentence: String) -> String {
        let words = sentence
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard words.count > 5 else { return sentence }

        let tailStart = max(0, words.count - 6)
        return words[tailStart...].joined(separator: " ")
    }

    nonisolated private static func tokenizeWords(from text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    nonisolated private static func buildCoreWordMask(from words: [String]) -> [Bool] {
        guard !words.isEmpty else { return [] }

        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "if",
            "in", "into", "is", "it", "its", "of", "on", "or", "so", "that", "the", "their",
            "then", "there", "they", "this", "to", "was", "were", "while", "with", "we", "you"
        ]

        var mask = words.map { word -> Bool in
            let cleaned = normalizedWord(word)
            guard !cleaned.isEmpty else { return false }
            if stopWords.contains(cleaned) {
                return false
            }
            if cleaned.count >= 5 {
                return true
            }
            return cleaned.contains { $0.isUppercase }
        }

        if !mask.contains(true) {
            // Keep at least one content anchor.
            if let maxIndex = words.indices.max(by: { words[$0].count < words[$1].count }) {
                mask[maxIndex] = true
            }
        }
        return mask
    }

    nonisolated private static func normalizedWord(_ word: String) -> String {
        word
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
    }

    nonisolated private static func buildLadderSegments(from text: String, words: [String]) -> [Sentence.LadderSegment] {
        let clauses = text
            .split(whereSeparator: { ",;:—–".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if clauses.count >= 3 {
            return [
                Sentence.LadderSegment(text: clauses[0], indentLevel: 0),
                Sentence.LadderSegment(text: clauses[1], indentLevel: 1),
                Sentence.LadderSegment(text: clauses.dropFirst(2).joined(separator: ", "), indentLevel: 2)
            ]
        }

        if clauses.count == 2 {
            let secondWords = clauses[1].split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let detailStart = max(0, secondWords.count / 2)
            let detail = secondWords[detailStart...].joined(separator: " ")
            return [
                Sentence.LadderSegment(text: clauses[0], indentLevel: 0),
                Sentence.LadderSegment(text: clauses[1], indentLevel: 1),
                Sentence.LadderSegment(text: detail.isEmpty ? clauses[1] : detail, indentLevel: 2)
            ]
        }

        if words.count <= 6 {
            return [
                Sentence.LadderSegment(text: text, indentLevel: 0)
            ]
        }

        let firstCut = max(2, words.count / 3)
        let secondCut = max(firstCut + 1, (words.count * 2) / 3)

        let first = words[0 ..< firstCut].joined(separator: " ")
        let second = words[firstCut ..< secondCut].joined(separator: " ")
        let third = words[secondCut ..< words.count].joined(separator: " ")

        return [
            Sentence.LadderSegment(text: first, indentLevel: 0),
            Sentence.LadderSegment(text: second, indentLevel: 1),
            Sentence.LadderSegment(text: third, indentLevel: 2)
        ].filter { !$0.text.isEmpty }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
