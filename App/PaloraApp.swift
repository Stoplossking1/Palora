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
      onTestCapture: { [weak audioService] in
        Task {
          do {
            NSLog("[Test] Starting quick audio capture test...")
            let startURL = try await audioService?.startRecordingSystemAudio()
            if let startURL = startURL {
              NSLog("[Test] Recording to \(startURL.lastPathComponent)")
            }
            try await Task.sleep(nanoseconds: 3_000_000_000) // ~3 seconds
              print("After 3 sec")
              
              
            if let url = try await audioService?.stopRecordingSystemAudio() {
                print("it passes here")
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
              NSLog("[Test] Audio saved to: \(url.path) (\(size) bytes)")
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
          } catch {
            NSLog("[Test] ERROR: \(error)")
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


