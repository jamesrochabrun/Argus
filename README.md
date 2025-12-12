# Argus

<img width="2058" height="830" alt="Image" src="https://github.com/user-attachments/assets/8fd7f8fe-612a-42eb-b97e-7e54869cd383" />

A MCP (Model Context Protocol) server for analyzing videos and extracting UI/animation design specifications using OpenAI's Vision API.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/jamesrochabrun/Argus/main/install.sh | sh
```

### After Installing

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "argus": {
      "type": "stdio",
      "command": "~/.local/bin/argus",
      "args": ["mcp"],
      "env": {
        "OPENAI_API_KEY": "your-openai-api-key"
      }
    }
  }
}
```

Get your API key at: https://platform.openai.com/api-keys

Restart Claude Code to use Argus.

---

## Requirements

- macOS 14.0+
- OpenAI API key
- ffmpeg (`brew install ffmpeg`)

---

## Available Tools

| Tool | Purpose | Cost |
|------|---------|------|
| `analyze_video` | Describe video content (UI, animations, design elements) | ~$0.001-0.003 |
| `design_from_video` | Extract animation specs for implementation in any framework | ~$0.003-0.01 |

### analyze_video

Analyzes a video file and describes what's happening visually.

**Parameters:**
- `video_path` (required): Absolute path to video file
- `custom_prompt` (optional): Custom analysis prompt

**Example:**
```
Analyze this video: /path/to/recording.mov
```

### design_from_video

Extracts animation timing, curves, and choreography into a framework-agnostic specification.

**Parameters:**
- `video_path` (required): Absolute path to video file
- `mode` (required): `quick` (~$0.003) or `high_detail` (~$0.01)
- `focus_hint` (optional): Element to focus on (e.g., "the blue button")

**Example:**
```
Extract animation specs from /path/to/animation.mov using quick mode
```

**Output includes:**
- What the animation does (natural language)
- Timeline of events
- Animation spec (JSON) with elements, keyframes, curves
- Ready for implementation in SwiftUI, React, Flutter, etc.

---

## Build from Source

```bash
git clone https://github.com/jamesrochabrun/Argus.git
cd Argus
brew install ffmpeg  # Required dependency
swift build -c release

# Auto-configure Claude Code
.build/release/argus --setup
```

---

## Architecture

```
Claude Code
    │
    │ MCP Protocol (stdio)
    ▼
argus mcp
    │
    ├── FFmpeg (frame extraction)
    │
    └── OpenAI Vision API
            │
            ▼
    Design Specification (JSON)
```

---

## License

MIT
