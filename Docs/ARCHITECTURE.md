# Palora – Architecture and Tradeoffs

Palora is a lean macOS menu bar app that records system audio during meetings, transcribes it with a cloud STT API, summarizes via an LLM, and saves Markdown notes locally.

## High‑Level Flow

1) Detection: `MeetingDetector` polls the frontmost app (Zoom/Teams/Browser) to infer meeting start/stop.
2) Recording: `RecordingController` starts `AudioCaptureService` (ScreenCaptureKit) to capture system audio to a temp `.m4a` file.
3) Transcription: `TranscriptionService` uploads the audio file to OpenAI Whisper (`/audio/transcriptions`) for a transcript.
4) Summarization: `SummaryService` calls OpenAI Chat Completions to produce structured `MeetingNotes` (summary, key points, action items) in JSON.
5) Export: `MarkdownExporter` saves a timestamped `.md` file in `~/Documents/Meeting Notes`.
6) Indicator: `StatusBarController` toggles a red dot when recording.

## Modules

- App/: `PaloraApp`, DI wiring; `Permissions` helper for Screen Recording.
- UI/: `StatusBarController` (NSStatusItem + NSMenu).
- Audio/: `AudioCaptureService` (ScreenCaptureKit audio‑only → AVAssetWriter `.m4a`).
- Meetings/: `MeetingDetector` (NSWorkspace heuristic + debounce).
- AI/: `TranscriptionService` (Whisper HTTP), `SummaryService` (LLM chat completions).
- Storage/: `MarkdownExporter` (writes `.md`).
- Orchestration/: `RecordingController` (FSM: idle → recording → finalizing → idle|error).
- Config/: `AppConfig`, `NotesDirectoryProviding`, `APIKeyProviding`.

## Key Decisions & Tradeoffs

### Audio Capture
- Chosen: ScreenCaptureKit (SCStream) with audio‑only capture.
  - Pros: Apple‑supported, no third‑party drivers, good permissions UX.
  - Cons: Requires Screen Recording permission; not available on very old macOS.
- Alternative: Virtual audio device (e.g., BlackHole) + AVAudioEngine.
  - Pros: System‑wide routing control; flexible.
  - Cons: Extra install step; higher friction for MVP.
- Alternative: CoreAudio aggregate device + process taps.
  - Pros: Precise, low‑level control.
  - Cons: Complex to implement; brittle across OS changes for an MVP.

### Meeting Detection
- Chosen: Frontmost app heuristic (Zoom/Teams/Browser) with light debounce.
  - Pros: Simple, no special entitlements to start.
  - Cons: Can false‑positive/negative; doesn’t inspect window titles without AX.
- Future: Add Accessibility (AX) window title checks or mic‑in‑use signals for improved accuracy.

### STT + LLM
- Chosen: Cloud APIs (OpenAI Whisper + GPT) via `URLSession`.
  - Pros: Minimal local complexity; predictable results.
  - Cons: Requires internet, ongoing API cost, privacy considerations.
- Alternative: Local Whisper/LLM.
  - Pros: Privacy, offline.
  - Cons: Larger code and distribution footprint; performance constraints.

### Orchestration
- `RecordingController` is the integration point for triggers and errors.
  - All UI or detection signals call `startRequested()` / `stopRequested()`.
  - Errors (permissions, network) are surfaced to the user and return to a safe state.
  - Easy to extend with more detectors (calendar, window titles) or UI entry points.

### Storage
- Markdown in `~/Documents/Meeting Notes` by default.
  - Pros: Transparent, simple backups, easy to sync with tools (Obsidian, Git).
  - Cons: No encryption by default; users may prefer a custom directory.

## Permissions & Privacy
- Requires Screen Recording permission to capture system audio.
- API key is provided by `APIKeyProviding` (env or UserDefaults by default). Prefer Keychain for production.
- Audio files are kept in temporary directory only until upload completes; summaries and transcripts saved locally in Markdown.

## Extensibility
- Add mic capture and mix with system audio for speaker attribution.
- Support multiple STT providers and LLMs behind small protocols.
- Add a minimal preferences window for API key and notes directory.
- Calendar integration for automatic meeting start/stop.

## Risks & Mitigations
- Permission denials → Guided prompt with link to System Settings.
- Network failures → Error state + retry after stop.
- Heuristic detection errors → Manual Start/Stop always available from menu.

## Glossary
- SCStream: ScreenCaptureKit stream used to obtain audio sample buffers.
- AVAssetWriter: Encodes `CMSampleBuffer` audio to `.m4a` for upload.

---

This MVP favors clarity, minimal dependencies, and a single orchestration point to make future extensions straightforward.


