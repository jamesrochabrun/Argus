# Argus

<img width="2058" height="830" alt="Image" src="https://github.com/user-attachments/assets/8fd7f2fe-612a-42eb-b97e-7e54869cd383" />

A MCP (Model Context Protocol) server for visual QA using OpenAI's Vision API. Argus records your screen, extracts frames, and analyzes them for UI bugs, animation issues, and design-implementation misalignments.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/jamesrochabrun/Argus/main/install.sh | sh
```

This downloads the latest release and shows configuration instructions.

### After Installing

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "argus": {
      "type": "stdio",
      "command": "~/.local/bin/argus-mcp",
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

## Build from Source

For contributors or if you prefer building locally:

```bash
git clone https://github.com/jamesrochabrun/Argus.git
cd Argus
swift build -c release

# Auto-configure Claude Code (optional)
.build/release/argus-mcp --setup
```

The `--setup` flag automatically updates `~/.claude.json` with the correct paths.

### Manual Configuration

If you prefer manual setup, binaries are at:
- `.build/release/argus-mcp` - Main MCP server
- `.build/release/argus-select` - Visual region selector

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "argus": {
      "type": "stdio",
      "command": "/absolute/path/to/Argus/.build/release/argus-mcp",
      "env": {
        "OPENAI_API_KEY": "your-openai-api-key"
      }
    }
  }
}
```

---

## Analysis Modes

| Mode | Purpose | FPS | Max Duration | Resolution | Est. Cost |
|------|---------|-----|--------------|------------|-----------|
| `low` | UI Bug Detection | 4 | 30s | 512px | ~$0.003 |
| `high` | Detailed Analysis | 8 | 30s | 896px | ~$0.01 |

### Choosing the Right Mode

- **`low`**: Scan for layout issues, visual bugs, text truncation, overlapping elements. Best for quick QA checks.
- **`high`**: Pixel-level inspection for design-implementation alignment, accessibility concerns, and animation mechanics.

---

## Available Tools

| Tool | Description | Required |
|------|-------------|----------|
| `analyze_video` | Analyze an existing video file for UI bugs | `video_path` |
| `record_and_analyze` | Record screen and analyze for visual issues | `mode` |
| `select_record_and_analyze` | Select region with crosshair, record, and analyze | `mode` |

All tools support optional `duration_seconds` (max 30s) and `custom_prompt` parameters.

---

## Mode Examples

### 1. `low` - UI Bug Detection

**When to use:** Quick scan for layout issues, visual bugs, and broken UI states.

```
Record my screen for 3 seconds and analyze with mode low
```

**Output:**
```
## Video Analysis Results

### Video Information
- Duration: 3.0 seconds
- Resolution: 1920x1080
- Frames Analyzed: 12

### Summary
**[MEDIUM]** Text truncation in terminal output - last line cut off
**[LOW]** Overlapping notification banner with main content
**[LOW]** Inconsistent spacing between list items

No critical issues detected.

### Detailed Frame Analysis
**[0.0s - 1.5s]**
- Text truncation observed (Frame 3)
- Notification overlap detected (Frame 1-8)

**[1.5s - 3.0s]**
- Spacing inconsistency in sidebar (Frame 10)
```

---

### 2. `high` - Detailed Analysis

**When to use:** Design-implementation alignment, accessibility review, animation mechanics.

```
Record my screen for 3 seconds and analyze with mode high
```

**Output:**
```
## Video Analysis Results

### Video Information
- Duration: 3.0 seconds
- Resolution: 1920x1080
- Frames Analyzed: 24

### Summary
#### Design-Implementation Issues
- Color contrast insufficient for body text (#666 on #fff = 5.7:1, needs 7:1 for AAA)
- Button corner radius 4px, design spec shows 8px
- Focus indicator not visible on keyboard navigation

#### Animation Mechanics
- Modal slide-up uses ease-out curve, smooth 60fps
- Spring overshoot at Frame 18 matches design intent

#### Accessibility Concerns
- Touch targets on icons are 36x36px (below 44px minimum)
- Missing aria-labels on action buttons

### Actionable Recommendations
1. Increase text contrast ratio to meet WCAG AAA
2. Update corner radius to match design system
3. Add visible focus indicators for keyboard users
```

---

## Token Usage & Cost

| Mode | Typical Frames | Est. Input Tokens | Est. Cost |
|------|----------------|-------------------|-----------|
| `low` | 12-120 | ~25,000-40,000 | ~$0.003 |
| `high` | 24-240 | ~500,000-800,000 | ~$0.01+ |

**Cost Control Tips:**
1. Start with `low` mode for most QA tasks - it catches common UI bugs
2. Use `high` mode only when you need design-implementation verification
3. Use region selection to record only specific UI components

---

## Architecture

```
+-----------------------------------------------------------+
|                   Claude Code / Desktop                    |
+-----------------------------+-----------------------------+
                              | MCP Protocol (stdio)
+-----------------------------v-----------------------------+
|                        argus-mcp                           |
+-------------+-------------+-------------+-----------------+
|   Screen    |    Video    |    Video    |     Region      |
|  Recorder   |  Extractor  |  Analyzer   |    Selector     |
|(ScreenKit)  |(AVFoundation)|  (OpenAI)  | (argus-select)  |
+-------------+-------------+------+------+-----------------+
                                   |
                          +--------v--------+
                          |  OpenAI Vision  |
                          |   GPT-4o-mini   |
                          +-----------------+
```

---

## Permissions

Screen recording requires permissions:
1. System Preferences -> Privacy & Security -> Screen Recording

---

## Known Issues

- **External monitors not supported**: Currently only records the main display. External/secondary monitors are not captured.

---

## License

MIT
