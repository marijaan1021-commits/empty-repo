# The Android emulator stack for GitHub Codespaces

A **headless Android 14 emulator** running inside a GitHub Codespace, with a
live view of its screen and working touch input.

This repository is the **rig**, not an app: it is ready for whatever Android
app you want to run. Drop a project into `app/` (or point the scripts at one
that is already on the machine) and the stack installs it, launches it and
keeps it alive.

## Start here

**→ [`START-HERE.md`](START-HERE.md)** — how to rebuild everything from
nothing in a fresh Codespace, step by step, with the checks.

```bash
bash scripts/install-toolchain.sh   # SDK + emulator + AVD + JDK 17 + Flutter
bash scripts/install-stack.sh       # link this repo into /workspaces + install the extension
bash scripts/create-keystore.sh     # the release signing key
bash /workspaces/emu.sh             # start the emulator, print the public URL
```

## Bring your own app

```bash
export APP_DIR=/workspaces/my_app          # the project
export APP_PKG=com.example.my_app          # the package id

setsid nohup bash /workspaces/build.sh "$APP_DIR" \
  android-arm,android-arm64,android-x64 >/tmp/flutter-build.log 2>&1 </dev/null & disown

bash /workspaces/emu.sh                    # installs, launches, keeps it alive
```

> Build **before** the emulator starts — a 3-ABI Gradle build with the emulator
> running gets the daemon OOM-killed on this 2-vCPU box.

## The documents

| File | What it is |
|---|---|
| [`START-HERE.md`](START-HERE.md) | **the procedure** — build from scratch, run it, verify it, the traps |
| [`AGENTS.md`](AGENTS.md) | the full history: 34 sessions, every measurement, every dead end |

## What is in here

| Path | What |
|---|---|
| `scripts/` | every runtime script — `emu.sh` is the one command |
| `extension.js`, `media/`, `package.json` | the VS Code extension that renders the emulator in a tab |
| `avd/testavd.config.ini` | the tuned AVD configuration |
| `.vscode/`, `.devcontainer/` | auto-start on folder open / on container start |

## Day to day

```bash
bash /workspaces/emu.sh            # start everything (idempotent)
bash /workspaces/emu.sh status     # health check
bash /workspaces/emu.sh stop       # stop everything
bash /workspaces/emu.sh url        # the public URL
bash /workspaces/verify.sh         # the eight health checkpoints
```
