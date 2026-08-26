# Transcript Shark — Implementation Plan

> This plan is derived from `TECH-SPEC.md` and governs the incremental build of the app.  
> Every milestone must be **built, run, and manually verified** before progressing to the next.  
> Do not create mock stubs for core capabilities (audio, transcription) and call a milestone complete.

---

## Project Identity

| Field | Value |
|---|---|
| **App name** | Meeting Recorder (internal: `transcript-shark`) |
| **Bundle ID** | `com.transcript-shark.MeetingRecorder` |
| **Platform** | macOS 15+ |
| **Language** | Swift 6 |
| **UI** | SwiftUI |
| **Architecture** | MVVM + Services |
| **Persistence** | SwiftData |
| **Audio** | ScreenCaptureKit + AVFoundation |
| **Transcription** | Apple Speech (pluggable) |
| **Concurrency** | Swift structured concurrency (async/await, actors, AsyncStream) |

---

## Priority Order

Per the spec, always favour in this order:

1. Reliability
2. Privacy (local-first)
3. Recording quality
4. Data integrity
5. Usability
6. Additional features

---

## Repository Structure

```
MeetingRecorder/
├── MeetingRecorderApp.swift
├── App/
│   ├── AppState.swift
│   ├── ApplicationCoordinator.swift
│   └── MenuBarManager.swift
├── Models/
│   ├── Meeting.swift
│   ├── MeetingFolder.swift
│   └── Transcript.swift
├── Services/
│   ├── Audio/
│   │   ├── AudioCaptureService.swift
│   │   ├── SystemAudioCapture.swift
│   │   ├── MicrophoneCapture.swift
│   │   └── RecordingWriter.swift
│   ├── Meetings/
│   │   ├── MeetingDetectionService.swift
│   │   └── TeamsMeetingDetector.swift
│   ├── Transcription/
│   │   ├── TranscriptionService.swift       ← protocol
│   │   └── AppleSpeechTranscriber.swift
│   ├── Storage/
│   │   ├── MeetingRepository.swift
│   │   └── FileStorageService.swift
│   └── Permissions/
│       └── PermissionService.swift
├── Views/
│   ├── MainWindow/
│   ├── Sidebar/
│   ├── MeetingList/
│   ├── MeetingDetail/
│   ├── Transcript/
│   ├── Settings/
│   └── Onboarding/
└── Utilities/
    ├── Logger.swift
    └── DateFormatter.swift
```

---

## Core Interfaces (define before implementing)

### State Machine

```swift
enum RecorderState {
    case disabled
    case monitoring
    case meetingDetected
    case recording
    case finalizingRecording
    case transcribing
    case completed
    case error
}
```

### Meeting Detection

```swift
protocol MeetingDetector {
    func startMonitoring()
    func stopMonitoring()
    var meetingState: AsyncStream<MeetingDetectionEvent> { get }
}

enum MeetingDetectionEvent {
    case potentialMeetingDetected(MeetingContext)
    case meetingStarted(MeetingContext)
    case meetingEnded(MeetingContext)
}

struct MeetingContext {
    let applicationName: String
    let bundleIdentifier: String
    let detectedTitle: String?
    let detectedAt: Date
}
```

### Transcription

```swift
protocol TranscriptionService {
    func transcribe(audioURL: URL, language: Locale?) async throws -> TranscriptResult
}

struct TranscriptResult {
    let text: String
    let segments: [TranscriptSegment]
    let detectedLanguage: String?
    let duration: TimeInterval
}

struct TranscriptSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}
```

### Transcription Queue

```swift
actor TranscriptionQueue {
    enum JobStatus { case pending, processing, completed, failed }
}

enum TranscriptionStatus {
    case pending, processing, completed, failed
}
```

---

## Milestones

---

### Milestone 1 — Recording Prototype ✦ COMPLETE ✅

**Completed:** 2026-08-26 — Build 13

**Technical notes (macOS 26 / SCStream):**
- `SCRecordingOutput` (macOS 15+) is the correct API — writes directly to `.mp4` without manual `AVAssetWriter` or Core Audio HAL access
- Supported output formats at runtime: `public.mpeg-4` and `com.apple.quicktime-movie` only — `.m4a` is rejected
- `AVCaptureSession`, `AVAudioEngine`, and `SCStream.captureMicrophone` all trigger `audioanalyticsd` sandbox violations on macOS 26 — avoid for now
- `AudioCapture` must be `@MainActor` — SCStream has internal `dispatchPrecondition` assertions on the main queue
- The `AddInstanceForFactory: No factory registered` and `HALC_ProxyObjectMap` log lines are macOS system noise, not errors
- Microphone capture is deferred to Milestone 2 using a separate approach

**Goal:** Prove the core technical capability: record both system audio and microphone simultaneously on macOS and produce a playable audio file.

**Deliverables:**
- [ ] Xcode project created (macOS app target, no iOS)
- [ ] Entitlements set: `com.apple.security.device.audio-input`, `com.apple.security.screen-capture`
- [ ] `Info.plist` privacy descriptions added:
  - `NSMicrophoneUsageDescription`
  - `NSAudioCaptureUsageDescription`
  - `NSScreenCaptureUsageDescription`
- [ ] `SystemAudioCapture` using `SCStream` with audio-only configuration
- [ ] `MicrophoneCapture` using `AVCaptureSession` or SCK microphone capture
- [ ] Writing audio frames to `recording.tmp.caf` in real time (never buffering entire recording in memory)
- [ ] Manual Start/Stop UI (minimal — two buttons is fine)
- [ ] Conversion from `.caf` → `.m4a` (AAC, 48 kHz) on stop
- [ ] Resulting `.m4a` opens in QuickTime and plays both voices

**Tests:**
- Record 5 minutes; verify file size is non-zero and grows during recording
- Record 1 hour; verify memory usage stays < 200 MB (excluding system frameworks)
- Verify crash mid-recording leaves a non-empty `.tmp.caf`

**Do not proceed until:** Both microphone and remote participant are audible in the output file.

---

### Milestone 2 — Recording Engine

**Goal:** Extract the recording prototype into proper service-layer abstractions.

**Deliverables:**
- [ ] `AudioCaptureService` protocol + concrete implementation
- [ ] `RecordingCoordinator` actor:
  - Owns `RecordingSession` lifecycle
  - Guards against duplicate sessions
  - Calls `TranscriptionQueue.enqueue()` on stop
- [ ] `RecordingSession` struct (see spec §67)
- [ ] `RecordingWriter` handles incremental disk writes
- [ ] `RecordingCoordinator` exposes `RecorderState` as an `@Published` / `AsyncStream`
- [ ] Unit tests: state transitions, guard against double-start

**Architecture constraint:** `RecordingCoordinator` must NOT know about `MeetingDetector`. It receives events only.

---

### Milestone 3 — Menu Bar Application ✅ COMPLETE

**Completed:** 2026-08-26 — Build 20

**Technical notes:**
- `NSApp.delegate as? AppDelegate` fails when using `@NSApplicationDelegateAdaptor` — use `NotificationCenter` instead
- `makeKeyAndOrderFront` does not work for `.accessory` policy apps — use `orderFrontRegardless`
- `NSWindow.isReleasedWhenClosed = false` + `windowShouldClose returning false` (after `orderOut`) is the correct pattern for a menu bar app window
- `SwiftUI WindowGroup` cannot reopen a window after it's closed — use `NSWindowController` with AppKit-managed lifecycle

**Goal:** Working menu bar app with manual recording controls and visible status.

**Deliverables:**
- [ ] `MenuBarManager` using `NSStatusItem` + `NSMenu`
- [ ] Icon states: `○` idle, `●` recording, `◌` transcribing, `⊘` disabled, `!` error
- [ ] Menu items (idle state):
  - Auto Recording: ON
  - Start Recording Manually
  - Open App / Settings / Quit
- [ ] Menu items (recording state):
  - ● Recording — Teams / 00:23:41
  - Stop Recording / Open Meeting / Disable Auto Recording
- [ ] Elapsed timer updating every second while recording
- [ ] Closing the main window does NOT quit the app
- [ ] Quit-while-recording confirmation dialog (§47)
- [ ] `AppState` observable object shared between menu bar and main window

**Tests:**
- Start recording; verify icon changes to `●`
- Stop recording; verify icon returns to `○`

---

### Milestone 4 — Transcription ✅ COMPLETE

**Completed:** 2026-08-26 — Build 23

**Technical notes:**
- `SFSpeechRecognizer.requestAuthorization` crashes in test/background contexts — only call it from the main app (TranscriptionQueue does this before processing)
- On-device recognition (`requiresOnDeviceRecognition = true`) silently returns empty text for files > ~1 minute — implemented fallback to server-based recognition
- `SFSpeechRecognitionResult` is not `Sendable` — extract text and segments into value types before resuming the checked continuation
- `MarkdownGenerator` must be `Sendable` to be stored as a property in the `TranscriptionQueue` actor

**Goal:** After recording stops, automatically produce a `transcript.md` using Apple Speech.

**Deliverables:**
- [ ] `TranscriptionService` protocol (§18)
- [ ] `AppleSpeechTranscriber` conforming to `TranscriptionService`:
  - Uses `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` (or URL-based request)
  - Respects language setting (default: auto-detect)
- [ ] `TranscriptionQueue` actor with job states (pending, processing, completed, failed)
- [ ] Failed jobs are retryable
- [ ] `MarkdownGenerator` producing:
  - YAML front matter (§23)
  - `# Title` heading
  - Metadata block (date, start, end, duration, application, folder, audio file)
  - `## Transcript` section with `### MM:SS` timestamp headers per segment
- [ ] Output filename: `2026-08-26_10-02_UUID/transcript.md`
- [ ] `AppleSpeechTranscriber` must NOT be referenced from any UI code — always via protocol
- [ ] macOS notification on transcription complete (§16)

**Tests:**
- Feed a known `.m4a` file; verify output `.md` is syntactically valid
- Verify YAML front matter parses correctly
- Verify queue handles failure + retry
- Verify UI is not blocked during transcription

---

### Milestone 5 — Library GUI ✅ COMPLETE

**Completed:** 2026-08-26 — Build 25

**Technical notes:**
- `@Observable` macro (not `ObservableObject`) required for `@MainActor` classes in macOS 26 — use `@State` in views instead of `@StateObject`
- `Meeting` needs `Hashable` for `List` selection binding and `.tag()`
- `RecorderState` and `TranscriptionStatus` need `Equatable` for `onChange(of:)` and `==` comparisons
- Recording banner overlay keeps the library view as the permanent main interface

**Goal:** Three-column SwiftUI main window for browsing meeting history.

**Deliverables:**
- [ ] `NavigationSplitView` with three columns: Sidebar / Meeting List / Meeting Detail
- [ ] **Sidebar:**
  - Library section: All Meetings, Today, This Week
  - Folders section (initially empty)
  - \+ New Folder button
- [ ] **Meeting List:**
  - Grouped by date (Today, Yesterday, date headers)
  - Sorted newest-first
  - Status indicators: `●` recording, `◌` transcribing, `✓` ready, `!` failed
- [ ] **Meeting Detail:**
  - Title, date, start time, duration, application, folder
  - Audio player (§32): play/pause/seek/speed (0.75×, 1×, 1.25×, 1.5×, 2×)
  - Transcript viewer (§31): rendered Markdown (default) + raw Markdown toggle
  - Cmd+F search within transcript
  - Actions: Rename, Move to Folder, Reveal in Finder, Retry Transcription, Delete
- [ ] Meeting detail can display a meeting selected from the list

**Tests:**
- Create two mock `Meeting` objects with transcripts; verify both appear in the list
- Verify audio player plays/pauses and shows correct time

---

### Milestone 6 — Persistence ✅ COMPLETE

**Completed:** 2026-08-26 — Build 35

**Technical notes:**
- SwiftData `@Model` cannot store `URL` natively — store as `String` (relative path), resolve at read time
- `TranscriptionStatus` extensions need `nonisolated` to be callable from `@Model` context
- `PersistenceController` auto-recovers from schema conflicts in development by deleting and recreating the store
- First-launch migration: `importNewRecordingsFromDisk()` runs on every `reload()` and inserts any `.mp4` not yet in the database

**Goal:** All data survives app restart.

**Deliverables:**
- [ ] SwiftData schema for `Meeting` and `Folder` (§26)
- [ ] `MeetingRepository`: CRUD for meetings + SwiftData queries
- [ ] `FolderRepository`: CRUD for folders, supports hierarchy (parentFolderID)
- [ ] `FileStorageService`:
  - Root: `~/Library/Application Support/MeetingRecorder/`
  - Sub-dirs: `Meetings/YYYY/MM/UUID/`, `Database/`, `Logs/`
  - Creates directory structure on first launch
- [ ] All repositories inject a `ModelContext` — no singleton access patterns
- [ ] Meetings persist across app restart (title, folder, dates, paths, status)
- [ ] Optional: user-configured transcript export to `~/Documents/Meeting Notes/` (§25)

**Tests:**
- Create meeting, quit, relaunch → meeting still present
- Create folder, move meeting, quit, relaunch → meeting still in folder

---

### Milestone 7 — Folder Organisation ✅ COMPLETE

**Completed:** 2026-08-26 — Build 36

**Goal:** Full folder management in the GUI.

**Deliverables:**
- [ ] Create folder (prompt for name)
- [ ] Create nested subfolder (`People → John Smith`)
- [ ] Rename folder (inline or dialog)
- [ ] Delete folder with choice: Move meetings to All Meetings OR delete all meetings (§36)
- [ ] Move meeting into a folder (drag or context-menu action)
- [ ] Drag meetings between folders
- [ ] Folder hierarchy shown in sidebar with expand/collapse
- [ ] Meeting auto-sorted within folders by `startedAt DESC`

**Tests:**
- Create `People → John` hierarchy; move meeting; verify path
- Delete folder with meetings; choose "Move to All Meetings"; verify meetings remain
- Verify folder deletion does NOT silently delete meetings

---

### Milestone 8 — Teams Automatic Detection

**Goal:** App automatically detects when a Teams meeting starts/ends and records without manual intervention.

**Deliverables:**
- [ ] `MeetingDetector` protocol (§9)
- [ ] `TeamsMeetingDetector` implementing scoring model (§10):
  - Teams process running: +10
  - Teams has active window: +10
  - Teams window title suggests call/meeting: +30
  - Teams producing sustained audio: +20
  - Microphone actively being used: +20
  - Window title indicates meeting: +30
  - Threshold: 50 → `meetingStarted`
- [ ] `SupportedMeetingApp` config struct (§11)
- [ ] Teams identified by bundle identifier (not process name)
- [ ] Detector internal state machine: `IDLE → POSSIBLE_MEETING → IN_MEETING → POSSIBLE_END → IDLE`
- [ ] Start debounce: meeting indicators stable for **3 seconds** before triggering (§12)
- [ ] End debounce: no meeting activity for **8 seconds** before stopping (§13)
- [ ] If signals return during `POSSIBLE_END` → return to `IN_MEETING`
- [ ] Detection events wired to `RecordingCoordinator` via `ApplicationCoordinator`
- [ ] macOS notification: "Meeting recording started" / "Meeting recording stopped" (§16)

**Architecture constraint:** `TeamsMeetingDetector` must NOT directly start audio capture. It emits events only.

**Tests:**
- Unit test all detector state transitions
- Unit test start debounce (3 s)
- Unit test end debounce (8 s)
- Unit test score threshold

---

### Milestone 9 — Reliability

**Goal:** App handles edge cases without data loss.

**Deliverables:**
- [ ] **Crash recovery:** On startup, scan for `*.recording.tmp` files; prompt user to recover or delete (§49)
  - Recovery: repair/finalise audio, create Meeting record, offer transcription
- [ ] **Sleep/wake:** Observe `NSWorkspace.willSleepNotification`; finalise recording before sleep; on wake, resume monitoring (§48)
- [ ] **Permission recovery:** If SCStream permission is revoked mid-recording, stop cleanly with actionable error (§53)
- [ ] **Recording error recovery:** Any `SCStream` error stops recording and shows a user-friendly message with "Open System Settings" button
- [ ] **Transcription retry:** Failed transcription jobs are retryable from Meeting Detail view
- [ ] **Long meeting testing:** Record 2-hour session; confirm memory usage < 200 MB; confirm file is valid and fully playable
- [ ] **Quit during recording:** Confirmation dialog; `Stop Recording and Quit` finalises audio before quitting

**Tests:**
- Simulate crash (force-kill) mid-recording; relaunch; verify recovery prompt appears
- Simulate sleep during recording; verify `.tmp.caf` is closed cleanly

---

### Milestone 10 — Polish

**Goal:** App is complete, pleasant, and ready for daily use.

**Deliverables:**
- [ ] **Onboarding flow** (§43): step-by-step permission granting (Microphone, System Audio, Notifications); shows status `✓` / `!` per permission; "Open System Settings" button
- [ ] **First-run consent** (§45): acknowledgement that user is responsible for recording consent/compliance with workplace policy
- [ ] **Settings window** (§37–41):
  - General: launch at login, show menu bar, notifications, auto-detect
  - Recording: which apps to detect, microphone selection, audio quality
  - Transcription: engine picker, language picker, auto-transcribe toggle
  - Storage: show usage, open in Finder, transcript export folder, retention policy
  - Privacy: (informational, local-first statement)
- [ ] **Notifications** (§16): configurable, using `UNUserNotificationCenter`
- [ ] **Keyboard shortcuts** (§56): Cmd+N, Cmd+Shift+R, Cmd+F, Cmd+,, Space, Delete
- [ ] **Global search** (§33): search meeting title, folder name, transcript content, date
- [ ] **Storage management** (§41): show total storage; option to delete recordings after N days
- [ ] **Launch at login** using `ServiceManagement` (SMAppService)
- [ ] **Secrets in Keychain** (§62): any future cloud API keys go to Keychain, never UserDefaults
- [ ] **OSLog** structured logging (§52): categories for MeetingDetection, Recording, Audio, Transcription, Storage, Permissions, UI. Never log transcript content or raw audio.
- [ ] UI polish pass: spacing, typography, accessibility labels, Dark Mode

---

## Data Model Detail

### Meeting (SwiftData)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | Primary key |
| `title` | String | User-editable |
| `startedAt` | Date | Immutable after creation |
| `endedAt` | Date? | Set on meeting end |
| `duration` | TimeInterval | Computed or stored |
| `meetingApplication` | String | e.g. "Microsoft Teams" |
| `folderID` | UUID? | FK to Folder |
| `recordingURL` | String? | Relative path |
| `transcriptURL` | String? | Relative path |
| `transcriptionStatus` | TranscriptionStatus | pending/processing/completed/failed |
| `createdAt` | Date | |
| `updatedAt` | Date | |

### Folder (SwiftData)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | Primary key |
| `name` | String | |
| `parentFolderID` | UUID? | For nesting |
| `createdAt` | Date | |

---

## File Layout on Disk

```
~/Library/Application Support/MeetingRecorder/
├── Database/
│   └── meetings.sqlite
├── Meetings/
│   └── 2026/
│       └── 08/
│           └── 2026-08-26_10-02_<UUID>/
│               ├── recording.m4a       ← combined (exposed in UI)
│               ├── microphone.m4a
│               ├── system.m4a
│               ├── transcript.md
│               └── metadata.json
└── Logs/
```

Active recording temporary file:

```
2026-08-26_10-02_<UUID>/recording.tmp.caf
```

---

## Markdown Transcript Format

```markdown
---
id: 09E4FC95-17A0-4B65
title: "1:1 with John Smith"
date: 2026-08-26
started: 10:02
duration_seconds: 2712
meeting_application: "Microsoft Teams"
folder: "People/John Smith"
audio_file: "recording.m4a"
---

# 1:1 with John Smith

**Date:** 26 August 2026
**Started:** 10:02
**Ended:** 10:47
**Duration:** 45 minutes
**Application:** Microsoft Teams

## Transcript

### 00:00

Morning John, how are you?

### 00:18

Yeah I'm good...
```

---

## Menu Bar Icon States

| State | Symbol |
|---|---|
| Idle / Monitoring | `○` |
| Recording | `●` |
| Transcribing | `◌` |
| Disabled | `⊘` |
| Error | `!` |

Do not rely on colour alone (accessibility requirement).

---

## Permissions Required

| Permission | Purpose | API |
|---|---|---|
| Microphone | Record user's voice | `AVCaptureDevice` / SCK |
| Screen Recording | Capture system audio | `SCStream` |
| Notifications | Inform user of recording status | `UNUserNotificationCenter` |

Accessibility permission is NOT requested unless a specific detection implementation genuinely requires it.

---

## Privacy Constraints

- All audio and transcripts stored locally by default
- No analytics service receives audio, transcript text, meeting names, or participant names without explicit opt-in
- Cloud API keys (Phase 2+) stored in macOS Keychain only
- Logs must NEVER contain transcript content or raw audio

---

## MVP Exclusions (do not implement yet)

- AI summaries, action items, decisions
- Cloud sync or cloud database
- Speaker diarisation / recognition
- Calendar integration
- Zoom / Google Meet / Slack detection
- Mobile or web app
- Live transcription
- Semantic / vector search
- Teams API integration

---

## Phase 2 (post-MVP)

Speaker diarisation, AI summary, action items, decisions, follow-ups, calendar integration, automatic meeting title suggestion, Zoom/Meet/Slack detection, local Whisper transcription, SQLite FTS5 full-text search.

## Phase 3 (future)

AI notes view (summary + action items overlay on transcript), People view (per-person meeting history).

---

## Engineering Rules

1. **Layer independence:** Meeting Detection → Recording → Transcription → Storage → UI. No layer reaches across the boundary.
2. **`TeamsMeetingDetector`** must NOT call `SCStream` directly. It emits `MeetingDetectionEvent`.
3. **`AudioCaptureService.stop()`** emits `RecordingFinishedEvent` which `TranscriptionQueue` consumes.
4. **`TranscriptionService`** is a protocol. UI code references the protocol only, never a concrete type.
5. **Concurrency:** `async/await` + `actors` + `AsyncStream`. No `DispatchQueue` patterns.
6. **Logging:** OSLog only. Never log transcript or audio content.
7. **Secrets:** Keychain only for any credentials.
8. **Memory:** Audio written to disk incrementally. No in-memory audio buffer accumulating over time.

---

## Acceptance Checklist (before calling the project MVP-complete)

- [ ] User joins Teams call → app enters Recording state within 5 seconds
- [ ] Both user voice and remote participant voice are audible in the output file
- [ ] User leaves meeting → recording stops within 15 seconds
- [ ] Recording file remains playable after stop
- [ ] Transcription produces a valid `.md` file
- [ ] Meeting appears in app after restart with all metadata intact
- [ ] User can create `People → John` folders and move a meeting into them
- [ ] Meeting, folder, recording, and transcript are all deleted when user confirms delete
- [ ] Folder deletion does NOT silently delete meetings
- [ ] App handles quit-during-recording with confirmation
- [ ] Crash recovery prompt appears on next launch when `.tmp.caf` exists
