import Foundation
import AVFoundation
import ScreenCaptureKit

final class AudioCaptureService: NSObject {
  enum CaptureError: Error {
    case noDisplay
    case writerSetupFailed
    case writerFailed
  }

  private let writerQueue = DispatchQueue(label: "palora.audio.writer")
  private let captureQueue = DispatchQueue(label: "palora.audio.capture")

  private var stream: SCStream?
  private var writer: AVAssetWriter?
  private var audioInput: AVAssetWriterInput?
  private var firstPTS: CMTime?
  private var outputURL: URL?

    func startRecordingSystemAudio() async throws -> URL {
      try await stopIfNeeded()

      let url = Self.makeTempURL()
      outputURL = url
      NSLog("[AudioCapture] Preparing recording at \(url.path)")

      let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000
      ]
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
      input.expectsMediaDataInRealTime = true

      guard writer.canAdd(input) else { throw CaptureError.writerSetupFailed }
      writer.add(input)

      self.writer = writer
      self.audioInput = input
      self.firstPTS = nil

      // Use callback-based API with proper error handling
      let content = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCShareableContent, Error>) in
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
          if let error = error {
            NSLog("[AudioCapture] ERROR getting shareable content: \(error.localizedDescription)")
            continuation.resume(throwing: error)
          } else if let content = content {
            NSLog("[AudioCapture] Got shareable content: \(content.displays.count) displays, \(content.windows.count) windows")
            continuation.resume(returning: content)
          } else {
            NSLog("[AudioCapture] ERROR: No content and no error returned")
            continuation.resume(throwing: CaptureError.noDisplay)
          }
        }
      }

      guard let display = content.displays.first else {
        NSLog("[AudioCapture] ERROR: No displays found in content")
        throw CaptureError.noDisplay
      }
      NSLog("[AudioCapture] Using display \(display.displayID)")

      let filter = SCContentFilter(display: display,
                                   excludingApplications: [],
                                   exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue) // Required for audio to work
        
      self.stream = stream
      try await stream.startCapture()
      NSLog("[AudioCapture] Stream started, waiting for first audio sample...")
      return url
    }

    func stopRecordingSystemAudio() async throws -> URL {
      guard let stream = stream,
            let writer = writer,
            let url = outputURL else {
        throw CaptureError.writerSetupFailed
      }

      try await stream.stopCapture()
      try? stream.removeStreamOutput(self, type: .audio)
      try? stream.removeStreamOutput(self, type: .screen)
      self.stream = nil

      // Only mark as finished if writer actually started (we received samples)
      return try await withCheckedThrowingContinuation { continuation in
        // Safe: writer is only accessed on writerQueue (serial)
        nonisolated(unsafe) let capturedWriter = writer
        writerQueue.async { [weak self, url] in
          guard let self = self else { return }
          
          // Check if writer started (status != .unknown) before marking input finished
          if capturedWriter.status != .unknown, let input = self.audioInput {
            input.markAsFinished()
            self.audioInput = nil
          } else {
            // Writer never started, just clean up
            self.audioInput = nil
            NSLog("[AudioCapture] No samples received, writer never started")
          }

          // Only finish writing if writer was started
          if capturedWriter.status != .unknown {
            capturedWriter.finishWriting {
              if capturedWriter.status == .completed {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                NSLog("[AudioCapture] Recording saved to \(url.path), size: \(size) bytes")
                continuation.resume(returning: url)
              } else {
                let error = capturedWriter.error ?? CaptureError.writerFailed
                NSLog("[AudioCapture] Writer failed: \(String(describing: capturedWriter.error))")
                continuation.resume(throwing: error)
              }
            }
          } else {
            // Writer never started, return error
            NSLog("[AudioCapture] Cannot finish: writer never started (no audio samples received)")
            continuation.resume(throwing: CaptureError.writerFailed)
          }
        }
      }
    }

  private func stopIfNeeded() async throws {
    if let stream = stream {
      try await stream.stopCapture()
      try? stream.removeStreamOutput(self, type: .audio)
      try? stream.removeStreamOutput(self, type: .screen)
    }
    stream = nil
    writer = nil
    audioInput = nil
    outputURL = nil
    firstPTS = nil
  }

  private static func makeTempURL() -> URL {
    let name = "Palora_\(timestamp()).m4a"
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter.string(from: Date())
  }
}

extension AudioCaptureService: SCStreamOutput {
  func stream(_ stream: SCStream, didOutput sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    // Silently drop video frames - we only want audio
    guard type == .audio else {
      return
    }
    
    NSLog("[AudioCapture] Received audio sample")
    
    guard let writer = writer,
          let input = audioInput,
          sampleBuffer.isValid else {
      if writer == nil {
        NSLog("[AudioCapture] Writer is nil!")
      } else if audioInput == nil {
        NSLog("[AudioCapture] AudioInput is nil!")
      } else if !sampleBuffer.isValid {
        NSLog("[AudioCapture] Sample buffer is invalid!")
      }
      return
    }

    // Handle first sample: start writer and session on writer queue
    if firstPTS == nil {
      firstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      guard let firstPTS = firstPTS else {
        NSLog("[AudioCapture] Failed to get PTS from first sample")
        return
      }

      writerQueue.async { [weak self] in
        guard let self = self, let writer = self.writer else { return }
        writer.startWriting()
        writer.startSession(atSourceTime: firstPTS)
        NSLog("[AudioCapture] ✅ Writer started, first audio sample at \(firstPTS.seconds)")
      }
    }

    // Append sample on writer queue
    guard input.isReadyForMoreMediaData else {
      NSLog("[AudioCapture] Input not ready for more data")
      return
    }
    writerQueue.async { [weak self] in
      guard let self = self,
            let input = self.audioInput,
            input.isReadyForMoreMediaData else { return }
      if !input.append(sampleBuffer) {
        NSLog("[AudioCapture] ❌ Failed to append sample: \(String(describing: self.writer?.error))")
      }
    }
  }
}

extension AudioCaptureService: SCStreamDelegate {
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    NSLog("[AudioCapture] Stream stopped with error: \(error.localizedDescription)")
  }
}
// final class AudioCaptureService: NSObject {
//   enum CaptureError: Error {
//     case writerSetupFailed
//     case writerInputFailed
//     case missingFirstTimestamp
//   }

//   private let writerQueue = DispatchQueue(label: "palora.audio.writer")
//   private let captureQueue = DispatchQueue(label: "palora.audio.capture")

//   private var stream: SCStream?
//   private var writer: AVAssetWriter?
//   private var audioInput: AVAssetWriterInput?
//   private var firstPTS: CMTime?
//   private var outputURL: URL?

//   func startRecordingSystemAudio() throws {
//   stopIfRunning()

//   let filename = "Palora_\(Self.timestampString()).m4a"
//   let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
//   self.outputURL = url
//   NSLog("[AudioCapture] Starting recording to: \(url.path)")

//   let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
//   let audioSettings: [String: Any] = [
//     AVFormatIDKey: kAudioFormatMPEG4AAC,
//     AVNumberOfChannelsKey: 2,
//     AVSampleRateKey: 48000,
//     AVEncoderBitRateKey: 128_000
//   ]
//   let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
//   input.expectsMediaDataInRealTime = true

//   if writer.canAdd(input) {
//     writer.add(input)
//   } else {
//     throw CaptureError.writerSetupFailed
//   }

//   self.writer = writer
//   self.audioInput = input
//   self.firstPTS = nil

//   let content = try awaitShareableContent()
//   guard let display = content.displays.first else {
//     NSLog("[AudioCapture] ERROR: No displays found")
//     throw CaptureError.writerSetupFailed
//   }
//   NSLog("[AudioCapture] Using display: \(display.displayID)")
  
//   let filter = SCContentFilter(display: display, excludingWindows: [])
//   let config = SCStreamConfiguration()
//   config.capturesAudio = true
//   config.sampleRate = 48000
//   config.channelCount = 2
  
//   NSLog("[AudioCapture] Stream config: capturesAudio=true, sampleRate=48000, channels=2")

//   let stream = SCStream(filter: filter, configuration: config, delegate: self)
//   try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)

//   writer.startWriting()
//   writer.startSession(atSourceTime: .zero)
//   NSLog("[AudioCapture] Writer started, status: \(writer.status.rawValue)")
  
//   stream.startCapture()
//   NSLog("[AudioCapture] Stream capture started")

//   self.stream = stream
// }

//   func stopRecordingSystemAudio() async throws -> URL {
//   guard let writer = writer, let url = outputURL else {
//     throw CaptureError.writerSetupFailed
//   }

//   // Stop the stream first to stop new samples
//   stopStream()

//   // Mark input as finished
//   audioInput?.markAsFinished()
//   self.audioInput = nil

//   // Wait for writer to finish on its queue
//   return try await withCheckedThrowingContinuation { continuation in
//     // Safe: writer is only accessed on writerQueue (serial)
//     nonisolated(unsafe) let capturedWriter = writer
//     writerQueue.async { [url] in
//       capturedWriter.finishWriting {
//         // Check if we actually wrote samples
//         if capturedWriter.status == .completed {
//           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
//           NSLog("[AudioCapture] Wrote file: \(url.path), size: \(size)")
//           continuation.resume(returning: url)
//         } else {
//           NSLog("[AudioCapture] Writer failed: \(capturedWriter.status.rawValue), error: \(String(describing: capturedWriter.error))")
//           continuation.resume(throwing: capturedWriter.error ?? CaptureError.writerInputFailed)
//         }
//       }
//     }
//   }
// }

// private func fileSize(_ url: URL) -> Int {
//   (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
// }

//   private func stopIfRunning() {
//     if stream != nil {
//       stopStream()
//     }
//   }

//   private func stopStream() {
//     stream?.stopCapture()
//     stream = nil
//   }

//   private func awaitShareableContent() throws -> SCShareableContent {
//     let semaphore = DispatchSemaphore(value: 0)
//     var result: Result<SCShareableContent, Error>!
//     SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
//       if let error = error {
//         result = .failure(error)
//       } else if let content = content {
//         result = .success(content)
//       } else {
//         result = .failure(NSError(domain: "Palora", code: -1, userInfo: [NSLocalizedDescriptionKey: "No content"]))
//       }
//       semaphore.signal()
//     }
//     semaphore.wait()
//     switch result! {
//     case .success(let content): return content
//     case .failure(let error): throw error
//     }
//   }

//   private static func timestampString() -> String {
//     let df = DateFormatter()
//     df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
//     return df.string(from: Date())
//   }
// }

// extension AudioCaptureService: SCStreamOutput {
//   func stream(_ stream: SCStream, didOutput sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
//     guard type == .audio else { return }
//     guard let input = audioInput, input.isReadyForMoreMediaData else {
//       NSLog("[AudioCapture] WARNING: Input not ready for data")
//       return
//     }
//     if firstPTS == nil {
//       firstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
//       NSLog("[AudioCapture] First audio sample received")
//     }
//     input.append(sampleBuffer)
//   }
// }

// extension AudioCaptureService: SCStreamDelegate {
//   func stream(_ stream: SCStream, didStopWithError error: Error) {
//     NSLog("[AudioCapture] Stream stopped with error: \(error.localizedDescription)")
//   }
// }


