# TartDesk

`TartDesk` is a macOS desktop app for managing [Tart](https://github.com/cirruslabs/tart) virtual machines and OCI images with SwiftUI.

## Requirements

- macOS 14+
- `tart` installed separately and available on the machine
- Tart-compatible VMs or OCI images

`TartDesk` does not bundle `Tart`. Install it separately with:

```bash
brew install cirruslabs/cli/tart
```

## Development

Run the app directly from Swift Package Manager:

```bash
swift run
```

Build only:

```bash
swift build
```

## Build `.app`

Build a local `.app` bundle for ad-hoc use:

```bash
./scripts/build-app.sh
```

Generated app:

```bash
dist/TartDesk.app
```

Open it:

```bash
open dist/TartDesk.app
```

The build script also generates and embeds a temporary app icon.

## Distribution

For general distribution, use the notarized GitHub Actions flow in [`.github/workflows/release.yml`](/Users/mohnya/Projects/Mohnya/tartdesk/.github/workflows/release.yml).

The latest signed app bundle is available from [GitHub Releases](https://github.com/Moomo/TartDesk/releases).

Download the latest `.zip`, extract `TartDesk.app`, then drag and drop it into your `Applications` folder.

Push a version tag to trigger the workflow:

```bash
git tag v0.0.1
git push origin v0.0.1
```

The workflow runs on the self-hosted macOS runner and:

- builds `TartDesk.app`
- signs it with `Developer ID Application`
- notarizes and staples it
- uploads the final zip to GitHub Releases

You can also run the workflow manually from the GitHub Actions UI when needed.

## Features

- List local VMs and OCI images
- Deduplicate OCI tag and digest entries in the UI
- Run local VMs in graphics or headless mode
- Configure per-VM shared folders from Edit VM Settings and apply them on run
- Stop local VMs
- Create local VMs from OCI images or other local VMs
- Create empty VMs
- Edit local VM settings
  - name
  - CPU
  - memory
  - display size
  - disk size
- Delete local VMs with confirmation
- Show Guest Agent / `tart exec` status
- Show VM IP address for SSH
- Copy SSH command
- Open SSH command in Terminal

## Notes

- OCI images cannot be run directly. Clone them into a local VM first.
- `TartDesk` is a GUI wrapper around the `tart` CLI and depends on a separately installed `Tart`.
- Some features depend on guest setup, for example:
  - SSH requires guest networking and an SSH server
  - `tart exec` requires Tart Guest Agent support in the guest
  - Shared folders require Tart's directory sharing support; macOS guests mount them under `/Volumes/My Shared Files` by default
- `dist/` is a build artifact directory and is not meant to be committed.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

`TartDesk` and `Tart` are licensed separately.

- `TartDesk`: MIT License
- `Tart`: licensed by Cirrus Labs under the Fair Source License 0.9

See the official `Tart` repository and its license for details:

- <https://github.com/cirruslabs/tart>
- <https://github.com/cirruslabs/tart/blob/main/LICENSE>
