# gosync

Copy photos and videos from a GoPro to an Android phone over USB, and convert
the videos to H.264 the phone can actually play. Runs in Termux; no app to build.

Plug in the GoPro, turn it on, tap the **gosync** button. New files land in
`DCIM/Camera`, ready for the gallery.

## Why

A HERO12 shoots 5.3K HEVC. Many phones can't play that: the hardware decoder
tops out below 5.3K. These scripts make a 1080p (or 4K) H.264 copy of each clip
and tuck the HEVC original away.

## What's here

| File | Does |
|---|---|
| `gosync.js` | Copies new media from the GoPro over USB, then runs `gosane.sh`. |
| `gosane.sh` | Converts GoPro HEVC clips in `DCIM/Camera` and `Movies/GoPro-Exports` to H.264. |
| `shortcuts/` | Termux:Widget home-screen buttons for both, with icons. |
| `install.sh` | Puts all of the above where Termux runs them. |

## Requirements

**On the phone, two apps:**

| App | Get it from | Why |
|---|---|---|
| **Termux** | F-Droid: <https://f-droid.org/packages/com.termux/> | Runs everything. |
| **Termux:Widget** | F-Droid: <https://f-droid.org/packages/com.termux.widget/> | Home-screen buttons. |

Get both from the **same source**. Termux add-ons only work with a Termux from
the same place (F-Droid builds don't work with Play Store or GitHub builds).
Searching F-Droid for "termux:widget" fails at the colon; search
`com.termux.widget` or use the link.

**In Termux, these packages:** `ffmpeg`, `curl`, `nodejs`, `util-linux`.
`install.sh` installs whichever are missing. You need `git` yourself to clone.

**The camera:** a GoPro that supports Open GoPro over USB (tested with a
HERO12 Black), with **Preferences > Connections > USB Connection** set to
**GoPro Connect**.

Not needed: Termux:API, root, or a computer.

## Install

1. Install Termux and Termux:Widget from F-Droid (above).
2. In Termux, get storage access and git, then clone:
   ```
   termux-setup-storage
   pkg install git
   git clone https://github.com/kdemarest/gosync.git /sdcard/gosync
   ```
3. Run the installer:
   ```
   bash /sdcard/gosync/install.sh
   ```
   It installs missing packages, copies the scripts to `~/.local/bin` and the
   buttons and icons to `~/.shortcuts`, and adds `~/.local/bin` to your PATH.
   Shared storage can't hold executable files, which is why the scripts are
   copied out. Rerun it after every `git pull`.
4. Put the buttons on the home screen. Android doesn't let any app do this for
   you, so it's a one-time drag:
   - Long-press the **Termux:Widget** app icon.
   - Drag **gosync** onto the home screen, and **gosane** too if you want it.
   - If the menu shows plain icons instead of the custom ones, force-stop
     Termux:Widget (Settings > Apps > Termux:Widget > Force stop) and
     long-press it again.

   The first time you tap a button, Android may ask to let Termux display over
   other apps or ignore battery optimization. Allow both.

   (Adding Termux:Widget as a *widget* gives a large list of all buttons
   instead of single icons.)

## Use

**gosync** (button, or `gosync.js` in Termux):

```
gosync.js        copy everything new from the camera, then convert
gosync.js -n     dry run: list what would be copied
```

**gosane** (button, or `gosane.sh` in Termux), to convert without a camera attached:

```
gosane.sh            1080p, hardware encoder
gosane.sh -4         4K
gosane.sh -sw        1080p with libx264: better quality, much slower
gosane.sh -n         dry run
gosane.sh FILE|DIR   convert specific files or folders
```

Logs: `~/gosync.log`, `~/gosane.log`.

## How it works

**gosync.js.** In GoPro Connect mode the camera appears to Android as a USB
network link, with the camera at `172.2X.1YZ.51`. gosync talks to it with the
[Open GoPro](https://gopro.github.io/OpenGoPro/) HTTP API, binding to that
interface (`curl --interface`) because Android otherwise sends traffic over
Wi-Fi.

- Copies `.MP4` and `.JPG` files, skipping `.LRV`/`.THM` previews.
- Remembers what it copied in `~/.gosync/copied.tsv` (name, capture time, size),
  so each run copies only new files, even if you delete them from the phone later.
- Downloads to a hidden `.part` file, checks the size, then renames.
- Sets each file's time to its capture time. If the camera's clock was wrong
  (before 2020), it uses the copy time instead, and rewrites the dates inside
  JPGs to match.
- Never deletes anything from the camera.

**gosane.sh.** Picks GoPro-named `.mp4` files (`GX…`, `GH…`, `GOPR…`, `GP…`,
`GS…`) without a `_1080`/`_4k` suffix, and converts the HEVC ones:

- Writes `NAME_1080.mp4` (or `_4k`) into `DCIM/Camera`, scaled to fit
  1920×1080 (or 3840×2160) in either orientation, audio copied as-is.
- Decodes in software (the phone's hardware decoder refuses 5.3K) and encodes
  with the hardware `h264_mediacodec` encoder, about 1.5 s per second of footage.
- Checks the result is H.264 with the same duration, then moves the original to
  `DCIM/GoPro-HEVC` (with `.nomedia`, so the gallery hides it).
- Keeps the original's capture date. A pre-2020 date (wrong camera clock) is
  replaced with the file's time.
- Skips files changed in the last 60 seconds, in case a sync is still writing them.

## Notes

- The gallery sorts by capture date, so converted clips appear on the day they
  were shot, not at the top.
- Android may take a while to show new files in the gallery; a restart forces a
  rescan.
- The phone stays awake while a button runs (`termux-wake-lock`).
