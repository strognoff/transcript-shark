# Transcript Shark — Technical Specification

## 1. Product Overview

Transcript Shark is a native macOS app for recording audio, transcribing it, organising recordings, and generating AI summaries through a local CLI provider.

The app supports broad recording workflows:

- calls and meetings;
- livestreams;
- demos;
- interviews;
- podcasts;
- ad-hoc voice notes;
- any other Mac audio workflow where the user has consent to record.

The original internal implementation still contains names like `Meeting`, `MeetingRepository`, and `TeamsMeetingDetector`. These are compatibility details. User-facing language should use **Recording** and **Transcript Shark**.

---

## 2. Product Goals

Transcript Shark should make recording and note generation simple while staying local-first.

Expected workflow:

1. User launches Transcript Shark.
2. App runs from the menu bar.
3. User starts a recording manually or auto-detection starts a Teams recording.
4. App records microphone and system audio.
5. Recording is finalised locally.
6. Transcription is generated using Apple Speech.
7. Recording appears in the library.
8. User can rename, organise, play, search, and delete recordings.
9. User can generate an AI summary using Tabnine or OpenCode.
10. Summary is saved next to the recording.

---

## 3. Platform

| Area | Choice |
|---|---|
| OS | macOS 15+ |
| Language | Swift 6 |
| UI | SwiftUI + AppKit |
| Persistence | SwiftData |
| Audio | ScreenCaptureKit + AVFoundation |
| Transcription | Apple Speech |
| AI summaries | Local CLI via `Foundation.Process` |

Avoid Electron. The app should feel native to macOS.

---

## 4. Architecture

```text
MeetingRecorder/
├── App
│   ├── AppState
│   ├── ApplicationCoordinator
│   ├── CameraOverlayManager
│   └── MenuBarManager
├── Models
│   ├── Folder
│   ├── Meeting
│   ├── MeetingRecord
│   └── RecordingSession
├── Services
│   ├── Audio
│   ├── Meetings
│   ├── Storage
│   └── Transcription
└── Views
    ├── LibraryView
    ├── MeetingList
    ├── MeetingDetail
    ├── Onboarding
    ├── Settings
    └── Sidebar
```

### Layering rules

- UI observes repositories and `AppState`.
- `RecordingCoordinator` owns recording lifecycle.
- `TeamsMeetingDetector` emits detection events only.
- `ApplicationCoordinator` translates detection events into recording actions.
- Storage services own SwiftData/file-system persistence.
- AI summary service shells out to the selected local CLI provider.

---

## 5. State Machine

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

Normal lifecycle:

```text
MONITORING
  ↓
RECORDING
  ↓
FINALIZING
  ↓
TRANSCRIBING
  ↓
COMPLETED
  ↓
MONITORING
```

The state is shared between the menu bar and main app window through `AppState`.

---

## 6. Recording

### Capture goals

- Capture microphone audio.
- Capture system audio.
- Preserve sidecar files where available.
- Produce a combined playable recording.
- Avoid buffering entire recordings in memory.

### Storage layout

```text
~/Library/Application Support/MeetingRecorder/
├── Database/
│   └── meetings.sqlite
└── Recordings/
    └── <date>_<recording>/
        ├── recording.mp4
        ├── recording_mic.caf
        ├── recording_system.caf
        ├── recording_transcript.md
        └── recording_summary.md
```

The app-support folder intentionally remains `MeetingRecorder` to preserve compatibility with existing local data.

---

## 7. Menu Bar

Transcript Shark is primarily controlled from the macOS menu bar.

State icons:

| Icon | Meaning |
|---|---|
| `○` | Idle / monitoring |
| `●` | Recording |
| `◌` | Transcribing |
| `⊘` | Auto-recording disabled |
| `!` | Error |

Menu items include:

- Auto Recording ON/OFF;
- Start Recording Manually;
- Stop Recording;
- Open Recording;
- Camera Bubble ON/OFF;
- Open App;
- Settings;
- Quit.

---

## 8. Library UI

The main window uses a multi-column layout:

```text
Folders → Recordings → Recording Detail → AI Summary
```

### Sidebar

- All Recordings
- Today
- This Week
- Folder hierarchy
- New folder creation
- Folder rename/delete

### Recordings list

- Group by date.
- Sort newest first.
- Search by title.
- Context menu actions:
  - Rename
  - Delete
- Drag recordings into folders.

### Recording detail

- Title
- Date/time
- Duration
- Application/source
- Playback controls
- Transcript viewer
- Rename
- Move to folder
- Reveal in Finder
- Retry transcription
- Delete

---

## 9. Rename Recordings

Users can rename recordings from:

- row context menu in the recordings list;
- detail toolbar.

Implementation uses `MeetingRepository.updateTitle` and keeps selected UI state in sync after save. Blank names are rejected in the rename sheet.

---

## 10. Transcription

The transcription layer uses Apple Speech.

When sidecar files are available:

- microphone sidecar is labelled `Me`;
- system sidecar is labelled `Them`;
- segments are merged by timestamp.

When sidecars are unavailable, the combined recording is transcribed without speaker separation.

Transcript output is Markdown with front matter metadata.

---

## 11. AI Summary

The AI Summary panel generates and persists a Markdown summary for a recording.

### Providers

Supported local CLI providers:

| Provider | Default executable | Invocation style |
|---|---|---|
| Tabnine | `/Users/<you>/.local/bin/tabnine` | `tabnine --skip-trust --prompt <prompt> -o text`, transcript via stdin |
| OpenCode | `/usr/local/bin/opencode` | `opencode run --format default --title "Transcript Shark Summary" <prompt + transcript>` |

### Settings

Settings → AI Summary supports:

- provider selection;
- provider-specific executable path;
- executable status indicator;
- global custom summary instructions;
- reset to default prompt;
- per-recording prompt overrides from the AI Summary panel.

Default prompt:

```text
You are a recording assistant. Summarise the following transcript concisely.
Structure your response with three short sections:
**Key Topics**, **Decisions Made**, and **Action Items**.
Be brief and specific. Omit filler and small talk.
```

Users can replace this with instructions such as:

```text
Give me only the highlights.
```

---

## 12. Camera Bubble

The camera bubble is optional and manually controlled.

- Bottom-right circular preview.
- Always-on-top floating AppKit window.
- Camera permission via AVFoundation.
- Camera picker supports built-in and external/USB cameras.
- Selected camera persists.
- Visible state does not auto-start on app launch.
- Background blur is not available; the earlier Vision/Portrait implementation was removed for stability.

---

## 13. Settings

| Tab | Scope |
|---|---|
| General | Launch at login, auto-recording, startup screen, notifications |
| Recording | Capture area, selected window, microphone info, camera bubble, camera picker |
| Transcription | Auto-transcribe, language |
| Storage | Recording folder, Finder shortcut, retention placeholder |
| Privacy | Screen Recording, Microphone, Camera permission status |
| AI Summary | Provider, executable path, custom prompt |

---

## 14. Privacy and Security

- Store audio, transcripts, summaries, and metadata locally.
- Do not log raw audio or transcript content.
- Do not store secrets in source files.
- AI summary content is sent only to the selected local CLI provider; users are responsible for that provider’s configuration and network behaviour.
- Public distribution should use Developer ID signing and notarization.

---

## 15. Validation

For implementation changes:

```bash
cd MeetingRecorder

xcodebuild build \
  -project MeetingRecorder.xcodeproj \
  -scheme MeetingRecorder \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project MeetingRecorder.xcodeproj \
  -target MeetingRecorderTests \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

For OpenCode command-shape smoke testing:

```bash
opencode run --format default --title 'Transcript Shark Smoke Test' 'Reply with exactly: ok'
```

---

## 16. Future Work

- Signed/notarized DMG release pipeline.
- Additional auto-detection providers: Zoom, Google Meet, Slack Huddles.
- Local Whisper transcription provider.
- Full-text search across transcript content.
- More robust AI extraction workflows.
- Optional background blur only if implemented with a stable, tested pipeline.
