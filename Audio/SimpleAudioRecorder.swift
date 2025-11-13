import Foundation
import AVFoundation
import ScreenCaptureKit

/// Minimal standalone audio recorder module focused on getting audio recording to work.
/// This module is completely separate from AudioCaptureService and can be tested independently.
final class SimpleAudioRecorder: NSObject {
  enum RecordingError: Error {
    case noCapturableContent
    case writerSetupFailed
    case streamStartFailed(Error)
    case noAudioSamplesReceived
    case writerFailed(Error?)
  }
  
  // MARK: - Properties
  
  private let writerQueue = DispatchQueue(label: "simple.audio.writer")
  private let captureQueue = DispatchQueue(label: "simple.audio.capture")
  
  private var stream: SCStream?
  private var writer: AVAssetWriter?
  private var audioInput: AVAssetWriterInput?
  private var firstPTS: CMTime?
  private var outputURL: URL?
  private var sampleCount: Int = 0
  
  // MARK: - Public API
  
  /// Starts recording system audio to a temporary file.
  /// Returns the URL where the recording will be saved.
  func startRecording() async throws -> URL {
    NSLog("[SimpleAudioRecorder] 🎙️ Starting audio recording...")
    
    // Clean up any existing recording
    try await stopIfNeeded()
    
    // Create output file
    let url = makeTempURL()
    outputURL = url
    NSLog("[SimpleAudioRecorder] 📁 Output file: \(url.path)")
    
    // Setup AVAssetWriter
    try setupWriter(url: url)
    
    // Get shareable content and create filter
    let filter = try await createContentFilter()
    NSLog("[SimpleAudioRecorder] ✅ Content filter created successfully")
    
    // Create and configure stream
    let stream = try createStream(filter: filter)
    self.stream = stream
    
    // Start capture
    do {
      try await stream.startCapture()
      NSLog("[SimpleAudioRecorder] ✅ Stream started successfully, waiting for audio samples...")
    } catch {
      NSLog("[SimpleAudioRecorder] ❌ Failed to start stream: \(error.localizedDescription)")
      throw RecordingError.streamStartFailed(error)
    }
    
    return url
  }
  
  /// Stops recording and returns the URL of the saved file.
  /// Throws an error if no samples were received.
  func stopRecording() async throws -> URL {
    NSLog("[SimpleAudioRecorder] 🛑 Stopping recording...")
    
    guard let stream = stream,
          let writer = writer,
          let url = outputURL else {
      throw RecordingError.writerSetupFailed
    }
    
    // Stop the stream first
    do {
      try await stream.stopCapture()
      NSLog("[SimpleAudioRecorder] Stream stopped")
    } catch {
      NSLog("[SimpleAudioRecorder] ⚠️ Error stopping stream (may already be stopped): \(error.localizedDescription)")
      // Continue anyway - stream might have been stopped by system
    }
    
    // Clean up stream
    try? stream.removeStreamOutput(self, type: .audio)
    try? stream.removeStreamOutput(self, type: .screen)
    self.stream = nil
    
    // Check if we received any samples
    guard sampleCount > 0 else {
      NSLog("[SimpleAudioRecorder] ❌ No audio samples received!")
      throw RecordingError.noAudioSamplesReceived
    }
    
    // Finish writing
    return try await finishWriting(writer: writer, url: url)
  }
  
  // MARK: - Private Setup Methods
  
  private func setupWriter(url: URL) throws {
    NSLog("[SimpleAudioRecorder] Setting up AVAssetWriter...")
    
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    
    // Audio settings that match ScreenCaptureKit's typical output
    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 128000
    ]
    
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    input.expectsMediaDataInRealTime = true
    
    guard writer.canAdd(input) else {
      throw RecordingError.writerSetupFailed
    }
    
    writer.add(input)
    
    self.writer = writer
    self.audioInput = input
    self.firstPTS = nil
    self.sampleCount = 0
    
    NSLog("[SimpleAudioRecorder] ✅ Writer setup complete")
  }
  
  private func createContentFilter() async throws -> SCContentFilter {
    NSLog("[SimpleAudioRecorder] Getting shareable content...")
    
    let content = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCShareableContent, Error>) in
      SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
        if let error = error {
          NSLog("[SimpleAudioRecorder] ❌ Error getting shareable content: \(error.localizedDescription)")
          continuation.resume(throwing: error)
        } else if let content = content {
          NSLog("[SimpleAudioRecorder] ✅ Got content: \(content.displays.count) displays, \(content.windows.count) windows, \(content.applications.count) applications")
          continuation.resume(returning: content)
        } else {
          NSLog("[SimpleAudioRecorder] ❌ No content returned")
          continuation.resume(throwing: RecordingError.noCapturableContent)
        }
      }
    }
    
    // Try multiple strategies to create a valid filter
    
    // Strategy 1: Use desktop windows (most reliable for audio)
    if let desktopWindow = content.windows.first {
      NSLog("[SimpleAudioRecorder] Using desktop window: \(desktopWindow.windowID)")
      return SCContentFilter(desktopIndependentWindow: desktopWindow)
    }
    
    // Strategy 2: Use main display with all applications
    if let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) {
      NSLog("[SimpleAudioRecorder] Using main display: \(mainDisplay.displayID)")
      return SCContentFilter(display: mainDisplay, excludingApplications: [], exceptingWindows: [])
    }
    
    // Strategy 3: Use first available display
    if let firstDisplay = content.displays.first {
      NSLog("[SimpleAudioRecorder] Using first display: \(firstDisplay.displayID)")
      return SCContentFilter(display: firstDisplay, excludingApplications: [], exceptingWindows: [])
    }
    
    // Strategy 4: Use Google Chrome (where music is playing)
    // Log all available apps for debugging
    NSLog("[SimpleAudioRecorder] Available applications: \(content.applications.map { $0.bundleIdentifier ?? "unknown" })")
    
    if let chromeApp = content.applications.first(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
      NSLog("[SimpleAudioRecorder] ✅ Found Google Chrome: \(chromeApp.bundleIdentifier ?? "unknown")")
      
      guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        throw RecordingError.noCapturableContent
      }
      
      let otherApps = content.applications.filter { $0.bundleIdentifier != "com.google.Chrome" }
      return SCContentFilter(display: mainDisplay, excludingApplications: otherApps, exceptingWindows: [])
    } else {
      NSLog("[SimpleAudioRecorder] ⚠️ Google Chrome not found in running applications")
      throw RecordingError.noCapturableContent
    }
    
    throw RecordingError.noCapturableContent
  }
  
  private func createStream(filter: SCContentFilter) throws -> SCStream {
    NSLog("[SimpleAudioRecorder] Creating stream configuration...")
    
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.sampleRate = 48000
    configuration.channelCount = 2
    
    // Important: We need to capture screen too (even if we don't use it) for audio to work
    configuration.width = 1
    configuration.height = 1
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum
    
    NSLog("[SimpleAudioRecorder] Stream config: audio=true, sampleRate=48000, channels=2")
    
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    
    // Add both audio and screen outputs (screen is required for audio to work)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
    
    NSLog("[SimpleAudioRecorder] ✅ Stream created with audio and screen outputs")
    
    return stream
  }
  
  private func finishWriting(writer: AVAssetWriter, url: URL) async throws -> URL {
    return try await withCheckedThrowingContinuation { continuation in
      writerQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(throwing: RecordingError.writerSetupFailed)
          return
        }
        
        // Mark input as finished
        if let input = self.audioInput, writer.status != .unknown {
          input.markAsFinished()
          NSLog("[SimpleAudioRecorder] Audio input marked as finished")
        }
        self.audioInput = nil
        
        // Finish writing
        if writer.status != .unknown {
          writer.finishWriting {
            if writer.status == .completed {
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
              NSLog("[SimpleAudioRecorder] ✅ Recording saved: \(url.path) (\(size) bytes, \(self.sampleCount) samples)")
              continuation.resume(returning: url)
            } else {
              let error = writer.error ?? RecordingError.writerFailed(nil)
              NSLog("[SimpleAudioRecorder] ❌ Writer failed: \(String(describing: writer.error))")
              continuation.resume(throwing: RecordingError.writerFailed(writer.error))
            }
          }
        } else {
          NSLog("[SimpleAudioRecorder] ❌ Writer never started")
          continuation.resume(throwing: RecordingError.writerFailed(nil))
        }
      }
    }
  }
  
  private func stopIfNeeded() async throws {
    if let stream = stream {
      do {
        try await stream.stopCapture()
      } catch {
        // Ignore errors when stopping - stream might already be stopped
        NSLog("[SimpleAudioRecorder] ⚠️ Error stopping existing stream: \(error.localizedDescription)")
      }
      try? stream.removeStreamOutput(self, type: .audio)
      try? stream.removeStreamOutput(self, type: .screen)
    }
    stream = nil
    writer = nil
    audioInput = nil
    outputURL = nil
    firstPTS = nil
    sampleCount = 0
  }
  
  private func makeTempURL() -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let timestamp = formatter.string(from: Date())
    
    let filename = "SimpleAudio_\(timestamp).m4a"
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
  }
}

// MARK: - SCStreamOutput

extension SimpleAudioRecorder: SCStreamOutput {
  func stream(_ stream: SCStream, didOutput sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    // Only process audio samples
    guard type == .audio else {
      return
    }
    
    sampleCount += 1
    
    // Log first sample
    if sampleCount == 1 {
      NSLog("[SimpleAudioRecorder] 🎵 First audio sample received!")
    } else if sampleCount % 100 == 0 {
      NSLog("[SimpleAudioRecorder] 📊 Received \(sampleCount) audio samples")
    }
    
    guard let writer = writer,
          let input = audioInput,
          CMSampleBufferIsValid(sampleBuffer) else {
      if writer == nil {
        NSLog("[SimpleAudioRecorder] ⚠️ Writer is nil when receiving sample")
      } else if audioInput == nil {
        NSLog("[SimpleAudioRecorder] ⚠️ AudioInput is nil when receiving sample")
      } else {
        NSLog("[SimpleAudioRecorder] ⚠️ Sample buffer is invalid")
      }
      return
    }
    
    // Handle first sample: start writer
    if firstPTS == nil {
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      firstPTS = pts
      
      writerQueue.async { [weak self] in
        guard let self = self, let writer = self.writer else { return }
        writer.startWriting()
        writer.startSession(atSourceTime: pts)
        NSLog("[SimpleAudioRecorder] ✅ Writer started at PTS: \(pts.seconds)")
      }
    }
    
    // Append sample
    guard input.isReadyForMoreMediaData else {
      return
    }
    
    writerQueue.async { [weak self] in
      guard let self = self,
            let input = self.audioInput,
            input.isReadyForMoreMediaData else {
        return
      }
      
      if !input.append(sampleBuffer) {
        NSLog("[SimpleAudioRecorder] ❌ Failed to append sample: \(String(describing: self.writer?.error))")
      }
    }
  }
}

// MARK: - SCStreamDelegate

extension SimpleAudioRecorder: SCStreamDelegate {
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    NSLog("[SimpleAudioRecorder] ⚠️ Stream stopped with error: \(error.localizedDescription)")
  }
}

