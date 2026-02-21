import Foundation

enum MockDataGenerator {
    static func makeSentences() -> [Sentence] {
        let sentenceSpecs: [(raw: String, translation: String, terms: [String: String], rare: Set<String>)] = [
            (
                raw: "Whoever fights with monsters should see to it that he does not become a monster.",
                translation: "与怪物搏斗的人，必须警惕自己不要变成怪物。",
                terms: [
                    "monsters": "怪物",
                    "monster": "怪物",
                    "fights": "搏斗"
                ],
                rare: ["monsters", "monster", "whoever"]
            ),
            (
                raw: "The abyss is not only a darkness before us; it is also a mirror that asks what habits of fear we carry into every judgment.",
                translation: "深渊不仅是眼前的黑暗；它也是一面镜子，追问我们把怎样的恐惧习惯带入每一次判断。",
                terms: [
                    "abyss": "深渊",
                    "mirror": "镜子",
                    "judgment": "判断",
                    "fear": "恐惧"
                ],
                rare: ["abyss", "judgment", "habits"]
            ),
            (
                raw: "A disciplined spirit learns to examine its motives before it condemns the world.",
                translation: "有纪律的精神会在谴责世界之前先审视自己的动机。",
                terms: [
                    "disciplined": "有纪律的",
                    "spirit": "精神",
                    "motives": "动机",
                    "world": "世界"
                ],
                rare: ["disciplined", "motives", "condemns"]
            ),
            (
                raw: "No price is too high for the privilege of owning yourself, yet ownership is earned through repeated acts of honesty, not declarations.",
                translation: "为拥有你自己这一特权，任何代价都不算太高；但这种拥有要靠反复的诚实行动去赢得，而不是宣言。",
                terms: [
                    "privilege": "特权",
                    "ownership": "拥有",
                    "honesty": "诚实",
                    "declarations": "宣言"
                ],
                rare: ["privilege", "ownership", "declarations", "repeated"]
            ),
            (
                raw: "Become who you are by chiseling away borrowed convictions, until your voice sounds less like applause and more like necessity.",
                translation: "通过凿去借来的信念去成为你自己，直到你的声音不再像掌声，而更像必然。",
                terms: [
                    "convictions": "信念",
                    "applause": "掌声",
                    "necessity": "必然",
                    "borrowed": "借来的"
                ],
                rare: ["convictions", "necessity", "chiseling"]
            ),
            (
                raw: "The higher type is not comfortable; it is coherent.",
                translation: "更高类型的人并不舒适；他是自洽的。",
                terms: [
                    "higher": "更高的",
                    "coherent": "自洽的",
                    "type": "类型"
                ],
                rare: ["coherent"]
            )
        ]

        return sentenceSpecs.map { spec in
            makeSentence(
                rawText: spec.raw,
                translation: spec.translation,
                termTranslations: spec.terms,
                rareWords: spec.rare
            )
        }
    }

    private static func makeSentence(
        rawText: String,
        translation: String,
        termTranslations: [String: String],
        rareWords: Set<String>
    ) -> Sentence {
        let words = buildWords(
            from: rawText,
            termTranslations: termTranslations,
            rareWords: rareWords
        )

        let chunkIndices = stride(from: 6, to: max(7, words.count - 1), by: 7).map { $0 }
        let coreMask = words.map { isCoreWord($0.text) }

        return Sentence(
            rawText: rawText,
            wordData: words,
            translation: translation,
            chunkIndices: chunkIndices,
            isCoreWord: coreMask,
            ladderSegments: makeLadderSegments(from: rawText)
        )
    }

    private static func buildWords(
        from rawText: String,
        termTranslations: [String: String],
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
                translation: termTranslations[normalized],
                frequencyBand: frequencyBand(for: normalized, rareWords: rareWords),
                collocationPartners: partners
            )
        }
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
