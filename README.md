<p align="center">
  <img src="Assets/Brand/app-icon-cat.png" alt="Open Island" width="128" height="128">
</p>

<h1 align="center">Open Island</h1>

<p align="center">
  Open-source, local-first, native macOS companion for AI coding agents.
  <br>
  <a href="README.zh-CN.md">中文</a> | <strong>English</strong>
</p>

<p align="center">
  <a href="https://github.com/Octane0411/open-vibe-island/releases/latest"><img src="https://img.shields.io/github/v/release/Octane0411/open-vibe-island?style=flat-square&label=release&color=blue" alt="Latest Release"></a>
  <a href="https://github.com/Octane0411/open-vibe-island/stargazers"><img src="https://img.shields.io/github/stars/Octane0411/open-vibe-island?style=flat-square&color=yellow" alt="Stars"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL%20v3-green?style=flat-square" alt="License: GPL v3"></a>
</p>

<p align="center">
  <a href="https://github.com/Octane0411/open-vibe-island/releases">Download</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="docs/roadmap.md">Roadmap</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <img src="docs/images/demo.gif" alt="Open Island in action" width="720">
</p>

## What It Does

Open Island sits in your Mac's notch or top bar and gives coding agents a small native control surface: live session status, permission prompts, notifications, and jump-back to the right terminal or IDE.

Everything runs locally. There is no account, server dependency, or telemetry.

## Highlights

- Native macOS app built with SwiftUI and AppKit
- Local hook bridge for agent events and approvals
- Session discovery and persistence across launches
- Jump-back support for terminals, IDEs, and selected agent apps
- Sparkle auto-update and signed release packaging

## Supported Surfaces

Open Island currently supports Claude Code, Codex CLI, Codex Desktop App, Cursor, Gemini CLI, Kimi CLI, OpenCode, Qoder, Qwen Code, Factory, and CodeBuddy.

Jump-back support includes Terminal.app, Ghostty, iTerm2, WezTerm, Zellij, tmux, cmux, Kaku, Warp, VS Code, Cursor, Windsurf, Trae, and JetBrains IDEs.

See [docs/product.md](docs/product.md) and [docs/hooks.md](docs/hooks.md) for the detailed support matrix.

## Quick Start

Download the latest DMG from [GitHub Releases](https://github.com/Octane0411/open-vibe-island/releases), or build from source:

```bash
git clone https://github.com/Octane0411/open-vibe-island.git
cd open-vibe-island
open Package.swift
```

On first launch, Open Island starts the local bridge and discovers existing sessions where possible. Hook installation is managed from the app's Control Center.

Requirements:

- macOS 14+
- Swift 6.2
- Xcode

## Development

Run the standard checks:

```bash
scripts/harness.sh
```

Useful docs:

- [Documentation index](docs/index.md)
- [Architecture](docs/architecture.md)
- [Quality and harness](docs/quality.md)
- [Packaging](docs/packaging.md)
- [Roadmap](docs/roadmap.md)

## License

[GPL v3](LICENSE)
