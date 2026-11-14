# Butterfly

Meeting notes for your Mac, living in the notch. Records Zoom, Teams, Meet, Slack and FaceTime calls and writes the transcript. Hold right ⌥ to dictate anywhere.

## Install

1. Download **[Butterfly.zip](https://github.com/armandokun/butterfly/releases/latest/download/Butterfly.zip)**.
2. Unzip it and drag **Butterfly** to **Applications**.
3. Open it. macOS says it can't check it for malicious software: click **Done**, then **System Settings → Privacy & Security → Open Anyway**. Only the first time.
4. Allow Microphone, Screen Recording (call audio) and Accessibility (dictation) when asked.

Requires macOS 26 or later. Updates install automatically (or menu bar icon → **Check for Updates…**).

## API key

Paste a **[Gemini](https://aistudio.google.com/apikey)** key in **Settings** (menu bar icon → Settings…) for meeting transcripts. It's stored in your Keychain.

## Build from source

Needs Xcode 26 (or its Command Line Tools).

```bash
./scripts/install.sh      # build, install to /Applications, launch
swift build               # just compile (debug flags: see Sources/Butterfly/CLI.swift)
```

The code lives in `Sources/Butterfly`. Without a Developer ID certificate, builds are signed ad-hoc, so macOS asks for permissions again after each rebuild.

Crash reports and logs: `~/Library/Logs/Butterfly`.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[GPL-3.0](LICENSE). You can use, change and sell it; anything you distribute that's based on it must also be open source under the GPL.

Bundles [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3) and [Sparkle](https://sparkle-project.org) (MIT).
