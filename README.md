# Whiteboard Recorder

A macOS menu bar app that records your meeting — **microphone and system audio
mixed into a single file** — and uploads it to
[Whiteboard](https://whiteboard.kepochan.com), which transcribes it into a note.

It replaces `meeting-agent-client-mac`, whose backend is being shut down.

## The app lives in the menu bar, nowhere else

Whiteboard Recorder has **no Dock icon and opens no window** (it is
`LSUIElement`). A circle appears in the menu bar at the top of the screen, and
that is all there is to see while nothing is being recorded. If you launch it
and nothing seems to happen, that is expected — look for the circle in the menu
bar, not for a window.

## Installing

1. Download `WhiteboardRecorder.zip`, unzip it, drag the app into `/Applications`.
2. On first launch, right-click the circle in the menu bar and open
   **Preferences…** to paste an API key. Create the key in Whiteboard under
   **Settings → API keys**, with the scopes `recordings:read` and
   `recordings:write` to upload, plus `notes:read` so the app can offer the
   workspace's existing tags.
3. Start a first recording (left-click the circle). macOS then asks for **two
   permissions**, one after the other — not before, and not at launch:
   - access to the **microphone**;
   - permission to **capture audio from other applications** ("Audio Recording"
     in System Settings → Privacy & Security).

   Both are needed. Without the second one only your own voice is recorded, and
   the other participants in the call are silent on the recording.

The app is signed but not notarised. On a machine other than the one it was
built on, macOS blocks the first launch: allow it from System Settings →
Privacy & Security.

## Using it

- **Left-click**: starts recording **immediately**. Nothing else happens and
  nothing is asked, so no part of the meeting is lost.
- **Left-click again**: stops the recording, then asks for the details —
  workspace, title, meeting date and time, language, visibility, tags. The
  meeting date defaults to the instant the recording *started*, not the instant
  it stopped. The language starts on French. Visibility offers two tabs, **Only
  me** (the default) and **Share with team** (workspace, read and edit); the
  chevron next to them lists every other mode.
- **OK** hands the recording to the upload queue. Uploads run in the
  background, one at a time, in pieces: a cut connection resumes where the
  server stopped, and a quit or a crash resumes at the next launch. The window
  shows the progress and can be closed; the icon is free for the next meeting at
  once.
- **Save a copy…** keeps a copy of the `.m4a` before it is sent. The
  local file is deleted once the upload succeeds, so this is the moment to ask
  for one.
- **Discard** throws the recording away.
- **Right-click**: elapsed time while recording, **Preferences…**, **Quit**.

The audio is not kept on the server: it is deleted once transcribed. The app
keeps its local copy until the server has the whole file and has created the
recording, then deletes it.

Tags are chosen from the tags that already exist in the workspace — the app
never invents one, and never sends a colour it did not receive. The `meeting`
tag is selected from the start and cannot be removed: the server puts it on
every recording anyway.

## When an upload fails

After four failed attempts in a row the upload pauses. It resumes by itself when
the network comes back, or from **Resume upload** in the window or the
right-click menu. A refused upload (key, workspace, title) shows the alert
below; it leaves the queue so the next one can go.

The local recording is **never deleted** on failure. An alert offers:

- **Retry**, when another attempt could plausibly succeed — or **Upload again**
  when the upload was finishing as it was cut, and the recording may already be
  on Whiteboard: check there first;
- **Save…**, to choose where to put the `.m4a`;
- **Close**.

If you dismiss the alert without choosing, or if the failure came from the
recording itself rather than from the upload, the file is moved to your save
folder — `~/Downloads` by default, configurable in the preferences.

Quitting the app mid-recording does not lose it either: the recording is
finalised, moved to the save folder, and the app tells you where it went. A file
left behind by a crash is recovered the next time the app starts.

## API key

The key is stored in the macOS Keychain, never in the preferences in clear text
and never in a file in this repository. It needs the scopes `recordings:read`,
`recordings:write` and `notes:read`, and is created in Whiteboard under
**Settings → API keys**.

## Technical note: the sandbox

The app keeps App Sandbox enabled (`com.apple.security.app-sandbox`). That is
possible because CoreAudio *process taps*
(`AudioHardwareCreateProcessTap`) — used here to capture system audio without a
kernel extension — **work under App Sandbox**. Apple does not document this; it
was verified before the rest of the capture was built on top of it.

## Development

```bash
swift test          # the business logic (RecorderCore), without Xcode
./run.sh            # builds in debug and launches the app
./build-release.sh  # produces WhiteboardRecorder.app and WhiteboardRecorder.zip
```

No API key may appear in the code, in a script, or in a commit.
