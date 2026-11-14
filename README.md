# Butterfly

Meeting notes for Lithuanian teams, living in your Mac's notch. Butterfly records Zoom, Teams, Meet, Slack and FaceTime calls and writes the transcript, summary and action items, built for how Lithuanian business is actually spoken: Lithuanian with English work terms mixed in ("deploy'inti", "sprint'as", "OpenAI"). English stays English, nothing gets translated.

Also: hold right ⌥ to dictate in Lithuanian or English anywhere you type.

## Install

1. Download **[Butterfly.zip](https://github.com/armandokun/butterfly/releases/latest/download/Butterfly.zip)**.
2. Unzip it and drag **Butterfly** to **Applications**.
3. Open it. macOS says it can't check it for malicious software: click **Done**, then **System Settings → Privacy & Security → Open Anyway**. Only the first time.
4. Allow Microphone, Screen Recording (call audio) and Accessibility (dictation) when asked.

Requires macOS 26 or later. Updates install automatically (or menu bar icon → **Check for Updates…**).

## API key

Paste a **[Gemini](https://aistudio.google.com/apikey)** key in **Settings** (menu bar icon → Settings…). It's stored in your Keychain.

Add names and terms your team uses (people, clients, products) in **Settings → Vocabulary** so they're spelled right.

## Privacy

Meeting audio and dictation go straight from your Mac to Google Gemini with your own key, and meeting files are deleted from Google right after. In the EU, Switzerland and the UK, Google doesn't train on it or have people review it, even on a free key. Elsewhere, use a key with billing turned on for the same terms ([Gemini API terms](https://ai.google.dev/gemini-api/terms)). Transcripts are saved in Documents › Butterfly Meetings.

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
