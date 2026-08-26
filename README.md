# Transcript Shark

A native macOS application that automatically detects online meetings, records both sides of the conversation, transcribes the audio into speaker-labelled Markdown, and generates an AI summary — so your meeting notes write themselves.

> **Version:** 1.0 (build 54) · macOS 15+ · Apple Silicon & Intel

---

## What it does

1. Runs silently in the macOS menu bar
2. Detects when a Microsoft Teams meeting starts
3. Records your microphone **and** the remote participants' audio simultaneously into separate tracks
4. When the meeting ends, transcribes each track independently — labelling every line **Me** or **Them**
5. Saves the speaker-attributed transcript as a Markdown file
6. Optionally generates an AI summary (key topics, decisions, action items) using the local Tabnine CLI
7. Organises everything in a native four-column GUI — browse by folder, date, or search across all transcripts

All data stays on your Mac. No cloud. No subscriptions. No audio uploads.

---

## Platform requirements

| Requirement | Value |
|---|---|
| macOS | 15.0 or later |
| Xcode | 16.0 or later (to build from source) |
| Swift | 6 |
| Architecture | Apple Silicon or Intel |
| Tabnine CLI | Required only for AI Summary feature |

---

## Permissions

Granted during first-run onboarding:

| Permission | Why |
|---|---|
| **Microphone** | Records your voice during meetings |
| **Screen Recording** | Captures system audio from meeting participants (audio only — no screen content is captured or stored) |
| **Notifications** | Tells you when recording starts, stops, and when a transcript is ready |

---

## How to use

### First launch

On first launch a welcome screen walks you through granting the required permissions and a recording consent acknowledgement. Check **"Don't show this at startup"** on the welcome screen to skip it on future launches. You can re-enable it anytime in **Settings → General → Show startup screen at launch**.

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

Open the app from the menu bar. The main window shows four columns:

```
┌──────────┬─────────────────┬──────────────────────────┬──────────────────┐
│ FOLDERS  │ MEETINGS        │ MEETING DETAIL           │ AI SUMMARY       │
│          │                 │                          │                  │
│ All      │ Aug 26          │ 1:1 John Smith           │ ✦ AI Summary     │
│ Today    │ 10:02 John ✓   │ 26 Aug 2026 · 45 min     │ ──────────────── │
│          │                 │                          │ **Key Topics**   │
│ People   │ Aug 15          │ ▶ ━━━━━━━ 12:14 / 45:12  │ Platform roadmap │
│  John    │ 09:30 Sarah ✓  │                          │                  │
│  Sarah   │                 │ Transcript               │ **Decisions**    │
│          │                 │                          │ Ship in Sept     │
│ Projects │                 │ **Me** `00:00`           │                  │
│          │                 │ Morning John...          │ **Action Items** │
│ + Folder │                 │ **Them** `00:18`         │ - Jeff: RFC doc  │
│          │                 │ Yeah I'm good...         │                  │
│          │                 │                          │ [Re-summarise]   │
└──────────┴─────────────────┴──────────────────────────┴──────────────────┘
```

### Speaker-attributed transcripts

Each recording produces two audio sidecar files — one for your microphone, one for system audio. These are transcribed independently and merged by timestamp, so every segment in the transcript is labelled:

```markdown
**Me** `00:00`

Morning John, how are you doing?

**Them** `00:18`

Yeah I'm good. I wanted to talk about the platform project...

**Me** `00:34`

Sure, what's on your mind?
```

If sidecar files are unavailable, the app falls back to transcribing the combined recording without speaker labels.

### AI Summary panel

The rightmost panel generates a concise AI summary of the transcript using the **local Tabnine CLI** — nothing is sent to any external server.

- Click **Summarise** to generate. This calls `tabnine` on your machine and takes 5–15 seconds.
- The summary is saved as `<recording>_summary.md` next to the audio file and **reloaded automatically** on future visits — no need to regenerate.
- Click **Re-summarise** to force a fresh summary (overwrites the saved one).
- Click **Copy** to copy the summary to the clipboard.

The summary is structured as:

```
**Key Topics**
…

**Decisions Made**
…

**Action Items**
…
```

#### Tabnine CLI requirement

The AI Summary feature requires the [Tabnine CLI](https://www.tabnine.com) to be installed locally. The default expected path is:

```
/Users/<you>/.local/bin/tabnine
```

If yours is installed elsewhere, update it in **Settings → AI Summary → Executable Path**.

### Organising meetings

- Click **+ Folder** in the sidebar to create a folder
- Drag a meeting from the list into a folder, or use **Move to Folder** in the toolbar
- Folder structure is stored in metadata — audio files are never moved

### Search

Use the search bar above the meetings list to filter by meeting title.

---

## Transcript format

Each meeting produces a Markdown file at:

```
~/Library/Application Support/MeetingRecorder/Recordings/<date>_<name>/
├── recording.mp4          ← combined audio (for playback)
├── recording_mic.caf      ← your microphone only
├── recording_system.caf   ← remote participants only
├── recording_transcript.md
└── recording_summary.md   ← AI summary (created on demand)
```

Example transcript with speaker attribution:

```markdown
---
id: 09E4FC95-17A0-4B65
title: "1:1 with John Smith"
date: 2026-08-26
started: 10:02
duration_seconds: 2712
meeting_application: "Microsoft Teams"
audio_file: "recording.mp4"
---

# 1:1 with John Smith

**Date:** 26 August 2026
**Started:** 10:02
**Ended:** 10:47
**Duration:** 45 minutes
**Application:** Microsoft Teams

## Transcript

**Me** `00:00`

Morning John, how are you?

**Them** `00:18`

Yeah I'm good. I wanted to talk about the platform project...
```

---

## Settings

Open via **Settings** in the menu bar or `⌘,`.

| Tab | What you can configure |
|---|---|
| **General** | Launch at login, auto-recording, show startup screen at launch, notifications |
| **Recording** | Microphone info (uses system default) |
| **Transcription** | Auto-transcribe after recording, language |
| **Storage** | Storage usage, open in Finder, retention policy |
| **Privacy** | Permission status for Screen Recording and Microphone |
| **AI Summary** | Tabnine CLI executable path (with Browse button and live Found/Not found indicator) |

---

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Space` | Play / Pause selected recording |
| `←` / `→` | Rewind / Forward 10 seconds |
| `Delete` | Delete selected meeting |

---

## Building from source

### 1. Clone the repository

```bash
git clone https://github.com/strognoff/transcript-shark.git
cd transcript-shark
```

### 2. Open in Xcode

```bash
open MeetingRecorder/MeetingRecorder.xcodeproj
```

### 3. Select your team

1. Select the `MeetingRecorder` target
2. Open **Signing & Capabilities**
3. Set your Apple Developer Team (a free personal team works for local development)

### 4. Build and run

Press **⌘R** or choose **Product → Run**.

### 5. Run on your machine without a paid account

For personal use without an Apple Developer account:

1. **Product → Archive**
2. In Organizer: **Distribute App → Copy App**
3. Drag the exported `.app` to `/Applications`
4. First launch: right-click → Open (bypasses Gatekeeper for unsigned apps)

Or bypass Gatekeeper via Terminal:
```bash
xattr -dr com.apple.quarantine /Applications/MeetingRecorder.app
```

### Run tests

```bash
xcodebuild test 
  -scheme MeetingRecorder 
  -destination 'platform=macOS' 
  CODE_SIGN_IDENTITY="" 
  CODE_SIGNING_REQUIRED=NO 
  CODE_SIGNING_ALLOWED=NO
```

Or press **⌘U** in Xcode.

---

## Dependencies

No third-party libraries. Apple frameworks only:

| Framework | Purpose |
|---|---|
| `SwiftUI` | UI |
| `SwiftData` | Persistence |
| `ScreenCaptureKit` | System audio capture |
| `AVFoundation` | Microphone capture, audio files |
| `Speech` | On-device transcription |
| `UserNotifications` | System notifications |
| `OSLog` | Structured logging |
| `ServiceManagement` | Launch at login |
| `Foundation.Process` | Tabnine CLI invocation |

**External tool (optional):** [Tabnine CLI](https://www.tabnine.com) — required only for AI Summary.

---

## Privacy

- Audio, transcripts, and summaries are stored **locally only**
- Nothing is uploaded to any server
- AI Summary uses the **local Tabnine CLI** on your machine — transcript text never leaves your Mac
- No analytics or telemetry

---

## Legal notice

You are responsible for complying with any applicable recording consent laws, workplace policies, and confidentiality requirements before recording a meeting. The app displays a first-run consent acknowledgement to this effect.

---

## Roadmap

**Shipped (v1.0)**
- Automatic Teams meeting detection and recording
- Speaker-attributed transcription (Me / Them)
- AI summary panel powered by local Tabnine CLI (persisted to disk)
- Folder organisation with drag-and-drop
- Menu bar status with manual recording
- Settings window with all configuration options
- Launch at login, notifications, retention policy

**Next**
- Zoom, Google Meet, Slack Huddle detection
- Full-text search across all transcripts
- Local Whisper transcription option
- People view (per-person meeting history)
- Action item extraction

---

## License

See [LICENSE](LICENSE).
