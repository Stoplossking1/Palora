import Foundation

struct OpenAITranscriptionResponse: Decodable {
  let text: String
}

final class TranscriptionService {
  enum ErrorType: Swift.Error {
    case missingAPIKey
    case httpError(String)
    case decodeError
  }

  private let config: AppConfig
  init(config: AppConfig) {
    self.config = config
  }

  func transcribe(audioURL: URL) async throws -> String {
  let apiKey = config.apiKeyProvider.apiKey()
  guard !apiKey.isEmpty else {
    NSLog("[Transcription] ERROR: Missing API key")
    throw ErrorType.missingAPIKey
  }
  
  NSLog("[Transcription] Starting transcription for: \(audioURL.path)")

  var request = URLRequest(url: config.openAIBaseURL.appendingPathComponent("audio/transcriptions"))
  request.httpMethod = "POST"
  request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

  let boundary = "Boundary-\(UUID().uuidString)"
  request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

  let body = try makeMultipartBody(boundary: boundary, audioURL: audioURL)
  request.httpBody = body
  NSLog("[Transcription] Uploading \(body.count) bytes")

  let (data, resp) = try await URLSession.shared.data(for: request)
  guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
    let msg = String(data: data, encoding: .utf8) ?? "unknown_error"
    NSLog("[Transcription] HTTP ERROR: \(msg)")
    throw ErrorType.httpError(msg)
  }

  if let decoded = try? JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data) {
    NSLog("[Transcription] Success: \(decoded.text.prefix(50))...")
    return decoded.text
  } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
    NSLog("[Transcription] Raw text response: \(text.prefix(50))...")
    return text
  } else {
    NSLog("[Transcription] Decode failed")
    throw ErrorType.decodeError
  }
}

  private func makeMultipartBody(boundary: String, audioURL: URL) throws -> Data {
    var data = Data()
    func append(_ string: String) { data.append(string.data(using: .utf8)!) }

    // model
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
    append("whisper-1\r\n")

    // file
    let fileData = try Data(contentsOf: audioURL)
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
    append("Content-Type: audio/m4a\r\n\r\n")
    data.append(fileData)
    append("\r\n")

    append("--\(boundary)--\r\n")
    return data
  }
}


