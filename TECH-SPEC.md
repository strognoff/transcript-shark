# Mac Meeting Recorder & Transcription App

## 1. Product Overview

Build a native macOS application that automatically detects online meetings, records both:

* the user's microphone;
* audio being received from the meeting application;

and, after the meeting finishes, transcribes the recording into Markdown.

The primary initial use case is Microsoft Teams meetings, especially recurring 1:1 meetings.

The app must provide a native GUI where recordings and transcripts can be organised into folders, viewed, renamed, moved and deleted.

The application should also run from the macOS menu bar and clearly show whether meeting recording is:

* enabled;
* waiting for a meeting;
* actively recording;
* transcribing;
* disabled.

The product should be designed so support for Zoom, Google Meet, Slack Huddles and other meeting applications can be added later.

---

# 2. Product Goals

The application should make meeting note-taking essentially automatic.

Expected workflow:

1. User launches the Mac.
2. Application runs quietly in the background.
3. User joins a Teams meeting.
4. Application detects the meeting.
5. Recording starts automatically.
6. Both microphone and meeting/system audio are recorded.
7. User leaves the meeting.
8. Application detects that the meeting ended.
9. Recording stops.
10. Audio file is finalised.
11. Transcription starts.
12. Transcript is written to a Markdown file.
13. Recording appears inside the application's meeting history.
14. User can assign the meeting to a folder such as:

```text
People/
  Sarah/
  John/
  Manager/

Teams/
  Platform/
  Engineering/

Projects/
  Project Alpha/
```

The user can then open:

```text
People → Sarah → 2026-08-26 - 1x1
```

and see the complete transcript and associated recording.

---

# 3. Platform

Target:

```text
macOS 15+
```

Preferred implementation:

```text
Language: Swift
UI: SwiftUI
Native APIs: AppKit where necessary
Architecture: MVVM + Services
Persistence: SwiftData
Audio: ScreenCaptureKit / AVFoundation
Transcription: pluggable transcription service
```

Avoid Electron unless there is a compelling technical reason.

The application should feel like a native Mac utility.

---

# 4. Main Application Architecture

Use the following high-level modules:

```text
MacMeetingRecorder
│
├── App
│   ├── ApplicationCoordinator
│   ├── MenuBarController
│   └── PermissionManager
│
├── MeetingDetection
│   ├── MeetingDetector
│   ├── TeamsDetector
│   ├── ProcessMonitor
│   └── AudioActivityMonitor
│
├── Recording
│   ├── RecordingCoordinator
│   ├── SystemAudioCapture
│   ├── MicrophoneCapture
│   ├── AudioMixer
│   └── RecordingWriter
│
├── Transcription
│   ├── TranscriptionService
│   ├── AppleSpeechTranscriber
│   ├── WhisperTranscriber
│   └── MarkdownGenerator
│
├── Storage
│   ├── RecordingRepository
│   ├── FolderRepository
│   ├── FileStorage
│   └── Database
│
├── Models
│   ├── Meeting
│   ├── Recording
│   ├── Transcript
│   └── Folder
│
└── UI
    ├── Sidebar
    ├── MeetingList
    ├── MeetingDetail
    ├── TranscriptViewer
    ├── RecordingPlayer
    └── Settings
```

---

# 5. Core State Machine

The recording engine should operate as a state machine.

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
DISABLED
   ↓
MONITORING
   ↓
MEETING DETECTED
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

The state must be observable by both the main GUI and menu bar.

---

# 6. Audio Capture

## Requirement

During a meeting, capture:

```text
Track A = microphone
Track B = system/meeting audio
```

Preferably preserve the two sources independently while recording.

Optionally create:

```text
Track C = mixed recording
```

for easy playback and transcription.

### Preferred API

Use Apple's ScreenCaptureKit for system audio capture.

Use either ScreenCaptureKit microphone capture or AVFoundation for microphone capture.

Where supported, prefer a single ScreenCaptureKit stream so the audio sources remain synchronised.

Recommended recording format:

```text
.m4a
AAC
48 kHz
```

Optionally keep the raw recording in:

```text
.caf
```

during recording and convert/finalise to `.m4a` afterward.

Do not record video.

The objective is audio only.

---

# 7. Audio Channels

Whenever technically practical, store audio as separate streams:

```text
meeting-system.m4a
microphone.m4a
combined.m4a
```

This is useful because later versions of the application may perform:

* speaker identification;
* separation of "me" versus "other participants";
* better transcription;
* conversation analytics.

For the MVP, only `combined.m4a` needs to be exposed in the UI.

---

# 8. Recording Failure Protection

The recorder must avoid keeping the entire recording in memory.

Audio should continually be written to disk.

For example:

```text
recording.tmp.caf
```

During meeting:

```text
append audio → disk
append audio → disk
append audio → disk
```

When meeting ends:

```text
close file
→ validate recording
→ convert/finalise
→ rename
```

This ensures a crash during a 2-hour meeting does not destroy the entire meeting recording.

On application startup, search for unfinished `.tmp` recordings and offer recovery.

---

# 9. Automatic Meeting Detection

Meeting detection must be abstracted behind:

```swift
protocol MeetingDetector {
    func startMonitoring()
    func stopMonitoring()
    
    var meetingState: AsyncStream<MeetingDetectionEvent> { get }
}
```

Initial implementation:

```text
TeamsDetector
```

Future implementations:

```text
ZoomDetector
GoogleMeetDetector
SlackHuddleDetector
WebexDetector
```

---

# 10. Teams Meeting Detection Strategy

Do not depend on a single signal.

Use several signals together.

Example scoring model:

```text
Teams process running                   +10
Teams has active window                 +10
Teams window suggests call/meeting      +30
Teams producing sustained audio         +20
Microphone actively being used          +20
Window title indicates meeting          +30
```

If score exceeds threshold:

```text
MEETING_STARTED
```

Example:

```text
threshold = 50
```

Meeting detection should therefore be heuristic rather than tightly coupled to undocumented Teams internals.

---

# 11. Teams Process Detection

Monitor running applications using:

```swift
NSWorkspace.shared.runningApplications
```

Recognise Teams using its bundle identifier rather than just its process name.

Store supported meeting applications in configuration:

```swift
struct SupportedMeetingApp {
    let name: String
    let bundleIdentifiers: [String]
}
```

This avoids hard-coding logic throughout the application.

---

# 12. Meeting Start Debounce

Do NOT start recording immediately when a weak signal appears.

Example logic:

```text
Meeting detected continuously for 3 seconds
        ↓
start recording
```

This prevents accidental recordings when Teams briefly opens a meeting-related window.

---

# 13. Meeting End Detection

Similarly, avoid stopping recording immediately.

Possible meeting-ended signals:

```text
Teams meeting window disappears

AND/OR

Teams audio stops

AND

microphone activity stops
```

Use a grace period:

```text
No meeting activity for 8 seconds
        ↓
Meeting considered ended
```

This prevents temporary Teams audio interruptions from splitting recordings.

---

# 14. Manual Controls

Automatic detection must always be overridable.

Menu bar:

```text
● Recording — Teams
  00:23:41

Stop Recording
Open Meeting
Disable Auto Recording
-----------------------
Open App
Settings
Quit
```

When idle:

```text
○ Meeting Recorder

Auto Recording: ON
Start Recording Manually
-----------------------
Open App
Settings
Quit
```

When disabled:

```text
○ Meeting Recorder

Auto Recording: OFF
Enable Auto Recording
-----------------------
Open App
Settings
Quit
```

---

# 15. Menu Bar Icon States

Use visually obvious status states.

Examples:

```text
Idle
○

Recording
●

Transcribing
◌

Disabled
⊘

Error
!
```

Do not rely exclusively on colour because of accessibility.

While recording, the user should always be able to tell that recording is active.

---

# 16. Recording Indicator

When automatic recording begins, display a native macOS notification:

```text
Meeting recording started

Microsoft Teams audio is being recorded.
```

When stopped:

```text
Meeting recording stopped

Transcription has started.
```

After transcription:

```text
Transcript ready

42-minute meeting successfully transcribed.
```

Notifications should be configurable.

---

# 17. Transcription Pipeline

Transcription starts AFTER recording has been finalised.

Pipeline:

```text
Meeting End
    ↓
Finalise audio
    ↓
Validate file
    ↓
Create transcription job
    ↓
Transcribe
    ↓
Generate Markdown
    ↓
Update database
    ↓
Mark meeting complete
```

Do not transcribe continuously during the call for MVP.

---

# 18. Transcription Interface

Transcription engines must be interchangeable.

```swift
protocol TranscriptionService {
    func transcribe(
        audioURL: URL,
        language: Locale?
    ) async throws -> TranscriptResult
}
```

Example:

```swift
struct TranscriptResult {
    let text: String
    let segments: [TranscriptSegment]
    let detectedLanguage: String?
    let duration: TimeInterval
}
```

And:

```swift
struct TranscriptSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}
```

---

# 19. Initial Transcription Provider

Preferred initial implementation:

```text
Apple Speech / SpeechAnalyzer
```

Advantages:

* native;
* no third-party API required;
* potentially on-device;
* simpler privacy model;
* no per-minute API charge.

However, transcription architecture must remain provider-independent.

Settings should eventually support:

```text
Transcription Engine

○ Apple Speech
○ Local Whisper
○ OpenAI
○ Custom API
```

The MVP only needs one working provider.

---

# 20. Optional Local Whisper Provider

Design for this now even if it isn't implemented immediately.

Potential future implementation:

```text
whisper.cpp
```

or another native/local Whisper implementation.

Advantages:

* completely offline;
* no audio upload;
* more predictable;
* multilingual;
* useful for English + Portuguese meetings.

The transcription provider should therefore never be referenced directly from UI code.

Always use:

```text
TranscriptionService
```

---

# 21. Transcription Language

Settings:

```text
Transcription Language

Auto Detect
English (UK)
English (US)
Portuguese (Brazil)
Portuguese (Portugal)
...
```

Default:

```text
Auto Detect
```

---

# 22. Markdown Format

Every transcript must exist as an actual `.md` file on disk.

Example filename:

```text
2026-08-26_John-Smith_1x1.md
```

Example file:

```markdown
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

Yeah I'm good. I wanted to talk about the platform project...

### 01:02

The major issue we have at the moment is...
```

If speaker identification is available later:

```markdown
### 01:02 — Me

I wanted to understand the issue with deployment.

### 01:08 — John

The main problem is...
```

Do not invent speaker names unless there is reliable speaker identification.

---

# 23. Markdown File Header

Use YAML front matter as well.

Example:

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
```

This makes the notes portable and machine-readable.

---

# 24. File Storage

Default application data directory:

```text
~/Library/Application Support/MeetingRecorder/
```

Structure:

```text
MeetingRecorder/
│
├── Database/
│   └── meetings.sqlite
│
├── Meetings/
│   ├── 2026/
│   │   ├── 08/
│   │   │   ├── 2026-08-26_10-02_UUID/
│   │   │   │   ├── recording.m4a
│   │   │   │   ├── microphone.m4a
│   │   │   │   ├── system.m4a
│   │   │   │   ├── transcript.md
│   │   │   │   └── metadata.json
│
└── Logs/
```

Folder organisation inside the GUI should be represented in metadata/database rather than physically moving raw meeting directories where possible.

This prevents links becoming broken.

---

# 25. User Export Directory

Allow users to optionally choose:

```text
Documents/Meeting Notes
```

as a transcript export location.

Example:

```text
Meeting Notes/
│
├── People/
│   ├── John/
│   │   ├── 2026-08-01.md
│   │   ├── 2026-08-15.md
│   │   └── 2026-08-26.md
│
├── Projects/
│
└── Teams/
```

The app database remains the authoritative metadata store.

---

# 26. Database Models

## Meeting

```swift
Meeting {
    id: UUID
    title: String
    startedAt: Date
    endedAt: Date?
    duration: TimeInterval
    meetingApplication: String
    folderID: UUID?
    recordingURL: String?
    transcriptURL: String?
    transcriptionStatus: String
    createdAt: Date
    updatedAt: Date
}
```

## Folder

```swift
Folder {
    id: UUID
    name: String
    parentFolderID: UUID?
    createdAt: Date
}
```

Folders must support hierarchy.

Example:

```text
People
└── Engineering
    └── John Smith
```

---

# 27. Main Window

Use a three-column Mac-style layout.

```text
┌──────────────────────────────────────────────────────────────┐
│ Meeting Recorder                                      ⚙      │
├────────────┬──────────────────┬───────────────────────────────┤
│ FOLDERS    │ MEETINGS         │ MEETING                       │
│            │                  │                               │
│ All        │ Aug 26           │ 1:1 John Smith                │
│ Today      │ 10:02 John       │ 26 Aug 2026 · 45 min          │
│            │                  │                               │
│ People     │ Aug 15           │ ▶ ━━━━━━━ 12:14 / 45:12       │
│  John      │ 09:30 Sarah      │                               │
│  Sarah     │                  │ Transcript                    │
│            │ Aug 11           │                               │
│ Projects   │ Platform Review  │ Morning John...               │
│            │                  │                               │
│ + Folder   │                  │                               │
└────────────┴──────────────────┴───────────────────────────────┘
```

Use:

```text
NavigationSplitView
```

where appropriate.

---

# 28. Sidebar

Sidebar sections:

```text
Library
    All Meetings
    Today
    This Week

Folders
    People
    Teams
    Projects

+ New Folder
```

Folders should support:

* create;
* rename;
* delete;
* nested folders;
* drag meeting into folder;
* drag folders to reorder where practical.

---

# 29. Meeting List

Meetings sorted:

```text
Newest first
```

Group visually by date.

Example:

```text
TODAY

10:02
1:1 John Smith
45 min
✓ Transcript ready


YESTERDAY

14:15
Platform Review
32 min
✓ Transcript ready
```

Meeting status indicators:

```text
● Recording

◌ Transcribing

✓ Ready

! Failed
```

---

# 30. Meeting Detail View

Show:

```text
Meeting title

Date
Start time
Duration
Meeting application
Folder

Audio player

Transcript

Actions
```

Actions:

```text
Rename
Move to Folder
Reveal Markdown in Finder
Reveal Recording in Finder
Retry Transcription
Delete Meeting
```

---

# 31. Transcript Viewer

Render Markdown natively.

Provide two modes:

```text
Rendered
Raw Markdown
```

Rendered mode should be the default.

Allow:

```text
Cmd + F
```

search inside transcript.

Optional future feature:

```text
Edit transcript
```

For MVP, editing can simply use a TextEditor and update the Markdown file.

---

# 32. Audio Player

Meeting detail should include simple playback:

```text
▶  ━━━━━━━━━━━  12:04 / 45:13

1x
```

Controls:

```text
Play
Pause
Seek
Playback speed
```

Playback speeds:

```text
0.75x
1x
1.25x
1.5x
2x
```

---

# 33. Searching

Global search should search:

```text
meeting title
folder name
transcript content
date
```

Example:

```text
Search: "salary review"
```

should identify all transcripts containing the phrase.

MVP implementation can use SQLite/SwiftData queries plus Markdown text indexing.

Future improvement:

```text
SQLite FTS5
```

for full-text transcript search.

---

# 34. Date Organisation

Meetings should always maintain their original recording date.

UI filters:

```text
Today
Yesterday
This Week
This Month
Custom date
```

Default sort:

```text
startedAt DESC
```

---

# 35. Deleting Meetings

Delete dialog:

```text
Delete "1:1 John Smith"?

This will permanently delete:

• the audio recording
• the transcription
• meeting metadata

This action cannot be undone.

[Cancel] [Delete]
```

Deleting a meeting must remove:

```text
recording files
transcript.md
metadata files
database record
```

Prefer moving files into macOS Trash rather than immediately unlinking them where practical.

---

# 36. Folder Deletion

If a folder contains meetings:

```text
Delete Folder "John Smith"?

The folder contains 14 meetings.

○ Move meetings to All Meetings
○ Delete folder and all meetings
```

Default:

```text
Move meetings to All Meetings
```

Never silently delete recordings because a folder was removed.

---

# 37. Settings

Settings tabs:

```text
General
Recording
Transcription
Storage
Privacy
```

---

# 38. General Settings

```text
☑ Launch Meeting Recorder at login

☑ Show menu bar icon

☑ Show recording notifications

☑ Automatically detect meetings
```

---

# 39. Recording Settings

```text
Automatic Recording

☑ Microsoft Teams

Future:
☐ Zoom
☐ Google Meet
☐ Slack
```

Audio:

```text
Microphone:
[MacBook Pro Microphone ▼]

System Audio:
Automatic

Audio Quality:
Standard
High
```

---

# 40. Transcription Settings

```text
Transcription Engine
[Apple Speech ▼]

Language
[Auto Detect ▼]

☑ Automatically transcribe after meeting
```

Future providers can display their own configuration.

---

# 41. Storage Settings

Show:

```text
Meeting Storage

~/Library/Application Support/MeetingRecorder/

Current storage usage:
4.8 GB

[Open in Finder]

Transcript Export Folder:
~/Documents/Meeting Notes

[Change]
```

Options:

```text
☑ Keep audio recordings after transcription

Delete recordings after:
Never
30 days
90 days
1 year
```

Default:

```text
Never
```

---

# 42. Permissions

The onboarding process must explicitly walk through required permissions.

At minimum:

```text
Microphone
System Audio / Screen Recording
Notifications
```

Potentially:

```text
Accessibility
```

only if a meeting-detection implementation genuinely requires it.

Do not request Accessibility permission unnecessarily.

---

# 43. Permission Screen

Example:

```text
Meeting Recorder needs three permissions.

Microphone
Required to record what you say.

System Audio
Required to record other meeting participants.

Notifications
Used to tell you when recording starts and stops.

Microphone          ✓
System Audio        !
Notifications       ✓

[Open System Settings]
```

---

# 44. Privacy Requirements

Meeting audio and transcripts may contain sensitive information.

Default architecture should therefore be:

```text
local-first
```

Recording files:

```text
stored locally
```

Transcript files:

```text
stored locally
```

No analytics platform should receive:

```text
audio
transcript text
meeting names
participant names
```

without explicit opt-in.

---

# 45. Recording Disclosure

The application should not attempt to conceal its recording state.

While recording:

```text
menu bar status = clearly recording
```

and optionally:

```text
native notification
```

The application should contain a first-run acknowledgement explaining that the user is responsible for complying with workplace policies, confidentiality requirements, and applicable recording/consent laws.

---

# 46. App Launch Behaviour

On launch:

```text
Load database
↓
Check unfinished recordings
↓
Check permissions
↓
Load settings
↓
Start MeetingDetector
↓
Enter monitoring state
```

The main window does not need to remain open.

Closing the window must NOT quit the app.

The menu bar application continues monitoring.

---

# 47. Quit Behaviour

If user quits while recording:

```text
Recording in progress

A meeting is currently being recorded.

[Cancel]
[Stop Recording and Quit]
```

Never terminate without finalising the recording.

---

# 48. Sleep Behaviour

Observe macOS sleep/wake notifications.

If Mac is going to sleep during recording:

```text
finalise current recording
mark interruption
```

On wake:

```text
resume meeting detection
```

Do not assume the meeting survived sleep.

---

# 49. Crash Recovery

On startup check:

```text
*.recording.tmp
```

If found:

```text
Recovered Recording

Meeting Recorder found an unfinished recording
from 10:02 today.

[Recover]
[Delete]
```

Recovery should:

```text
repair/finalise audio
create Meeting record
offer transcription
```

---

# 50. Transcription Queue

Transcription must not block the UI.

Create:

```swift
actor TranscriptionQueue
```

Jobs:

```text
queued
processing
completed
failed
```

Example:

```swift
enum TranscriptionStatus {
    case pending
    case processing
    case completed
    case failed
}
```

Failed jobs must be retryable.

---

# 51. Concurrency

Use Swift structured concurrency.

Prefer:

```text
async/await
actors
AsyncStream
```

Avoid having unrelated modules directly manipulate each other's state.

Example:

```text
MeetingDetector
        ↓ event

RecordingCoordinator
        ↓ event

TranscriptionQueue
        ↓ event

MeetingRepository
        ↓

UI
```

---

# 52. Logging

Implement structured application logging using:

```text
OSLog
Logger
```

Categories:

```text
MeetingDetection
Recording
Audio
Transcription
Storage
Permissions
UI
```

Never log transcript content.

Never log raw audio data.

---

# 53. Error Handling

Errors visible to users should be actionable.

Bad:

```text
SCStreamError -3802
```

Good:

```text
Unable to record meeting audio.

Meeting Recorder no longer has permission to
capture system audio.

[Open System Settings]
```

Underlying technical error should still go to logs.

---

# 54. Meeting Naming

Automatic meeting name initial value:

```text
Microsoft Teams Meeting
```

Where meeting title can reliably be obtained:

```text
Weekly Platform Meeting
```

Otherwise use:

```text
Meeting — 26 Aug 2026, 10:02
```

User can rename afterward.

---

# 55. 1:1 Workflow

Optimise strongly for recurring meetings with people.

Example:

First recording:

```text
Meeting — 26 Aug 2026
```

User renames:

```text
1:1 John Smith
```

and moves it into:

```text
People → John Smith
```

Later recordings can eventually use history to suggest:

```text
Move this meeting to People / John Smith?
```

This is a future enhancement and should not block MVP.

---

# 56. Keyboard Shortcuts

Suggested:

```text
Cmd + N
Manual recording

Cmd + Shift + R
Start/Stop recording

Cmd + F
Search

Cmd + ,
Settings

Space
Play/Pause selected recording

Delete
Delete selected meeting
```

Global recording shortcut can be added later.

---

# 57. MVP Scope

The first usable version MUST implement:

```text
✓ Native macOS application
✓ SwiftUI interface
✓ Menu bar component
✓ Microphone recording
✓ System audio recording
✓ Combined audio recording
✓ Manual start recording
✓ Manual stop recording
✓ Teams meeting automatic detection
✓ Automatic stop
✓ Post-meeting transcription
✓ Markdown transcript generation
✓ Meeting history
✓ Date sorting
✓ Folder creation
✓ Move meetings into folders
✓ Rename meetings
✓ Transcript viewer
✓ Audio playback
✓ Delete meetings
✓ Permission onboarding
✓ Recording status indicator
✓ Local storage
✓ Crash-safe recordings
```

---

# 58. MVP Exclusions

Do NOT spend initial development effort on:

```text
AI meeting summaries
action-item extraction
cloud sync
multi-user accounts
speaker recognition
calendar integration
Zoom
Google Meet
Teams API integration
mobile application
web application
live transcription
cloud database
semantic/vector search
```

Build the reliable recording/transcription foundation first.

---

# 59. Phase 2

After MVP stability:

```text
Speaker diarisation

"Me" vs "Other participant"

AI summary

Action items

Decisions

Follow-ups

Calendar integration

Automatic meeting title

Zoom detection

Google Meet detection

Slack Huddle detection

Whisper local transcription

Full-text indexing

Search across all meetings
```

---

# 60. Phase 3 — AI Notes

Future transcript:

```markdown
# 1:1 John Smith

## Summary

We discussed John's current project delivery,
team capacity and upcoming promotion review.

## Action Items

- [ ] Jeff: Review promotion evidence
- [ ] John: Send architecture proposal
- [ ] Jeff: Schedule follow-up

## Decisions

- Platform migration will begin next sprint.
- Deployment remains behind feature flag.

## Transcript

...
```

The raw transcript must always remain available.

AI-generated notes must never replace the original transcript.

---

# 61. Phase 3 — People View

Future UI:

```text
People
│
├── John Smith
│
│   26 Aug
│
│   12 Aug
│
│   29 Jul
│
└── Sarah Jones
```

Clicking John:

```text
John Smith

Meetings: 18
Last meeting: 26 Aug 2026

Meeting History

26 Aug 2026
12 Aug 2026
29 Jul 2026
...
```

This makes the application especially useful for manager 1:1 history.

---

# 62. Security

Application data should remain inside the user's account.

File permissions should not make recordings globally readable.

Secrets for cloud transcription providers, if implemented later, should be stored using:

```text
macOS Keychain
```

Never:

```text
UserDefaults
plaintext JSON
.plist
source code
```

for API tokens.

---

# 63. Sandbox Considerations

Evaluate App Sandbox requirements early.

Screen/system audio capture requires appropriate macOS permissions, and the application must contain the relevant privacy usage descriptions.

Required descriptions should include clear text for:

```text
NSMicrophoneUsageDescription

NSAudioCaptureUsageDescription

NSScreenCaptureUsageDescription
```

Use wording such as:

```text
Meeting Recorder uses your microphone to record
your voice during meetings.

Meeting Recorder captures system audio so other
meeting participants can be included in recordings.
```

---

# 64. Recommended Project Structure

```text
MeetingRecorder/
│
├── MeetingRecorderApp.swift
│
├── App/
│   ├── AppState.swift
│   ├── ApplicationCoordinator.swift
│   └── MenuBarManager.swift
│
├── Models/
│   ├── Meeting.swift
│   ├── MeetingFolder.swift
│   └── Transcript.swift
│
├── Services/
│   ├── Audio/
│   │   ├── AudioCaptureService.swift
│   │   ├── SystemAudioCapture.swift
│   │   ├── MicrophoneCapture.swift
│   │   └── RecordingWriter.swift
│   │
│   ├── Meetings/
│   │   ├── MeetingDetectionService.swift
│   │   └── TeamsMeetingDetector.swift
│   │
│   ├── Transcription/
│   │   ├── TranscriptionService.swift
│   │   └── AppleSpeechTranscriber.swift
│   │
│   ├── Storage/
│   │   ├── MeetingRepository.swift
│   │   └── FileStorageService.swift
│   │
│   └── Permissions/
│       └── PermissionService.swift
│
├── Views/
│   ├── MainWindow/
│   ├── Sidebar/
│   ├── MeetingList/
│   ├── MeetingDetail/
│   ├── Transcript/
│   ├── Settings/
│   └── Onboarding/
│
└── Utilities/
    ├── Logger.swift
    └── DateFormatter.swift
```

---

# 65. Important Engineering Principle

The following layers must remain independent:

```text
Meeting Detection
Recording
Transcription
Storage
UI
```

For example:

TeamsMeetingDetector must NOT directly start ScreenCaptureKit.

Instead:

```text
TeamsMeetingDetector
        ↓
MeetingDetectionEvent.started

RecordingCoordinator
        ↓
AudioCaptureService.start()
```

Likewise:

```text
AudioCaptureService.stop()
        ↓
RecordingFinishedEvent

TranscriptionQueue
        ↓
TranscriptionService
```

This is essential for supporting other meeting applications later.

---

# 66. Detection Events

Define:

```swift
enum MeetingDetectionEvent {
    case potentialMeetingDetected(MeetingContext)
    case meetingStarted(MeetingContext)
    case meetingEnded(MeetingContext)
}
```

Example context:

```swift
struct MeetingContext {
    let applicationName: String
    let bundleIdentifier: String
    let detectedTitle: String?
    let detectedAt: Date
}
```

---

# 67. Recording Model

```swift
struct RecordingSession {
    let id: UUID
    let meetingContext: MeetingContext
    let startedAt: Date

    var endedAt: Date?

    let systemAudioURL: URL
    let microphoneURL: URL
    let combinedAudioURL: URL
}
```

---

# 68. Recording Coordinator

The central coordinator owns recording lifecycle.

Pseudo-code:

```swift
actor RecordingCoordinator {

    private var currentSession: RecordingSession?

    func meetingStarted(_ context: MeetingContext) async throws {

        guard currentSession == nil else {
            return
        }

        let session = createSession(context)

        try await audioCapture.start(session)

        currentSession = session
    }

    func meetingEnded() async throws {

        guard let session = currentSession else {
            return
        }

        let result = try await audioCapture.stop()

        try repository.save(result)

        transcriptionQueue.enqueue(result)

        currentSession = nil
    }
}
```

---

# 69. Meeting Detector Safety

Automatic recording must never repeatedly create recordings because of unstable meeting detection.

Maintain detector state:

```text
IDLE
POSSIBLE_MEETING
IN_MEETING
POSSIBLE_END
```

Example:

```text
IDLE
 ↓ meeting indicators
POSSIBLE_MEETING
 ↓ indicators stable 3 sec
IN_MEETING
 ↓ indicators disappear
POSSIBLE_END
 ↓ absent 8 sec
IDLE
```

If signals return during `POSSIBLE_END`:

```text
return to IN_MEETING
```

---

# 70. Quality Requirements

The application should successfully handle:

```text
5-minute meeting
30-minute meeting
1-hour meeting
2-hour meeting
4-hour meeting
```

without memory growth proportional to recording duration.

Target memory while recording:

```text
< 200 MB
```

excluding system frameworks.

CPU use while recording should remain low because no live transcription is occurring.

---

# 71. Testing

Unit tests:

```text
MeetingDetector state transitions
Meeting end debounce
Meeting start debounce
Folder operations
Meeting deletion
Markdown generation
Transcription queue
Crash recovery detection
```

Integration tests:

```text
Record microphone
Record system audio
Record both simultaneously
Generate valid m4a
Transcribe saved file
Generate Markdown
Delete complete meeting
Recover interrupted recording
```

Manual tests:

```text
Teams call
Teams 1:1
Teams group call
Incoming Teams call rejected
Teams open but no meeting
Teams meeting muted
Meeting with headphones
Bluetooth headphones
AirPods
External microphone
Mac speaker
```

---

# 72. Acceptance Criteria — Recording

A test meeting is considered successful when:

```text
User joins Teams call

≤ 5 seconds later:
application enters Recording state

Both:
user voice
remote participant voice

are present in resulting recording.

User leaves meeting.

≤ 15 seconds later:
recording stops.

Recording remains playable.
```

---

# 73. Acceptance Criteria — Transcription

After recording stops:

```text
meeting status = Transcribing
```

Upon completion:

```text
meeting status = Ready
```

A valid `.md` file exists.

Opening the meeting in the app displays the Markdown transcript.

Restarting the app retains:

```text
meeting
folder
recording
transcript
date
title
```

---

# 74. Acceptance Criteria — Organisation

User must be able to:

```text
Create folder "People"

Create subfolder "John"

Move meeting into People/John

Quit app

Reopen app

Meeting remains under People/John
```

---

# 75. Acceptance Criteria — Delete

Deleting meeting:

```text
Meeting disappears from GUI.

Associated audio disappears.

Associated Markdown disappears.

Database record disappears.
```

Deleting a folder must not silently delete meetings.

---

# 76. Development Order

Implement in this sequence.

## Milestone 1 — Recording Prototype

Build a small native Mac prototype capable of:

```text
Start
Record system audio
Record microphone
Stop
Produce playable audio
```

Do NOT start building the full GUI before this works.

This is the primary technical risk.

---

## Milestone 2 — Recording Engine

Create:

```text
AudioCaptureService
RecordingCoordinator
RecordingSession
RecordingWriter
```

Validate recordings lasting at least one hour.

---

## Milestone 3 — Manual Recording Application

Create:

```text
Menu bar app
Start Recording
Stop Recording
Recording indicator
```

Still no Teams automatic detection required.

---

## Milestone 4 — Transcription

Implement:

```text
TranscriptionService
AppleSpeechTranscriber
TranscriptionQueue
MarkdownGenerator
```

Flow:

```text
Stop recording
→ transcribe
→ transcript.md
```

---

## Milestone 5 — Library GUI

Implement:

```text
Sidebar
Meeting list
Meeting detail
Transcript viewer
Audio player
```

---

## Milestone 6 — Persistence

Implement:

```text
SwiftData
MeetingRepository
FolderRepository
FileStorageService
```

---

## Milestone 7 — Folder Organisation

Implement:

```text
Create
Rename
Move
Delete
Nested folders
```

---

## Milestone 8 — Teams Detection

Implement:

```text
Teams process monitoring
Teams meeting signal collection
Detector state machine
Start debounce
End debounce
```

Connect detection events to:

```text
RecordingCoordinator
```

---

## Milestone 9 — Reliability

Implement:

```text
Crash recovery
Sleep/wake handling
Permission recovery
Recording error recovery
Transcription retries
Long meeting testing
```

---

## Milestone 10 — Polish

Implement:

```text
Onboarding
Notifications
Settings
Storage management
Keyboard shortcuts
UI polish
```

---

# 77. Agent Instruction

The development agent should treat this specification as the product source of truth.

Do not implement the entire application in one large change.

Work incrementally by milestone.

For every milestone:

1. Design the interfaces first.
2. Implement the smallest functional version.
3. Build the project.
4. Resolve all compiler warnings/errors.
5. Add relevant tests.
6. Run the application.
7. Validate the functionality manually where possible.
8. Commit only after the milestone works.

Do not create mock functionality for core requirements such as audio recording or transcription and subsequently describe the milestone as complete.

The priority order is:

```text
Reliability
Privacy
Recording quality
Data integrity
Usability
Additional features
```

The most important capability in the entire project is:

> Reliably capture both sides of a macOS Teams meeting without interfering with the meeting itself.

Prove that capability before investing significant development effort into the rest of the application.
