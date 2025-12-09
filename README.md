# Argus

<img width="2058" height="830" alt="Image" src="https://github.com/user-attachments/assets/8fd7f2fe-612a-42eb-b97e-7e54869cd383" />

A MCP (Model Context Protocol) server for video analysis using OpenAI's Vision API. Argus extracts frames from videos and analyzes them.

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

| Mode | Description | FPS | Max Frames | Max Duration | Resolution | Est. Cost |
|------|-------------|-----|------------|--------------|------------|-----------|
| `low` | Fast overview, quick summary | 2.0 | 60 | 30s | 512px | ~$0.002 |
| `auto` | Balanced detail, good for most tasks | 4.0 | 120 | 30s | 1024px | ~$0.005 |
| `high` | Comprehensive frame-by-frame analysis | 30.0 | 150 | 5s | 1280px | ~$0.05+ |

### Choosing the Right Mode

- **`low`**: Quick summary of what's in the video - good for getting an overview
- **`auto`**: Default choice - explains what happens step-by-step with good detail
- **`high`**: Detailed frame-by-frame analysis - best for animations, transitions, and visual details (limited to 5s recordings)

---

## Available Tools

| Tool | Description | Required |
|------|-------------|----------|
| `analyze_video` | Analyze a video file with specified mode | `video_path` |
| `record_and_analyze` | Record screen, then analyze | `mode` |
| `select_record_and_analyze` | Select region + record + analyze | `mode` |

All tools support optional `duration_seconds` and `custom_prompt` parameters. Max duration depends on mode: 30s for low/auto, 5s for high.

---

## Mode Examples

### 1. `low` - Fast Overview

**When to use:** Quick summary without detailed analysis.

```
Analyze the video at /path/to/demo.mp4 with mode low
```

**Output:**
```
## Video Analysis Results

### Video Information
- Duration: 12.5 seconds
- Resolution: 1920x1080
- Frames Analyzed: 6

### Summary
The video shows a mobile app login flow. A user enters credentials, taps the
login button, sees a loading spinner, and is taken to a home dashboard.
```

---

### 2. `auto` - Balanced Analysis

**When to use:** Thorough explanation of everything that happens.

```
Analyze the video at /path/to/tutorial.mp4 with mode auto
```

**Output:**
```
## Video Analysis Results

### Video Information
- Duration: 8.2 seconds
- Resolution: 1170x2532
- Frames Analyzed: 8

### Summary
This video demonstrates the checkout flow in an e-commerce iOS app.

### Detailed Frame Analysis
**[0.0s - 4.0s]**
1. Shopping cart with 3 items listed vertically
2. Each item shows: thumbnail, name/size, price
3. User taps green "Checkout" button
4. Slide-up animation reveals payment sheet

**[4.0s - 8.2s]**
1. Payment sheet shows: Apple Pay, Credit Card, PayPal
2. User selects Apple Pay
3. Face ID prompt appears
4. Success animation with confetti
5. Order confirmation screen
```

---

### 3. `high` - Comprehensive Analysis

**When to use:** Frame-by-frame analysis for animations, transitions, and visual details. Limited to 5 seconds max.

```
Record my screen for 3 seconds and analyze with mode high
```

**Output:**
```
## Video Analysis Results

### Video Information
- Duration: 3.0 seconds
- Resolution: 1170x2532
- Frames Analyzed: 90

### Summary
Modal presentation with spring animation showing smooth motion and visual transitions.

### Detailed Frame Analysis
**[0.00s - 0.17s]** (Frames 1-10)
## MOTION & TRANSITIONS
- Animation begins with ease-out curve
- Frame 1: Modal at y=2532 (off-screen)
- Frame 10: Modal at y=1266 (50% visible)

**[0.17s - 0.33s]** (Frames 11-20)
- Spring overshoot detected - characteristic bounce
- Frame 18: Modal overshoots slightly before settling

**[0.33s - 0.50s]** (Frames 21-30)
## VISUAL DETAILS
- Modal fully visible with shadow effect
- Background dims to 50% opacity
- Close button appears in top-right corner

## QUALITY OBSERVATIONS
- Smooth 60fps animation throughout
- Consistent visual hierarchy maintained
```

---

## Token Usage & Cost

| Mode | Typical Frames | Est. Input Tokens | Est. Cost |
|------|----------------|-------------------|-----------|
| `low` | 20-60 | ~20,000 | ~$0.002 |
| `auto` | 40-120 | ~50,000 | ~$0.005 |
| `high` | 90-150 | ~150,000 | ~$0.05+ |

**Cost Control Tips:**
1. Start with `low` to see if deeper analysis is needed
2. `high` mode is automatically limited to 5 seconds to control costs
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
