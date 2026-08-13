# Codex Completion Sound Manager

A lightweight Windows app that plays a custom sound whenever a Codex task finishes. It uses Codex's global `notify` configuration, so the manager does **not** need to stay open in the background.

![Codex Completion Sound Manager interface](docs/interface.png)

## Highlights

- Global completion sounds for Codex tasks on Windows
- A calm bundled completion sound that works immediately after installation
- WAV and MP3 support, with files stored locally
- Adjustable volume and repeat count
- Light and dark themes
- English, Russian, Spanish, German, and Simplified Chinese interfaces
- Protection against overlapping notifications
- Preserves and forwards an existing Codex notifier
- Creates a backup before changing `config.toml`
- Restores the previous notifier when the integration is disabled
- No telemetry, network requests, accounts, or background service

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- Codex with a user configuration directory at `%USERPROFILE%\.codex`

## Quick start

1. Download this repository as a ZIP and extract it, or clone it with Git.
2. Run `Install.ps1`.
3. Open **Codex Completion Sound Manager** from the desktop shortcut.
4. Select **Preview** to hear the bundled sound, or choose your own WAV or MP3 file.
5. Select **Apply to Codex**.
6. Fully quit and reopen Codex once.

If Windows blocks the installer script, open PowerShell in the project folder and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer copies the app to:

```text
%USERPROFILE%\.codex\codex-completion-sound-manager\
```

It also creates a desktop shortcut. Existing installed files are backed up before they are replaced.

## Portable use

You can run the app directly without installing it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexSoundManager.ps1
```

Keep the project folder in a stable location before selecting **Apply to Codex**, because Codex stores the absolute script path.

## How it works

The app updates the global `notify` entry in `%USERPROFILE%\.codex\config.toml`. When Codex completes a task, it starts the script in notification mode. The script reads the local settings, plays the selected audio, forwards any previously configured notifier, and exits.

The graphical settings window is only needed when you want to change the sound or preferences. It does not need to remain open.

## Files and privacy

The app stores its data next to the installed script:

```text
settings.json       Local preferences
sounds\             Imported WAV and MP3 files
assets\default-sound.mp3  Bundled default completion sound
notifier.log        Local diagnostic log
playback.lock       Temporary overlap-protection lock
```

Nothing is uploaded. The app does not read conversation content, API keys, or account information.

## Safety and recovery

- `config.toml` is backed up before every integration change.
- An existing notifier is saved and forwarded instead of being silently discarded.
- Selecting **Disable** removes this integration and restores the saved notifier.
- Imported audio is copied into the app's local `sounds` directory, so deleting the original file does not break notifications.

## Uninstall

1. Open the manager and select **Disable** to restore the previous Codex notifier.
2. Close the manager.
3. Remove `%USERPROFILE%\.codex\codex-completion-sound-manager` and the desktop shortcut if you no longer need them.

## Credits

This is an independent PowerShell/WPF implementation. Its feature direction was inspired in part by the open-source [miao8818/codex-sound-manager](https://github.com/miao8818/codex-sound-manager) project.

The bundled **Clear Bell Chime** sound is by [Universfield](https://pixabay.com/users/universfield-28281460/) via [Pixabay](https://pixabay.com/sound-effects/film-special-effects-clear-bell-chime-487898/). See [Third-party notices](THIRD_PARTY_NOTICES.md).

## License

The application code is available under the [MIT License](LICENSE). The bundled audio is provided under the Pixabay Content License and is not covered by the MIT License; see [Third-party notices](THIRD_PARTY_NOTICES.md).
