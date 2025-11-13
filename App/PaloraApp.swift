import SwiftUI
import AppKit

@main
struct PaloraApp: App {
  @NSApplicationDelegateAdaptor(PaloraAppDelegate.self) var appDelegate

  var body: some Scene {
    // No main window for a menu bar app; status item is managed by AppDelegate.
    Settings {
      EmptyView()
    }
  }
}

final class PaloraAppDelegate: NSObject, NSApplicationDelegate {
  private var statusBarController: StatusBarController?
  private var recordingController: RecordingController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let notesProvider = DefaultNotesDirectoryProvider()
    let apiKeyProvider = DefaultAPIKeyProvider()
    let config = AppConfig(
      notesDirectory: notesProvider,
      apiKeyProvider: apiKeyProvider,
      openAIBaseURL: URL(string: "https://api.openai.com/v1")!
    )

    let audioService = AudioCaptureService()
    let transcriptionService = TranscriptionService(config: config)
    let summaryService = SummaryService(config: config)
    let markdownExporter = MarkdownExporter(config: config)
    let meetingDetector = MeetingDetector()

    let controller = RecordingController(
      config: config,
      audioService: audioService,
      transcriptionService: transcriptionService,
      summaryService: summaryService,
      markdownExporter: markdownExporter,
      meetingDetector: meetingDetector
    )
    self.recordingController = controller

    let status = StatusBarController(
      onStart: { [weak controller] in controller?.startRequested() },
      onStop: { [weak controller] in controller?.stopRequested() },
      onOpenNotes: { [weak notesProvider] in
        if let url = notesProvider?.url() {
          NSWorkspace.shared.open(url)
        }
      },
      onTestCapture: {
        Task {
          let recorder = SimpleAudioRecorder()
          do {
            NSLog("[Test] 🧪 Starting SimpleAudioRecorder test (10 seconds)...")
            let startURL = try await recorder.startRecording()
            NSLog("[Test] ✅ Recording started: \(startURL.lastPathComponent)")
            
            // Record for 10 seconds
            try await Task.sleep(nanoseconds: 10_000_000_000)
            NSLog("[Test] ⏱️ 10 seconds elapsed, stopping...")
            
            let url = try await recorder.stopRecording()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            NSLog("[Test] ✅ SUCCESS! Audio saved to: \(url.path) (\(size) bytes)")
            
            // Show in Finder
            NSWorkspace.shared.activateFileViewerSelecting([url])
            
            // Show success alert
            DispatchQueue.main.async {
              let alert = NSAlert()
              alert.messageText = "Test Recording Complete"
              alert.informativeText = "Audio saved successfully!\n\nFile: \(url.lastPathComponent)\nSize: \(size) bytes"
              alert.alertStyle = .informational
              alert.addButton(withTitle: "OK")
              alert.runModal()
            }
          } catch {
            NSLog("[Test] ❌ ERROR: \(error)")
            DispatchQueue.main.async {
              let alert = NSAlert()
              alert.messageText = "Test Recording Failed"
              alert.informativeText = "Error: \(error.localizedDescription)"
              alert.alertStyle = .warning
              alert.addButton(withTitle: "OK")
              alert.runModal()
            }
          }
        }
      },
      onQuit: {
        NSApp.terminate(nil)
      }
    )
    self.statusBarController = status

    controller.onStateChange = { [weak status] state in
      switch state {
      case .idle:
        status?.setRecording(false)
      case .recording:
        status?.setRecording(true)
      case .finalizing:
        status?.setRecording(true)
      case .error(_):
        status?.setRecording(false)
      }
    }

    meetingDetector.onStart = { [weak controller] in controller?.handleMeetingDetected() }
    meetingDetector.onEnd = { [weak controller] in controller?.handleMeetingEnded() }
    meetingDetector.start()
  }
}


