<div align="center">

# Container Desktop

**A native macOS desktop for Apple's open-source container runtime.**

Run, inspect and manage Linux containers on Apple silicon, with each container in its own lightweight VM.
SwiftUI, no Electron, and no always-on Linux VM.

[![CI](https://github.com/incrediblezayed/container-desktop/actions/workflows/ci.yml/badge.svg)](https://github.com/incrediblezayed/container-desktop/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20·%20Apple%20silicon-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)

</div>

---

## Why

Apple's [`container`](https://github.com/apple/container) runs every Linux container in its own micro-VM using macOS's Virtualization framework. You get sub-second starts, VM-level isolation, a dedicated IP for each container, and **nothing running when nothing is running**. It ships only as a command-line tool, though.

Container Desktop adds the missing desktop experience. The plan is for it to become for Apple's runtime what Docker Desktop is for Docker, including the Docker-compatible socket that `docker`, `docker compose`, VS Code Dev Containers and Testcontainers expect.

## Features

| | |
|---|---|
| **Containers** | Start, stop, restart, kill and delete. Live CPU and memory in every row. Open a shell in Terminal, or a published port in the browser. |
| **Details** | Ports, mounts, environment, labels and IP. Streaming logs with filtering, live CPU and memory charts, and raw `inspect`. |
| **Run** | Image, name, command, ports, volumes (with a folder picker), environment, CPU and memory limits, network, `--rm` and Rosetta, all validated before anything runs. |
| **Images** | Pull with live progress, run from an image, delete and prune. Runtime-internal images are hidden by default. |
| **Volumes and networks** | Create and delete, and see which containers use each one. |
| **System** | Start and stop the runtime, versions and usage. A first-run guide appears when the CLI is missing. |
| **Menu bar** | Running containers with one-click start and stop. |

## Getting started

### Requirements

- A Mac with Apple silicon
- macOS 26 or later (required by the runtime)
- Apple's `container` CLI. Install the signed package from its [releases page](https://github.com/apple/container/releases), then run `container system start`.

### Build and run

```sh
git clone https://github.com/incrediblezayed/container-desktop.git
cd container-desktop
open ContainerDesktop.xcodeproj   # then ⌘R
```

Run the tests:

```sh
swift test --package-path Packages/ContainerKit
```

### Working without the runtime

`Scripts/fake-container` stands in for the CLI and replays the JSON test fixtures, so you can work on the UI on any Mac. Enable the `CONTAINER_DESKTOP_CLI` environment variable in the scheme (*Product → Scheme → Edit Scheme → Run → Environment*), or run:

```sh
open -n --env CONTAINER_DESKTOP_CLI="$PWD/Scripts/fake-container" "path/to/Container Desktop.app"
```

### Troubleshooting

- **A published port (`-p 8080:80`) hangs or resets, but the container's own IP works.** macOS is blocking the runtime's port forwarder. Turn on `container-runtime-linux` under *System Settings → Privacy & Security → Local Network*, then restart the container. See [apple/container#2029](https://github.com/apple/container/issues/2029).
- **`container system start` sits silently for minutes the first time.** It's downloading the Linux kernel (about 680 MB) without showing progress. Let it finish. If it was interrupted, run `container system kernel set --recommended`.

## Docker compatibility with Socktainer

[Socktainer](https://github.com/socktainer/socktainer) serves a Docker Engine API (v1.51) socket on top of Apple's runtime. With it, `docker run`, `docker compose`, interactive `exec`, `cp`, builds and events work against Apple containers.

Container Desktop will **manage Socktainer for you**, much as Docker Desktop manages `dockerd`, rather than building a competing daemon:

- [ ] Detect or install Socktainer (via Homebrew) and run it as a background service
- [ ] One-click `docker context` setup, plus `DOCKER_HOST` instructions
- [ ] Health and status of the socket in the app and the menu bar
- [ ] A version check, because Socktainer pins an exact `container` release
- [ ] Group containers by Compose project using `com.docker.compose.*` labels

When something should be fixed in Socktainer itself, we fix it upstream, following [its contribution guidelines](https://github.com/socktainer/socktainer#contributing-).

## Architecture

```
ContainerDesktop/            SwiftUI app
  App/AppModel.swift         Observable state, polling, actions
  Views/                     Containers, Images, Volumes, Networks, System, Menu bar
Packages/ContainerKit/       Runtime access, no UI, unit tested
  CLIRunner                  async Process wrapper: timeouts, cancellation, line streaming
  ContainerEngine            the protocol the UI talks to
  CLIContainerEngine         implementation over `container … --format json`
  Models                     version-tolerant decoders for the CLI's JSON
  RunSpec                    form → validated `container run` arguments
Scripts/fake-container       fixture-backed CLI for UI development
```

### Design decisions

**The CLI, not Apple's Swift client library.** People install and upgrade the runtime independently of this app. Linking `ContainerAPIClient` would build one XPC protocol version into the binary, so any runtime upgrade could break the app. The CLI's JSON output is the most stable contract Apple ships. ContainerKit decodes only the fields it needs, tolerates type changes, and skips entries it can't read instead of failing the whole list. `ContainerEngine` leaves room for a native backend later.

**Not sandboxed.** The app launches the `container` binary, which talks to launchd services, and the App Sandbox doesn't allow that. Releases will be Developer ID signed, built with the hardened runtime, notarized, and distributed outside the Mac App Store.

**Light by default.** Polling slows from 3 to 15 seconds when the app is in the background. Stats are sampled only while containers are running, and logs are batched and capped so a noisy container can't freeze the UI.

### Apple's runtime compared with Docker Desktop

Apple's runtime wins on idle footprint, isolation, startup time and per-container IPs. Docker Desktop is still ahead on bind-mount-heavy workloads (big `node_modules` trees, live-reloaded source) and on stacks with many small containers, because all of its containers share one VM and kernel.

## Roadmap

- [x] Containers, images, volumes, networks, system, menu bar
- [ ] Socktainer integration (see above)
- [ ] Compose projects view
- [ ] `container build` from a Dockerfile
- [ ] Registry sign-in
- [ ] Embedded terminal
- [ ] Notarized DMG releases and auto-updates

## Contributing

Issues and pull requests are welcome.

- Use [Conventional Commits](https://www.conventionalcommits.org/), for example `feat(images): show pull progress`.
- Add or update tests in `Packages/ContainerKit/Tests` for any change to runtime access or parsing. If the CLI's JSON changed, add a fixture captured from the real CLI.
- Keep pull requests small and focused.

## License

[Apache License 2.0](LICENSE), the same as Apple's `container` and Socktainer.

Container Desktop is an independent project and isn't affiliated with or endorsed by Apple Inc. or Docker, Inc.
