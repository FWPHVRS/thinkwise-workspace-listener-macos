# SQL Folder Listener for Thinkwise on macOS

A small menu bar app that watches the workspace folder used by Thinkwise Software Factory and opens SQL files in your preferred editor. Choose TablePlus, Visual Studio Code, another installed app, or the macOS default for `.sql` files.

This is an independent community utility, not an official Thinkwise product. It does not include or modify Thinkwise's Linux listener.

## Maintenance and support

This project is shared as a community contribution, provided as-is. There is no commitment to active maintenance, future releases, compatibility with future macOS or Thinkwise versions, or fixed response times. No commercial support or service-level agreement is included.

You are welcome to report issues or contribute improvements through GitHub. Reports and contributions may be reviewed when time permits; a response or fix is not guaranteed. Thinkwise does not provide support for this utility.

## Download and install

**[Download the latest release](https://github.com/FWPHVRS/thinkwise-workspace-listener-macos/releases/latest)** — choose the `macOS-universal.zip` asset. One app supports Apple Silicon and Intel Macs running macOS 13 or later. No .NET installation is needed.

1. Unzip the download and drag **SQL Folder Listener.app** into **Applications**.
2. Open the app from Applications.
3. Under **Open files with**, select **Choose application…** and select your installed SQL editor. Alternatively, select **Use macOS default** from that menu to follow your current `.sql` file association.
4. Click **Choose…** next to **Workspace folder** and select the same workspace folder you select in Software Factory's browser folder picker.
5. Keep **Open updated files** and **Include subfolders** enabled for the usual Software Factory workflow.
6. Keep your editor open and ready, then have Software Factory write a SQL file to the workspace folder.

The release is ad-hoc signed, but **not Apple Developer ID signed or notarized**. macOS may block its first launch. If you trust the downloaded release, follow [Apple's instructions for opening an unidentified app](https://support.apple.com/en-us/102445). Do not disable Gatekeeper system-wide. On a managed Mac, your administrator may need to approve it. You can also build the app locally from the source below.

## How it works

- Watches new and updated `.sql` files, including uppercase `.SQL`.
- Waits until a file has been unchanged across scans for at least two seconds before opening it. This is a settling delay, not a guarantee that the browser has completed a long write.
- Skips files already present when monitoring starts or restarts. Changing the folder or monitoring options starts a new baseline.
- Monitors subfolders when enabled; skips hidden files, app packages, and symbolic-link files.
- Sends files to the chosen editor through macOS's normal open-file mechanism. It does not execute SQL or connect to your database.
- Saves your folder, editor and monitoring options locally. There is no telemetry or network service in this utility.

The status panel shows whether monitoring is active, paused, or needs attention. Use **Pause** / **Resume** to control monitoring. **How it works** explains startup behavior and background operation. **Quit listener** exits the app.

Closing the settings window keeps monitoring in the background. Use **SQL → Settings…** to reopen it, or **SQL → Quit** to stop the app. **SQL ●** means monitoring is enabled; check Settings for file-access errors. Launch the app again after restarting your Mac; automatic login startup is not configured.

The app polls every half second and reads SQL files to detect changes. It is intended for a working folder of generated scripts, rather than a large archive. Files written while the app is stopped are treated as existing files on its next start.

## Editor compatibility

The selected application must support opening `.sql` documents through macOS. TablePlus opening and refreshing files were verified during development. Selecting TextEdit and opening a SQL file in it were also verified. Other editors can be selected, but their handling of an already-open file, unsaved changes, and cold startup varies. Keep a database editor open with the intended connection ready. A successful handoff means macOS accepted the open request; it does not prove the editor displayed the file or selected the correct connection.

If you save changes in the editor while monitoring updates, the listener also detects those changes. Disable **Open updated files** if that is inconvenient.

If nothing opens, check the status in Settings, verify both folder selections match, and confirm your editor can open a `.sql` file from Finder. Browser support for Software Factory's folder picker is separate from this app. macOS folder permissions may also require your approval.

## Build from source

Requires macOS and Apple's Xcode Command Line Tools (or Xcode). There are no third-party package dependencies.

```sh
git clone https://github.com/FWPHVRS/thinkwise-workspace-listener-macos.git
cd thinkwise-workspace-listener-macos
bash scripts/build.sh
```

The script compiles both CPU architectures, combines them into a universal app, ad-hoc signs it, runs the watcher self-tests on the host architecture, and writes a ZIP plus SHA-256 checksum into `dist/`. The app bundle is in `build/`.

```sh
"build/SQL Folder Listener.app/Contents/MacOS/SQLFolderListener" --self-test
cd dist
shasum -a 256 -c SQL-Folder-Listener-1.2.0-macOS-universal.zip.sha256
```

Automated tests cover startup files, settling writes, new files, updates, duplicate suppression, extension filtering, deletion, new-only mode and subfolders. Building both architectures does not replace runtime testing on an Intel Mac. The GitHub Actions workflow builds and tests the same source and retains its own downloadable build artifact.

## Contributing and license

Please open an issue with your macOS version, editor/version, the action you took, and the status shown by the listener. Remove private SQL, credentials and personal paths from reports.

MIT licensed; see [LICENSE](LICENSE).
