# Transcript Shark

A native macOS application that automatically detects online meetings, records both sides of the conversation, and transcribes the audio into Markdown — so your meeting notes write themselves.

> **Status:** Pre-development. See [PLAN.md](PLAN.md) for the implementation roadmap and [TECH-SPEC.md](TECH-SPEC.md) for the full product specification.

---

## What it does

1. Runs silently in the macOS menu bar
2. Detects when a Microsoft Teams meeting starts
3. Records your microphone **and** the system/meeting audio simultaneously
4. When the meeting ends, transcribes the recording using Apple's on-device Speech framework
5. Saves the transcript as a Markdown file
6. Organises everything in a native three-column GUI — browse by folder, date, or search across all transcripts

All data stays on your Mac. No cloud. No subscriptions. No audio uploads.

---

## Platform requirements

| Requirement | Value |
|---|---|
| macOS | 15.0 or later |
| Xcode | 16.0 or later |
| Swift | 6 |
| Architecture | Apple Silicon or Intel |

---

## Permissions

The app requires three macOS permissions, granted during first-run onboarding:

| Permission | Why |
|---|---|
| **Microphone** | Records your voice during meetings |
| **Screen Recording** | Captures system audio from meeting participants (audio only — no screen content is captured or stored) |
| **Notifications** | Tells you when recording starts, stops, and when a transcript is ready |

No Accessibility permission is requested.

---

## Building from source

### 1. Clone the repository

```bash
git clone https://github.com/your-org/transcript-shark.git
cd transcript-shark
```

### 2. Open in Xcode

```bash
open MeetingRecorder.xcodeproj
```

Or open Xcode and choose **File → Open** and select `MeetingRecorder.xcodeproj`.

### 3. Select your team

1. Select the `MeetingRecorder` target in the project navigator
2. Open the **Signing & Capabilities** tab
3. Set your Apple Developer Team (a free personal team works for local development)

### 4. Build and run

Press **⌘R** or choose **Product → Run**.

> **Note:** System audio capture via `SCStream` requires the app to be code-signed. Running unsigned from Xcode in a development build is fine. Distribution builds must be notarised.

---

## Development setup

No third-party dependencies are required. The project uses only Apple frameworks:

| Framework | Purpose |
|---|---|
| `SwiftUI` | UI |
| `SwiftData` | Persistence |
| `ScreenCaptureKit` | System audio capture |
| `AVFoundation` | Microphone capture, audio conversion |
| `Speech` | On-device transcription |
| `UserNotifications` | System notifications |
| `OSLog` | Structured logging |
| `ServiceManagement` | Launch at login |

### Run tests

```bash
xcodebuild test 
  -scheme MeetingRecorder 
  -destination 'platform=macOS' 
  -quiet
```

Or press **⌘U** in Xcode.

---

## How to use

### Menu bar

The app lives in the macOS menu bar. The icon shows the current state at a glance:

| Icon | State |
|---|---|
| `○` | Idle — waiting for a meeting |
| `●` | Recording |
| `◌` | Transcribing |
| `⊘` | Auto-recording disabled |
| `!` | Error |

Click the icon to see the menu:

**While idle:**
```
○ Meeting Recorder

Auto Recording: ON
Start Recording Manually
───────────────────────
Open App
Settings
Quit
```

**While recording:**
```
● Recording — Teams
00:23:41

Stop Recording
Open Meeting
Disable Auto Recording
───────────────────────
Open App
Settings
Quit
```

### Automatic recording (Teams)

When Teams meeting detection is enabled (the default), the app:

1. Monitors running applications for Microsoft Teams
2. Uses a scoring model to determine whether a real meeting is in progress
3. Waits for a stable signal (3 seconds) before starting to record
4. Records until the meeting ends and there is no activity for 8 seconds
5. Sends a notification and begins transcription automatically

### Manual recording

Click the menu bar icon → **Start Recording Manually** to record anything, independent of meeting detection.

### Main window

Open the app from the menu bar or Dock. The main window shows three columns:

```
┌────────────┬──────────────────┬───────────────────────────────┐
│ FOLDERS    │ MEETINGS         │ MEETING                       │
│            │                  │                               │
│ All        │ Aug 26           │ 1:1 John Smith                │
│ Today      │ 10:02 John       │ 26 Aug 2026 · 45 min          │
│            │                  │                               │
│ People     │ Aug 15           │ ▶ ━━━━━━━ 12:14 / 45:12       │
│  John      │ 09:30 Sarah      │                               │
│  Sarah     │                  │ Transcript                    │
│            │                  │                               │
│ Projects   │                  │ Morning John...               │
│            │                  │                               │
│ + Folder   │                  │                               │
└────────────┴──────────────────┴───────────────────────────────┘
```

### Organising meetings

- Click **+ Folder** in the sidebar to create a folder
- Right-click a folder to rename, create a subfolder, or delete it
- Drag a meeting from the list into a folder, or use **Move to Folder** in the meeting detail
- Folder structure is stored in metadata — the raw audio files are never moved

### Transcripts

Each meeting produces a Markdown file saved to:

```
~/Library/Application Support/MeetingRecorder/Meetings/YYYY/MM/<UUID>/transcript.md
```

Example transcript:

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

Yeah I'm good. I wanted to talk about the platform project...
```

You can also configure an optional export folder (e.g. `~/Documents/Meeting Notes/`) in **Settings → Storage** to automatically copy transcripts into a folder structure you choose.

### Search

Press **⌘F** to search across meeting titles, folder names, transcript content, and dates.

---

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘N` | Start manual recording |
| `⌘⇧R` | Start / Stop recording |
| `⌘F` | Search |
| `⌘,` | Open Settings |
| `Space` | Play / Pause selected recording |
| `Delete` | Delete selected meeting |

---

## Storage

All data is stored locally:

```
~/Library/Application Support/MeetingRecorder/
├── Database/
│   └── meetings.sqlite
├── Meetings/
│   └── YYYY/
│       └── MM/
│           └── <date>_<time>_<UUID>/
│               ├── recording.m4a       ← combined audio (UI)
│               ├── microphone.m4a      ← your voice only
│               ├── system.m4a          ← meeting audio only
│               ├── transcript.md
│               └── metadata.json
└── Logs/
```

To see how much space is used or to open the folder in Finder, go to **Settings → Storage**.

---

## Privacy

- Audio and transcripts are stored **locally only**
- Nothing is uploaded to any server
- No analytics or telemetry receives audio, transcript text, meeting names, or participant names
- Future cloud transcription providers (e.g. OpenAI Whisper API) will be opt-in and will store any API keys in the **macOS Keychain**, never in plain text

---

## Legal notice

You are responsible for complying with any applicable recording consent laws, workplace policies, and confidentiality requirements before recording a meeting. The app displays a first-run acknowledgement to this effect.

---

## Roadmap

See [PLAN.md](PLAN.md) for the detailed milestone-by-milestone implementation plan.

**Phase 1 — MVP** (current focus)  
Core recording, transcription, meeting history, folder organisation, Teams auto-detection, crash safety.

**Phase 2**  
Speaker diarisation, AI summary, action items, Zoom/Meet/Slack detection, local Whisper transcription, full-text search.

**Phase 3**  
AI notes view, People view (per-person meeting history).

---

## Contributing

The project is not yet open for external contributions while the core architecture is being established. Once Milestone 1 is complete and verified, a contribution guide will be added.

---

## License

See [LICENSE](LICENSE).
