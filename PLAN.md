# Transcript Shark — Implementation Plan

Transcript Shark is a native macOS menu bar app for local audio recording, transcription, organisation, and AI summaries. The product started as a meeting recorder, but the user-facing direction is now broader: calls, streams, interviews, demos, podcasts, notes, and meetings.

---

## Product Identity

| Field | Value |
|---|---|
| User-facing app name | Transcript Shark |
| Internal target/project | MeetingRecorder |
| Bundle ID | `com.transcript-shark.MeetingRecorder` |
| Platform | macOS 15+ |
| Language | Swift 6 |
| UI | SwiftUI + AppKit where needed |
| Persistence | SwiftData |
| Audio | ScreenCaptureKit + AVFoundation |
| Transcription | Apple Speech |
| AI Summary | Local CLI provider: Tabnine or OpenCode |

> Internal model names such as `Meeting`, `MeetingRepository`, and `TeamsMeetingDetector` remain for compatibility. User-facing copy should say “recording(s)” unless specifically discussing Teams auto-detection internals.

---

## Current Priorities

1. Reliability
2. Local-first privacy
3. Recording quality
4. Data integrity
5. Usability
6. Optional AI/camera enhancements

---

## Current Architecture

```text
MeetingRecorder/
├── App/
│   ├── AppState.swift
│   ├── ApplicationCoordinator.swift
│   ├── CameraOverlayManager.swift
│   └── MenuBarManager.swift
├── Models/
│   ├── Folder.swift
│   ├── Meeting.swift
│   ├── MeetingRecord.swift
│   └── RecordingSession.swift
├── Services/
│   ├── Audio/
│   ├── Meetings/
│   ├── Storage/
│   └── Transcription/
└── Views/
    ├── MeetingList/
    ├── MeetingDetail/
    ├── Onboarding/
    ├── Settings/
    └── Sidebar/
```

---

## Shipped / Current Capabilities

### Recording

- Manual recording from the menu bar.
- Teams auto-detection convenience mode.
- System audio capture and microphone capture.
- Local recording storage under Application Support.
- Menu bar status for idle, recording, transcription, disabled, and error states.

### Transcription

- Apple Speech transcription.
- Speaker-labelled transcript generation when microphone/system sidecars are available.
- Markdown transcript output.

### Library UI

- Sidebar folders.
- “All Recordings” view.
- Recording list grouped by date.
- Recording detail with playback and transcript.
- Recording rename from row context menu or detail toolbar.
- Move recording to folder.
- Delete/retry/reveal actions.

### Camera Bubble

- Manual camera bubble toggle from menu bar and Settings → Recording.
- Bottom-right circular preview window.
- Camera selection picker, including USB cameras.
- Background blur is intentionally removed for stability.

### AI Summary

- AI Summary panel in the detail view.
- Summary output persisted next to the recording.
- User-editable summary instructions/prompt.
- Provider selection in Settings → AI Summary:
  - Tabnine CLI
  - OpenCode CLI
- Provider-specific executable path and status check.

### Settings

| Tab | Scope |
|---|---|
| General | Launch at login, auto-recording, startup screen, notifications |
| Recording | Microphone info, camera bubble, camera picker |
| Transcription | Auto-transcribe, language |
| Storage | Recording folder, Finder shortcut, retention placeholder |
| Privacy | Screen Recording, Microphone, Camera status |
| AI Summary | Provider, executable path, prompt |

---

## Validation Expectations

Before considering a change complete:

- Build the app target.
- Build the unit-test target.
- Exercise or smoke-test the changed behavior where possible.
- Do not leave temporary build folders in the repo.
- Do not stage or commit unless explicitly requested.

Known useful commands:

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

---

## Near-Term Roadmap

- Public release polish and signed/notarized DMG.
- Better full-text search across transcripts.
- More communication-app detection beyond Teams.
- Local Whisper transcription option.
- More robust AI extraction views.
- Optional future background blur only if implemented with a stable capture pipeline.

---

## Non-Goals / Constraints

- Do not upload recordings, transcripts, or summaries to Transcript Shark-owned servers.
- Do not log raw transcript or audio content.
- Do not reintroduce the unstable Vision/Portrait background blur pipeline.
- Avoid broad internal type/database renames unless a migration plan exists.
