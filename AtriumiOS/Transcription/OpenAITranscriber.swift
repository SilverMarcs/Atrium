import Foundation

actor OpenAITranscriber: AudioTranscribing {
    let apiKey: String
    let model: String

    init(apiKey: String, model: String = "gpt-transcribe") {
        self.apiKey = apiKey
        self.model = model
    }

    func transcribe(audio: URL) async throws -> String {
        let bytes = try Data(contentsOf: audio)
        guard bytes.count < 25_000_000 else {
            throw NSError(domain: "Transcription", code: 1, userInfo: [NSLocalizedDescriptionKey: "This recording is too large. Try a shorter recording."])
        }
        let boundary = UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            // Keep diagnostics useful without exposing keys or recorded content.
            let requestID = response.value(forHTTPHeaderField: "x-request-id") ?? "unavailable"
            throw NSError(domain: "OpenAITranscription", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenAI transcription failed (HTTP \(response.statusCode), request \(requestID)). Check your API key, billing, and connection."])
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = object?["text"] as? String else { throw URLError(.cannotParseResponse) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
