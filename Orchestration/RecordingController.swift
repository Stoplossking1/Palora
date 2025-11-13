import Foundation
import AppKit

enum AppState {
  case idle
  case recording
  case finalizing
  case error(Error)
}

final class RecordingController {
  var onStateChange: ((AppState) -> Void)?

  private(set) var state: AppState = .idle {
    didSet { onStateChange?(state) }
  }

  private let config: AppConfig
  private let audioService: AudioCaptureService
  private let transcriptionService: TranscriptionService
  private let summaryService: SummaryService
  private let markdownExporter: MarkdownExporter
  private let meetingDetector: MeetingDetector

  init(
    config: AppConfig,
    audioService: AudioCaptureService,
    transcriptionService: TranscriptionService,
    summaryService: SummaryService,
    markdownExporter: MarkdownExporter,
    meetingDetector: MeetingDetector
  ) {
    self.config = config
    self.audioService = audioService
    self.transcriptionService = transcriptionService
    self.summaryService = summaryService
    self.markdownExporter = markdownExporter
    self.meetingDetector = meetingDetector
  }

  func handleMeetingDetected() {
    startRequested()
  }

  func handleMeetingEnded() {
    stopRequested()
  }

  func startRequested() {
    guard case .idle = state else { return }
      Permissions.ensureScreenRecordingPermission { [weak self] granted in
          guard let self = self else { return }
          if !granted {
              self.state = .error(NSError(domain: "Palora", code: -2, userInfo: [NSLocalizedDescriptionKey: "Screen Recording not granted"]))
              Permissions.promptToOpenSettings()
              return
          }
          Task {
          do {
              
             let url = try await self.audioService.startRecordingSystemAudio()
              
              self.state = .recording
          } catch {
              self.state = .error(error)
              self.presentAlert("Recording failed to start. Please grant Screen Recording permission in System Settings and try again.\n\n\(error.localizedDescription)")
          }
      }
    }
  }

  func stopRequested() {
  guard case .recording = state else { return }
  state = .finalizing
  NSLog("[Controller] Stopping recording and starting finalization")

  Task.detached { [weak self, markdownExporter] in
    guard let self = self else { return }

    do {
      let audioURL = try await self.audioService.stopRecordingSystemAudio()
      NSLog("[Controller] Audio saved: \(audioURL.path)")
      
      let transcript = try await self.transcriptionService.transcribe(audioURL: audioURL)
      NSLog("[Controller] Transcription complete")
      
      let notes = try await self.summaryService.summarize(transcript: transcript)
      NSLog("[Controller] Summary complete")
      
      let savedURL = try markdownExporter.save(notes: notes, transcript: transcript)
      NSLog("[Controller] Markdown saved: \(savedURL.path)")
      
      await MainActor.run { self.state = .idle }
    } catch {
      NSLog("[Controller] ERROR: \(error)")
      await MainActor.run {
        self.state = .error(error)
        self.presentAlert("Finalization failed. \(error.localizedDescription)")
      }
    }
  }
}

  private func presentAlert(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "Palora"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}


