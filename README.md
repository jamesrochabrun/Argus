# Argus MCP - Video Analysis Server

A high-performance MCP (Model Context Protocol) server for video analysis using OpenAI's Vision API. Argus extracts frames from videos and analyzes them with GPT-4o-mini.

## Requirements

- macOS 14.0+
- Swift 6.0+
- OpenAI API key

## Local Setup

```bash
# Clone
git clone https://github.com/jamesrochabrun/Argus.git
cd Argus

# Build
swift build
```

The binaries will be at:
- `.build/debug/argus-mcp` - Main MCP server
- `.build/debug/argus-select` - Visual region selector

### Configure Claude Code

Add to `~/.claude.json` under the `mcpServers` key:

```json
{
  "mcpServers": {
    "argus": {
      "type": "stdio",
      "command": "/path/to/Argus/.build/debug/argus-mcp",
      "env": {
        "OPENAI_API_KEY": "sk-your-openai-api-key"
      }
    }
  }
}
```

---

## Analysis Modes

| Mode | Description | FPS | Max Frames | Resolution | Est. Cost |
|------|-------------|-----|------------|------------|-----------|
| `low` | Fast overview, quick summary | 0.5 | 15 | 512px | ~$0.001 |
| `auto` | Balanced detail, good for most tasks | 1.0 | 30 | 1024px | ~$0.003 |
| `high` | Comprehensive frame-by-frame analysis | 30.0 | 120 | 1920px | ~$0.05+ |

### Choosing the Right Mode

- **`low`**: Quick summary of what's in the video
- **`auto`**: Default choice - explains what happens step-by-step
- **`high`**: Catches everything - animations, bugs, accessibility issues

---

## Available Tools

| Tool | Description | Required |
|------|-------------|----------|
| `analyze_video` | Analyze a video file with specified mode | `video_path` |
| `record_and_analyze` | Record screen, then analyze | `mode` |
| `select_record_and_analyze` | Select region + record + analyze | `mode` |

All tools support optional `duration_seconds` (max 30s) and `custom_prompt` parameters.

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

**When to use:** Frame-by-frame analysis for animations, bugs, accessibility. Keep recordings short (1-3 seconds).

```
Record my screen for 2 seconds and analyze with mode high
```

**Output:**
```
## Video Analysis Results

### Video Information
- Duration: 2.0 seconds
- Resolution: 1170x2532
- Frames Analyzed: 60

### Summary
Modal presentation with spring animation. Found 1 animation issue and 2 accessibility concerns.

### Detailed Frame Analysis
**[0.00s - 0.17s]** (Frames 1-10)
## ANIMATIONS
- Animation begins with ease-out curve
- Frame 1: Modal at y=2532 (off-screen)
- Frame 10: Modal at y=1266 (50% visible)

**[0.17s - 0.33s]** (Frames 11-20)
- Spring overshoot detected - characteristic bounce
- Frame 18: Modal at y=-42 (slight overshoot)

**[0.33s - 0.50s]** (Frames 21-30)
- Frame 24-25 shows 8px jump (possible dropped frame)

## ACCESSIBILITY
1. **Insufficient Contrast**: Light gray text on white background
2. **Small Touch Target**: Close button ~30x30pt (needs 44x44pt)
```

---

## Token Usage & Cost

| Mode | Frames | Est. Input Tokens | Est. Cost |
|------|--------|-------------------|-----------|
| `low` | 2 | ~1,500 | ~$0.001 |
| `auto` | 3 | ~2,500 | ~$0.003 |
| `high` | 90 | ~90,000 | ~$0.05+ |

**Cost Control Tips:**
1. Start with `low` to see if deeper analysis is needed
2. For `high` mode, keep recordings under 3 seconds
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
2. Enable for Terminal or your IDE

---

## Known Issues

- **External monitors not supported**: Currently only records the main display. External/secondary monitors are not captured.

---

## License

MIT
