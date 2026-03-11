# TartDesk

`TartDesk` is a macOS desktop app for managing [Tart](https://github.com/cirruslabs/tart) virtual machines and OCI images with SwiftUI.

## Requirements

- macOS 14+
- `tart` installed and available on the machine
- Tart-compatible VMs or OCI images

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
- Some features depend on guest setup, for example:
  - SSH requires guest networking and an SSH server
  - `tart exec` requires Tart Guest Agent support in the guest
  - Shared folders require Tart's directory sharing support; macOS guests mount them under `/Volumes/My Shared Files` by default
- `dist/` is a build artifact directory and is not meant to be committed.
