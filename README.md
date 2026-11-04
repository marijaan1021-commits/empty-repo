# CallNote + the Android emulator stack

A **headless Android 14 emulator** running inside a GitHub Codespace, with a
live view of its screen and working touch input — plus **CallNote**, a Flutter
app that reminds you, *the instant a contact calls*, what you wanted to
remember about them.

## Start here

**→ [`START-HERE.md`](START-HERE.md)** — how to rebuild everything from
nothing in a fresh Codespace, step by step, with the checks.

```bash
bash scripts/install-toolchain.sh   # SDK + emulator + AVD + JDK 17 + Flutter
bash scripts/install-stack.sh       # link this repo into /workspaces + install the extension
bash /workspaces/emu.sh             # start the emulator, print the public URL
```

## The three documents

| File | What it is |
|---|---|
| [`START-HERE.md`](START-HERE.md) | **the procedure** — build from scratch, run it, verify it, the traps |
| [`CALLNOTE.md`](CALLNOTE.md) | the app: features, architecture, permissions, the timing problem and how it was solved |
| [`AGENTS.md`](AGENTS.md) | the full history: 32 sessions, every measurement, every dead end |

## What is in here

| Path | What |
|---|---|
| `app/` | the CallNote Flutter app (`com.example.mini_app`) |
| `extension.js`, `media/`, `package.json` | the VS Code extension that renders the emulator in a tab |
| `scripts/` | every runtime script — `emu.sh` is the one command |
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
