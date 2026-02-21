import Foundation

enum MockDataGenerator {
    static func makeSentences() -> [Sentence] {
        let sentenceSpecs: [(
            raw: String,
            translation: String,
            shadow: (kernel: String, paraphrase: String, lexical: String),
            rare: Set<String>
        )] = [
            (
                raw: "Whoever fights with monsters should see to it that he does not become a monster.",
                translation: "与怪物搏斗的人，必须警惕自己不要变成怪物。",
                shadow: (
                    kernel: "Fight monsters without becoming one.",
                    paraphrase: "In resisting evil, guard your own character so you do not mirror it.",
                    lexical: "When you battle monsters, do not turn into a monster yourself."
                ),
                rare: ["monsters", "monster", "whoever"]
            ),
            (
                raw: "The abyss is not only a darkness before us; it is also a mirror that asks what habits of fear we carry into every judgment.",
                translation: "深渊不仅是眼前的黑暗；它也是一面镜子，追问我们把怎样的恐惧习惯带入每一次判断。",
                shadow: (
                    kernel: "The abyss is darkness and a mirror of fear-based judgment.",
                    paraphrase: "The void is not only frightening; it reveals how fear shapes what we judge.",
                    lexical: "The abyss is dark, and it reflects the fearful habits inside our judgments."
                ),
                rare: ["abyss", "judgment", "habits"]
            ),
            (
                raw: "A disciplined spirit learns to examine its motives before it condemns the world.",
                translation: "有纪律的精神会在谴责世界之前先审视自己的动机。",
                shadow: (
                    kernel: "Self-examination must precede condemnation.",
                    paraphrase: "A disciplined mind checks its motives before blaming the world.",
                    lexical: "Before judging the world, a trained spirit studies its own motives."
                ),
                rare: ["disciplined", "motives", "condemns"]
            ),
            (
                raw: "No price is too high for the privilege of owning yourself, yet ownership is earned through repeated acts of honesty, not declarations.",
                translation: "为拥有你自己这一特权，任何代价都不算太高；但这种拥有要靠反复的诚实行动去赢得，而不是宣言。",
                shadow: (
                    kernel: "Self-ownership is costly and earned by repeated honesty.",
                    paraphrase: "Owning yourself is worth any price, but it comes from consistent truthful action.",
                    lexical: "Real ownership of self is not declared; it is built through many honest acts."
                ),
                rare: ["privilege", "ownership", "declarations", "repeated"]
            ),
            (
                raw: "Become who you are by chiseling away borrowed convictions, until your voice sounds less like applause and more like necessity.",
                translation: "通过凿去借来的信念去成为你自己，直到你的声音不再像掌声，而更像必然。",
                shadow: (
                    kernel: "Identity is forged by removing borrowed beliefs.",
                    paraphrase: "You become yourself by cutting away inherited convictions until your voice is necessary.",
                    lexical: "To be who you are, strip off borrowed ideas until your own voice sounds inevitable."
                ),
                rare: ["convictions", "necessity", "chiseling"]
            ),
            (
                raw: "The higher type is not comfortable; it is coherent.",
                translation: "更高类型的人并不舒适；他是自洽的。",
                shadow: (
                    kernel: "Higher character means coherence, not comfort.",
                    paraphrase: "Greatness is defined less by ease and more by inner consistency.",
                    lexical: "The higher type is not about comfort; it is about being coherent."
                ),
                rare: ["coherent"]
            )
        ]

        return sentenceSpecs.map { spec in
            makeSentence(
                rawText: spec.raw,
                translation: spec.translation,
                shadow: spec.shadow,
                rareWords: spec.rare
            )
        }
    }

    private static func makeSentence(
        rawText: String,
        translation: String,
        shadow: (kernel: String, paraphrase: String, lexical: String),
        rareWords: Set<String>
    ) -> Sentence {
        let words = buildWords(
            from: rawText,
            rareWords: rareWords
        )

        let chunkIndices = chunkBreakIndices(from: words.map(\.text))
        let coreMask = words.map { isCoreWord($0.text) }

        let shadowVariations: [Sentence.ShadowVariation] = [
            Sentence.ShadowVariation(tone: .kernel, text: shadow.kernel),
            Sentence.ShadowVariation(tone: .paraphrase, text: shadow.paraphrase),
            Sentence.ShadowVariation(tone: .lexical, text: shadow.lexical)
        ]

        return Sentence(
            rawText: rawText,
            wordData: words,
            translation: translation,
            chunkIndices: chunkIndices,
            shadowVariations: shadowVariations,
            isCoreWord: coreMask,
            ladderSegments: makeLadderSegments(from: rawText)
        )
    }

    private static func buildWords(
        from rawText: String,
        rareWords: Set<String>
    ) -> [Word] {
        let tokens = rawText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let ids = tokens.map { _ in UUID() }

        return tokens.enumerated().map { index, token in
            let normalized = normalize(token)
            let isContent = isContentWord(normalized)

            var partners: [UUID] = []
            if isContent, index > 0 {
                let leftNormalized = normalize(tokens[index - 1])
                if isContentWord(leftNormalized) {
                    partners.append(ids[index - 1])
                }
            }
            if isContent, index < tokens.count - 1 {
                let rightNormalized = normalize(tokens[index + 1])
                if isContentWord(rightNormalized) {
                    partners.append(ids[index + 1])
                }
            }

            return Word(
                id: ids[index],
                text: token,
                translation: manualLexicon[normalized],
                frequencyBand: frequencyBand(for: normalized, rareWords: rareWords),
                collocationPartners: partners
            )
        }
    }

    private static func chunkBreakIndices(from tokens: [String]) -> [Int] {
        guard tokens.count > 1 else { return [] }

        var breakpoints: [Int] = []
        for index in tokens.indices {
            guard index < tokens.count - 1 else { continue }
            let token = tokens[index]
            if token.hasSuffix(",") || token.hasSuffix(";") || token.hasSuffix(":") {
                breakpoints.append(index)
            }
        }

        if breakpoints.isEmpty {
            let fallback = min(tokens.count - 2, max(1, tokens.count / 3))
            breakpoints = [fallback]
        }

        return Array(Set(breakpoints)).sorted()
    }

    private static func makeLadderSegments(from rawText: String) -> [Sentence.LadderSegment] {
        let clauses = rawText
            .split(whereSeparator: { ",;:".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if clauses.count <= 3 {
            return clauses.enumerated().map { index, clause in
                Sentence.LadderSegment(text: clause, indentLevel: min(index, 2))
            }
        }

        return [
            Sentence.LadderSegment(text: clauses[0], indentLevel: 0),
            Sentence.LadderSegment(text: clauses[1], indentLevel: 1),
            Sentence.LadderSegment(text: clauses.dropFirst(2).joined(separator: ", "), indentLevel: 2)
        ]
    }

    private static func frequencyBand(for normalized: String, rareWords: Set<String>) -> FrequencyBand {
        guard !normalized.isEmpty else { return .B }
        if rareWords.contains(normalized) {
            return .E
        }
        if stopWords.contains(normalized) {
            return .A
        }
        if normalized.count >= 10 {
            return .D
        }
        if normalized.count >= 7 {
            return .C
        }
        return .B
    }

    private static func isCoreWord(_ token: String) -> Bool {
        let normalized = normalize(token)
        guard !normalized.isEmpty else { return false }
        if stopWords.contains(normalized) {
            return false
        }
        return normalized.count >= 5
    }

    private static func isContentWord(_ normalized: String) -> Bool {
        !normalized.isEmpty && !stopWords.contains(normalized) && normalized.count >= 4
    }

    private static func normalize(_ token: String) -> String {
        token
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private static let manualLexicon: [String: String] = [
        "a": "一个",
        "abyss": "深渊",
        "acts": "行为",
        "also": "也",
        "and": "和",
        "applause": "掌声",
        "are": "是",
        "asks": "追问",
        "away": "去除",
        "become": "成为",
        "before": "在...之前",
        "borrowed": "借来的",
        "by": "通过",
        "carry": "带着",
        "chiseling": "凿刻",
        "coherent": "自洽",
        "comfortable": "舒适",
        "condemns": "谴责",
        "convictions": "信念",
        "darkness": "黑暗",
        "declarations": "宣言",
        "disciplined": "有纪律的",
        "does": "助动词",
        "earned": "赢得",
        "every": "每一个",
        "examine": "审视",
        "fear": "恐惧",
        "fights": "搏斗",
        "for": "为了",
        "habits": "习惯",
        "he": "他",
        "high": "高",
        "higher": "更高",
        "honesty": "诚实",
        "into": "进入",
        "is": "是",
        "it": "它",
        "its": "它的",
        "judgment": "判断",
        "learns": "学会",
        "less": "更少地",
        "like": "像",
        "mirror": "镜子",
        "monster": "怪物",
        "monsters": "怪物们",
        "more": "更加",
        "motives": "动机",
        "necessity": "必然",
        "no": "没有",
        "not": "不",
        "of": "的",
        "only": "仅仅",
        "ownership": "拥有权",
        "owning": "拥有",
        "price": "代价",
        "privilege": "特权",
        "repeated": "反复的",
        "see": "看清",
        "should": "应当",
        "sounds": "听起来",
        "spirit": "精神",
        "that": "那",
        "the": "这",
        "through": "通过",
        "to": "去",
        "too": "过于",
        "type": "类型",
        "until": "直到",
        "us": "我们",
        "voice": "声音",
        "we": "我们",
        "what": "什么",
        "who": "谁",
        "whoever": "任何...的人",
        "with": "与",
        "world": "世界",
        "yet": "然而",
        "you": "你",
        "your": "你的",
        "yourself": "你自己"
    ]

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "before", "but", "by", "does", "every", "for", "from", "he", "in", "into", "is", "it", "its", "not", "no", "of", "only", "or", "that", "the", "through", "to", "too", "until", "us", "what", "who", "with", "yet", "you", "your"
    ]
}

enum MockData {
    static let paragraph = [
        "Whoever fights with monsters should see to it that he does not become a monster. The abyss is not only a darkness before us; it is also a mirror that asks what habits of fear we carry into every judgment. A disciplined spirit learns to examine its motives before it condemns the world.",
        "No price is too high for the privilege of owning yourself, yet ownership is earned through repeated acts of honesty, not declarations. Become who you are by chiseling away borrowed convictions, until your voice sounds less like applause and more like necessity. The higher type is not comfortable; it is coherent."
    ].joined(separator: "\n\n")

    static let sentences: [Sentence] = MockDataGenerator.makeSentences()
}
