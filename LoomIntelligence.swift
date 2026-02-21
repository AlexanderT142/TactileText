import Foundation

actor LoomIntelligence {
    static let modelID = "gemini-3-flash-preview"

    enum LoomIntelligenceError: LocalizedError {
        case missingAPIKey
        case badHTTPStatus(Int, String)
        case emptyModelResponse
        case invalidJSONPayload(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Missing Gemini API key. Set GEMINI_API_KEY in your environment."
            case .badHTTPStatus(let code, let body):
                return "Gemini request failed (\(code)): \(body)"
            case .emptyModelResponse:
                return "Gemini returned an empty response."
            case .invalidJSONPayload(let payload):
                return "Failed to parse Gemini JSON payload: \(payload.prefix(240))"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func analyze(rawText: String) async throws -> [Sentence] {
        let apiKey = LoomSecrets.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw LoomIntelligenceError.missingAPIKey
        }

        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.modelID):generateContent")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else {
            throw LoomIntelligenceError.invalidJSONPayload("Invalid Gemini URL")
        }

        let userPrompt = """
        Analyze this text and return JSON only:

        \(rawText)
        """

        let requestBody = GeminiGenerateRequest(
            systemInstruction: .init(parts: [.init(text: Self.systemPrompt)]),
            contents: [.init(role: "user", parts: [.init(text: userPrompt)])],
            generationConfig: .init(
                temperature: 0.2,
                responseMimeType: "application/json"
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LoomIntelligenceError.invalidJSONPayload("Non-HTTP response")
        }

        if !(200 ... 299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            throw LoomIntelligenceError.badHTTPStatus(httpResponse.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
        let responseText = decoded.candidates?
            .first?
            .content?
            .parts?
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let responseText, !responseText.isEmpty else {
            throw LoomIntelligenceError.emptyModelResponse
        }

        let payload = try decodePayload(from: responseText)

        let sentences = payload.sentences.compactMap { mapSentence($0) }
        if sentences.isEmpty {
            throw LoomIntelligenceError.invalidJSONPayload(responseText)
        }
        return sentences
    }

    private func mapSentence(_ payload: LoomAISentence) -> Sentence? {
        let raw = payload.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let rawTokens = tokenizeWords(raw)
        var words = mapWords(rawTokens: rawTokens, aiWords: payload.words)
        enrichCollocations(words: &words)

        let chunks = payload.chunks
            .filter { $0 >= 0 && $0 < words.count }
            .sorted()
        let uniqueChunks = Array(NSOrderedSet(array: chunks)) as? [Int] ?? chunks

        let shadowVariations = buildShadowVariations(from: payload.shadowVariations, rawText: raw)

        return Sentence(
            rawText: raw,
            wordData: words,
            translation: payload.translation.isEmpty ? raw : payload.translation,
            chunkIndices: uniqueChunks,
            shadowVariations: shadowVariations,
            isCoreWord: buildCoreWordMask(from: words.map(\.text)),
            ladderSegments: buildLadderSegments(from: raw, words: words.map(\.text))
        )
    }

    private func mapWords(rawTokens: [String], aiWords: [LoomAIWord]) -> [Word] {
        guard !rawTokens.isEmpty else {
            return aiWords.map {
                Word(
                    text: $0.text,
                    definition: $0.definition.nilIfBlank,
                    synonym: $0.synonym.nilIfBlank,
                    translation: $0.translation.nilIfBlank,
                    frequencyBand: frequencyBand(from: $0.frequency, fallbackToken: $0.text)
                )
            }
        }

        return rawTokens.enumerated().map { index, token in
            let aiWord = index < aiWords.count ? aiWords[index] : nil
            return Word(
                text: token,
                definition: aiWord?.definition.nilIfBlank,
                synonym: aiWord?.synonym.nilIfBlank,
                translation: aiWord?.translation.nilIfBlank,
                frequencyBand: frequencyBand(from: aiWord?.frequency, fallbackToken: token)
            )
        }
    }

    private func buildShadowVariations(
        from aiShadow: LoomAIShadowVariations,
        rawText: String
    ) -> [Sentence.ShadowVariation] {
        let kernel = aiShadow.kernel.nilIfBlank ?? rawText
        let paraphrase = aiShadow.paraphrase.nilIfBlank ?? rawText
        let lexicalFallback = rawText
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(12)
            .joined(separator: " ")
        let lexical = aiShadow.lexical.nilIfBlank ?? lexicalFallback

        return [
            Sentence.ShadowVariation(tone: .kernel, text: kernel),
            Sentence.ShadowVariation(tone: .paraphrase, text: paraphrase),
            Sentence.ShadowVariation(tone: .lexical, text: lexical)
        ]
    }

    private func enrichCollocations(words: inout [Word]) {
        guard !words.isEmpty else { return }

        for index in words.indices {
            let normalized = normalize(words[index].text)
            guard isContentWord(normalized) else { continue }

            var partners: [UUID] = []

            if index > 0 {
                let left = normalize(words[index - 1].text)
                if isContentWord(left) {
                    partners.append(words[index - 1].id)
                }
            }

            if index < words.count - 1 {
                let right = normalize(words[index + 1].text)
                if isContentWord(right) {
                    partners.append(words[index + 1].id)
                }
            }

            words[index].collocationPartners = partners
        }
    }

    private func frequencyBand(from raw: String?, fallbackToken: String) -> FrequencyBand {
        if let raw {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let band = FrequencyBand(rawValue: normalized) {
                return band
            }
        }

        let token = normalize(fallbackToken)
        if stopWords.contains(token) {
            return .A
        }
        if token.count >= 10 {
            return .D
        }
        if token.count >= 7 {
            return .C
        }
        return .B
    }

    private func decodePayload(from responseText: String) throws -> LoomAIPayload {
        let candidates = candidateJSONStrings(from: responseText)

        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let payload = try? JSONDecoder().decode(LoomAIPayload.self, from: data),
               !payload.sentences.isEmpty {
                return payload
            }
        }

        throw LoomIntelligenceError.invalidJSONPayload(responseText)
    }

    private func candidateJSONStrings(from responseText: String) -> [String] {
        var candidates: [String] = [responseText.trimmingCharacters(in: .whitespacesAndNewlines)]

        if let fenced = extractFencedJSON(from: responseText) {
            candidates.append(fenced)
        }

        if let firstBrace = responseText.firstIndex(of: "{"),
           let lastBrace = responseText.lastIndex(of: "}") {
            let slice = String(responseText[firstBrace ... lastBrace])
            candidates.append(slice)
        }

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private func extractFencedJSON(from responseText: String) -> String? {
        guard let startRange = responseText.range(of: "```") else { return nil }
        let afterStart = responseText[startRange.upperBound...]

        guard let endRange = afterStart.range(of: "```") else { return nil }
        var fencedBody = String(afterStart[..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if fencedBody.hasPrefix("json") {
            fencedBody.removeFirst(4)
            fencedBody = fencedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return fencedBody
    }

    private func tokenizeWords(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private func buildCoreWordMask(from words: [String]) -> [Bool] {
        guard !words.isEmpty else { return [] }

        var mask = words.map { token -> Bool in
            let cleaned = normalize(token)
            guard !cleaned.isEmpty else { return false }
            if stopWords.contains(cleaned) {
                return false
            }
            return cleaned.count >= 5
        }

        if !mask.contains(true), let longest = words.indices.max(by: { words[$0].count < words[$1].count }) {
            mask[longest] = true
        }

        return mask
    }

    private func buildLadderSegments(from text: String, words: [String]) -> [Sentence.LadderSegment] {
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
            return [
                Sentence.LadderSegment(text: clauses[0], indentLevel: 0),
                Sentence.LadderSegment(text: clauses[1], indentLevel: 1)
            ]
        }

        if words.count <= 6 {
            return [Sentence.LadderSegment(text: text, indentLevel: 0)]
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

    private func normalize(_ token: String) -> String {
        token
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private func isContentWord(_ normalized: String) -> Bool {
        !normalized.isEmpty && !stopWords.contains(normalized) && normalized.count >= 4
    }

    private static let systemPrompt = """
    You are Loom Intelligence for IELTS-focused language acquisition.
    Return strict JSON only (no markdown, no prose).

    Analyze the user's text sentence-by-sentence in original order.

    Required top-level schema:
    {
      "sentences": [
        {
          "rawText": "exact original sentence text",
          "translation": "natural sentence translation in Chinese",
          "chunks": [0-based word indices where a pause boundary should occur],
          "words": [
            {
              "text": "word token exactly as it appears",
              "synonym": "one academic high-level synonym",
              "translation": "contextual Chinese (L1) translation",
              "frequency": "A|B|C|D|E"
            }
          ],
          "shadowVariations": {
            "kernel": "2-3 simple active S-V-O sentences (Band 6 comprehension)",
            "paraphrase": "same meaning with different grammar (Band 8 flexibility)",
            "lexical": "same structure with C1/C2 academic vocabulary upgrades (Band 9 vocabulary)"
          }
        }
      ]
    }

    Constraints:
    - sentence count must match the input sentence count.
    - words array length must match the sentence token count.
    - frequency must always be one of A,B,C,D,E.
    - translation should be concise and contextual Chinese.
    - synonym should be one high-level academic English synonym.
    - return all three shadowVariations keys for every sentence.
    - output valid JSON.
    """

    private let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "he", "her",
        "him", "his", "i", "in", "into", "is", "it", "its", "of", "on", "or", "our", "she",
        "that", "the", "their", "them", "there", "they", "this", "to", "us", "we", "who", "with", "you", "your"
    ]
}

private struct GeminiGenerateRequest: Encodable {
    struct Part: Encodable {
        let text: String
    }

    struct Content: Encodable {
        let role: String
        let parts: [Part]
    }

    struct SystemInstruction: Encodable {
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let responseMimeType: String
    }

    let systemInstruction: SystemInstruction
    let contents: [Content]
    let generationConfig: GenerationConfig

    enum CodingKeys: String, CodingKey {
        case systemInstruction = "system_instruction"
        case contents
        case generationConfig
    }
}

private struct GeminiGenerateResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }

            let parts: [Part]?
        }

        let content: Content?
    }

    let candidates: [Candidate]?
}

private struct LoomAIPayload: Decodable {
    let sentences: [LoomAISentence]
}

private struct LoomAISentence: Decodable {
    let rawText: String
    let translation: String
    let chunks: [Int]
    let words: [LoomAIWord]
    let shadowVariations: LoomAIShadowVariations

    enum CodingKeys: String, CodingKey {
        case rawText
        case rawTextSnake = "raw_text"
        case sentence
        case translation
        case chunks
        case words
        case shadowVariations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let camelRawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        let snakeRawText = try container.decodeIfPresent(String.self, forKey: .rawTextSnake)
        let fallbackSentence = try container.decodeIfPresent(String.self, forKey: .sentence)
        rawText = camelRawText ?? snakeRawText ?? fallbackSentence ?? ""

        translation = (try container.decodeIfPresent(String.self, forKey: .translation)) ?? ""
        chunks = (try container.decodeIfPresent([Int].self, forKey: .chunks)) ?? []
        words = (try container.decodeIfPresent([LoomAIWord].self, forKey: .words)) ?? []
        shadowVariations = (try container.decodeIfPresent(LoomAIShadowVariations.self, forKey: .shadowVariations)) ?? .empty
    }
}

private struct LoomAIWord: Decodable {
    let text: String
    let definition: String?
    let synonym: String?
    let translation: String?
    let frequency: String?

    enum CodingKeys: String, CodingKey {
        case text
        case definition
        case synonym
        case translation
        case frequency
    }
}

private struct LoomAIShadowVariations: Decodable {
    let kernel: String?
    let paraphrase: String?
    let lexical: String?

    static let empty = LoomAIShadowVariations(kernel: nil, paraphrase: nil, lexical: nil)

    enum CodingKeys: String, CodingKey {
        case kernel
        case paraphrase
        case lexical
        case simplify
        case lyric
        case direct
    }

    init(kernel: String?, paraphrase: String?, lexical: String?) {
        self.kernel = kernel
        self.paraphrase = paraphrase
        self.lexical = lexical
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let kernel = try container.decodeIfPresent(String.self, forKey: .kernel)
            ?? container.decodeIfPresent(String.self, forKey: .simplify)
        let paraphrase = try container.decodeIfPresent(String.self, forKey: .paraphrase)
            ?? container.decodeIfPresent(String.self, forKey: .lyric)
        let lexical = try container.decodeIfPresent(String.self, forKey: .lexical)
            ?? container.decodeIfPresent(String.self, forKey: .direct)

        self.init(kernel: kernel, paraphrase: paraphrase, lexical: lexical)
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
