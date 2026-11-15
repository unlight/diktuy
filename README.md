# Diktuy

A small Linux dictation script for the [Diktuy](https://diktuy.ru) speech-to-text API. Press a hotkey, speak, press it again, and the transcript is pasted into the active window.

## Features

- Toggle recording with one hotkey: first press starts, second press stops.
- Persistent on-screen indicator in the top-right corner of the primary monitor.
- Sends OGG audio to Diktuy with `language=auto` and a configurable term prompt.
- Restores the previous clipboard after pasting.
- Silent desktop notifications for errors and progress.
- Small Bash script; no Python, no daemon.

## Requirements

- Linux with X11 (tested on Cinnamon).
- A Diktuy API key.
- `arecord`, `sox`, `curl`, `xclip`, `xdotool`, `xmessage`, `wmctrl`, `xrandr`, `notify-send`.

On Debian/Ubuntu/Mint:

```bash
sudo apt install alsa-utils sox libsox-fmt-ogg curl xclip xdotool wmctrl x11-utils x11-xserver-utils libnotify-bin
```

## Install

```bash
git clone https://github.com/unlight/diktuy.git
cd diktuy
chmod +x diktuy.sh
```

Add your API key to the session environment:

```bash
echo 'export DIKTUY_API_KEY="your-key"' >> ~/.profile
```

Log out and back in, or run the script through `bash -lc` so `~/.profile` is loaded.

## Hotkey

Bind a key in your desktop environment to:

```bash
bash -lc '/path/to/diktuy/diktuy.sh'
```

In Cinnamon: Settings → Keyboard → Shortcuts → Custom Shortcuts → Add.

The first press starts recording; the second press stops it and pastes the text. The script itself does not choose the key.

## Configuration

Edit the top of `diktuy.sh`:

- `TERMS` — prompt with names and technical terms (up to 500 characters).
- `API_URL` — Diktuy transcription endpoint.
- `AUDIO_RAW`, `AUDIO_OGG`, `PID_FILE`, `LOG_FILE`, `LOCK_FILE` — temporary paths.

## How it works

1. `arecord` captures 16 kHz mono PCM.
2. `sox` converts it to OGG.
3. `curl` uploads it to Diktuy.
4. `xclip` puts the transcript in the clipboard and `xdotool` sends Shift+Insert.
5. The previous clipboard is restored.

HTTP errors are appended to `/tmp/diktuy.log`.

## Notes

- X11 only. Wayland is not supported by `xdotool`, `xclip`, `wmctrl`, or `xmessage`.
- The indicator is an `xmessage` window. It briefly takes focus; the script returns focus to the previous window.
- Pasting uses Shift+Insert. If your target application does not support it, adjust the `xdotool` line.
- The API key is read from `DIKTUY_API_KEY`, passed to `curl` through a temporary header file, and never stored in the repository.
