import AppKit

final class MeetingDetector {
  var onStart: (() -> Void)?
  var onEnd: (() -> Void)?

  private var timer: Timer?
  private var isInMeeting = false
  private var lastNonMeetingAt: Date = Date()

  private let meetingBundles: Set<String> = [
    "us.zoom.xos",
    "us.zoom.xos.ZoomDaemon",
    "us.zoom.ZoomOpener",
    "com.microsoft.teams",
    "com.microsoft.teams2",
    "com.apple.Safari",
    "com.google.Chrome",
    "org.mozilla.firefox"
  ]

  func start() {
    stop()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    guard let front = NSWorkspace.shared.frontmostApplication else { return }
    let bundle = front.bundleIdentifier ?? ""

    let looksLikeMeetingApp = meetingBundles.contains(bundle)

    if looksLikeMeetingApp && !isInMeeting {
      isInMeeting = true
      onStart?()
    } else if !looksLikeMeetingApp && isInMeeting {
      // Debounce exit: wait ~5 seconds off meeting apps to mark end.
      if Date().timeIntervalSince(lastNonMeetingAt) > 5 {
        isInMeeting = false
        onEnd?()
      }
    }

    if !looksLikeMeetingApp {
      lastNonMeetingAt = Date()
    }
  }
}


