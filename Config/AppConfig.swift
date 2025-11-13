import Foundation

struct AppConfig {
  let notesDirectory: NotesDirectoryProviding
  let apiKeyProvider: APIKeyProviding
  let openAIBaseURL: URL
}

protocol NotesDirectoryProviding {
  func url() -> URL
}

protocol APIKeyProviding {
  func apiKey() -> String
}

final class DefaultNotesDirectoryProvider: NotesDirectoryProviding {
  func url() -> URL {
    let fm = FileManager.default
    let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
    let folder = base.appendingPathComponent("Meeting Notes", isDirectory: true)
    if !fm.fileExists(atPath: folder.path) {
      try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    return folder
  }
}

final class DefaultAPIKeyProvider: APIKeyProviding {
  func apiKey() -> String {
    if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
      return env
    }
    if let saved = UserDefaults.standard.string(forKey: "OPENAI_API_KEY"), !saved.isEmpty {
      return saved
    }
    return ""
  }
}


