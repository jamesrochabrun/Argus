# Argus

<img width="2058" height="830" alt="Image" src="https://github.com/user-attachments/assets/8fd7f2fe-612a-42eb-b97e-7e54869cd383" />

A MCP (Model Context Protocol) server for analyzing videos and extracting UI/animation design specifications using OpenAI's Vision API.

## Install

```bash
# 1. Install ffmpeg (required)
brew install ffmpeg

# 2. Install Argus
curl -fsSL https://raw.githubusercontent.com/jamesrochabrun/Argus/main/install.sh | sh
```

The script downloads the binary and shows configuration instructions.

### Configure Claude Code

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

## Tools

| Tool | Purpose | Cost |
|------|---------|------|
| `analyze_video` | Describe video content (UI, animations, design elements) | ~$0.001-0.003 |
| `design_from_video` | Extract animation specs for implementation in any framework | ~$0.003-0.01 |

### analyze_video

Describes what's happening in a video.

```
Analyze this video: /path/to/recording.mov
```

### design_from_video

Extracts animation timing, curves, and choreography into a framework-agnostic spec.

**Parameters:**
- `video_path`: Path to video file
- `mode`: `quick` or `high_detail`
- `focus_hint` (optional): Element to focus on

```
Extract animation specs from /path/to/animation.mov using quick mode
```

**Output:** JSON spec with elements, keyframes, curves - ready for SwiftUI, React, Flutter, etc.

---

## Build from Source

For contributors:

```bash
git clone https://github.com/jamesrochabrun/Argus.git
cd Argus
swift build -c release
.build/release/argus --setup
```

---

## License

MIT
