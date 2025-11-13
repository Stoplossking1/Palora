import Foundation

struct MeetingNotes: Codable {
  let summary: String
  let keyPoints: [String]
  let actionItems: [String]
}

final class SummaryService {
  enum ErrorType: Swift.Error {
    case missingAPIKey
    case httpError(String)
    case decodeError
  }

  private let config: AppConfig
  init(config: AppConfig) {
    self.config = config
  }

  func summarize(transcript: String) async throws -> MeetingNotes {
  let apiKey = config.apiKeyProvider.apiKey()
  guard !apiKey.isEmpty else {
    NSLog("[Summary] ERROR: Missing API key")
    throw ErrorType.missingAPIKey
  }

  NSLog("[Summary] Starting summary for transcript length: \(transcript.count)")

  var request = URLRequest(url: config.openAIBaseURL.appendingPathComponent("chat/completions"))
  request.httpMethod = "POST"
  request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")

  let system = """
  You are an assistant that produces structured meeting notes as strict JSON.
  Output ONLY JSON with fields: summary (string), keyPoints (string[]), actionItems (string[]).
  """
  let user = """
  Transcript:
  \(transcript)
  """
  let payload: [String: Any] = [
    "model": "gpt-4o-mini",
    "messages": [
      ["role": "system", "content": system],
      ["role": "user", "content": user]
    ],
    "temperature": 0.2,
    "response_format": ["type": "json_object"]
  ]
  request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

  let (data, resp) = try await URLSession.shared.data(for: request)
  guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
    let msg = String(data: data, encoding: .utf8) ?? "unknown_error"
    NSLog("[Summary] HTTP ERROR: \(msg)")
    throw ErrorType.httpError(msg)
  }

  guard
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let choices = root["choices"] as? [[String: Any]],
    let first = choices.first,
    let message = first["message"] as? [String: Any],
    let content = message["content"] as? String,
    let contentData = content.data(using: .utf8),
    let notes = try? JSONDecoder().decode(MeetingNotes.self, from: contentData)
  else {
    NSLog("[Summary] Decode failed")
    throw ErrorType.decodeError
  }

  NSLog("[Summary] Success: \(notes.summary.prefix(50))...")
  return notes
}
}


