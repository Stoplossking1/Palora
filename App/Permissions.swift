import Foundation
import ScreenCaptureKit
import AppKit

enum Permissions {
  static func ensureScreenRecordingPermission(completion: @escaping (Bool) -> Void) {
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
      if let err = error {
        NSLog("ScreenCaptureKit error: \(err.localizedDescription)")
      }
      let granted = (content != nil)
      DispatchQueue.main.async {
        completion(granted)
      }
    }
  }

  static func promptToOpenSettings() {
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.messageText = "Screen Recording Permission Needed"
      alert.informativeText = "Palora needs Screen Recording permission to capture system audio. Open System Settings → Privacy & Security → Screen Recording, enable permission for this app, then restart Palora."
      alert.alertStyle = .informational
      alert.addButton(withTitle: "Open Settings")
      alert.addButton(withTitle: "Cancel")
      let result = alert.runModal()
      if result == .alertFirstButtonReturn {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
          NSWorkspace.shared.open(url)
        }
      }
    }
  }
}