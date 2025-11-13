import Foundation

final class MarkdownExporter {
  enum ErrorType: Swift.Error {
    case writeFailed
  }

  private let config: AppConfig
  init(config: AppConfig) {
    self.config = config
  }

  func save(notes: MeetingNotes, transcript: String) throws -> URL {
    let dir = config.notesDirectory.url()
    let filename = "\(Self.timestampString())_meeting.md"
    let url = dir.appendingPathComponent(filename)

    var lines: [String] = []
    lines.append("# Meeting – \(Self.readableDate())")
    lines.append("")
    lines.append("## Summary")
    lines.append(notes.summary)
    lines.append("")
    lines.append("## Key Points")
    for kp in notes.keyPoints {
      lines.append("- \(kp)")
    }
    lines.append("")
    lines.append("## Action Items")
    for ai in notes.actionItems {
      lines.append("- \(ai)")
    }
    lines.append("")
    lines.append("## Transcript")
    lines.append(transcript)
    lines.append("")

    let content = lines.joined(separator: "\n")
    do {
      try content.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      throw ErrorType.writeFailed
    }
  }

  private static func timestampString() -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd_HH-mm"
    return df.string(from: Date())
  }

  private static func readableDate() -> String {
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .short
    return df.string(from: Date())
  }
}


