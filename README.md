# Argus MCP - Video Analysis Server

A high-performance MCP (Model Context Protocol) server for video analysis using OpenAI's Vision API. Argus extracts frames from videos and sends them in batches to GPT-4o-mini for detailed analysis.

## Features

- **Video Analysis**: Extract frames from any video file and analyze them using OpenAI's Vision API
- **Screen Recording**: Record your screen using ScreenCaptureKit (macOS 14+)
- **Visual Region Selection**: Interactive crosshair overlay to select specific screen regions
- **Intent-Based Modes**: Pre-configured analysis modes for different use cases (animations, bugs, accessibility)
- **App-Specific Recording**: Record specific applications like iOS Simulator
- **Batch Processing**: Efficiently process frames in batches to minimize API calls

## Requirements

- macOS 14.0+
- Swift 6.0+
- OpenAI API key

## Installation

### Build from Source

```bash
git clone https://github.com/jamesrochabrun/Argus.git
cd Argus
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

Argus supports 3 simple quality-based modes:

| Mode | Description | FPS | Max Frames | Resolution | Est. Cost |
|------|-------------|-----|------------|------------|-----------|
| `low` | Fast overview, quick summary | 0.5 | 15 | 512px | ~$0.001 |
| `medium` | Balanced detail, good for most tasks | 1.0 | 30 | 1024px | ~$0.003 |
| `high` | Comprehensive frame-by-frame analysis | 30.0 | 120 | 1920px | ~$0.05+ |

### Choosing the Right Mode

- **`low`**: Use when you just need a quick summary of what's in the video
- **`medium`**: Default choice for most tasks - explains what happens step-by-step
- **`high`**: Use when you need to catch everything - animations, bugs, and accessibility issues combined

### How It Works

1. **Frame Extraction**: Video is sampled at the specified FPS
2. **Batching**: Frames are grouped (e.g., 10 frames per batch for animations)
3. **API Calls**: Each batch is sent to OpenAI Vision as base64 images
4. **Analysis**: GPT-4o-mini analyzes using mode-specific prompts
5. **Report**: Results are combined into a structured report

### Token Usage & Cost Estimation

> **⚠️ IMPORTANT: Token usage varies dramatically between modes. Choose the right mode for your use case to avoid unexpected costs.**

#### Token Usage by Mode (3-second video example)

| Mode | Frames Sent | API Calls | Est. Input Tokens | Est. Output Tokens | Est. Cost |
|------|-------------|-----------|-------------------|-------------------|-----------|
| `low` | 2 | 1 | ~1,500 | ~200 | ~$0.001 |
| `medium` | 3 | 1 | ~2,500 | ~600 | ~$0.003 |
| `high` | 90 | 18 | ~90,000 | ~12,000 | ~$0.05+ |

#### Token Usage by Mode

**🔴 `high` mode (⚠️ significantly higher cost):**
- Captures at 30fps with up to **120 frames**
- High-detail image mode at full resolution (1920px)
- Comprehensive analysis: animations + bugs + accessibility
- Expect **~90,000+ input tokens** for longer recordings
- **Use for short clips (1-3 seconds) when you need to catch everything**

**🟡 `medium` mode:**
- Balanced approach with 1fps and auto detail (1024px)
- Good for understanding what happens step-by-step
- Expect **~2,500-5,000 input tokens**
- **Default choice for most use cases**

**🟢 `low` mode:**
- Minimal frames (0.5fps), low resolution (512px)
- Most economical option
- Expect **~1,500-3,000 input tokens**
- **Use for quick checks or when cost is a priority**

#### How Image Tokens Are Calculated

OpenAI Vision API charges tokens based on image size and detail level:

| Detail Level | Approximate Tokens per Image |
|--------------|------------------------------|
| `low` | ~85 tokens (fixed) |
| `auto` | ~85-1,105 tokens (varies) |
| `high` | ~1,105+ tokens (scales with resolution) |

**Formula for `high` detail:**
```
tokens = 85 + (170 × number_of_512px_tiles)
```

For a 1024×1024 image at high detail: `85 + (170 × 4) = 765 tokens`
For a 1920×1080 image at high detail: `85 + (170 × 8) = 1,445 tokens`

#### Recommendations

| Use Case | Recommended Mode | Why |
|----------|------------------|-----|
| "What's in this video?" | `low` | Cheapest, fastest |
| "Explain the user flow" | `medium` | Good balance of detail and cost |
| "Test animation + find bugs" | `high` | Comprehensive analysis (keep recording short!) |

#### Cost Control Tips

1. **Start with `low`** - Use it first to see if deeper analysis is needed
2. **Limit recording duration** - For `high` mode, keep recordings under 3 seconds
3. **Use region selection** - Record only the specific UI component, not full screen
4. **Custom `max_frames`** - Override default with lower values: `max_frames: 30`

---

## Mode Examples

### 1. `low` - Fast Overview

**When to use:** You want a quick summary of what happens in a video without detailed analysis.

**Example prompt:**
```
Analyze the video at /path/to/demo.mp4 with mode low
```

**Expected output:**
```
## Video Analysis Results

### Video Information
- Duration: 12.5 seconds
- Resolution: 1920x1080
- FPS: 30.0
- Total Frames: 375

### Analysis Statistics
- Frames Analyzed: 6
- Batches Processed: 1
- Total Tokens Used: 423
- Extraction Time: 0.34 seconds
- Analysis Time: 2.15 seconds

### Summary
The video shows a mobile app login flow. A user enters credentials, taps the
login button, sees a loading spinner, and is taken to a home dashboard.

### Detailed Frame Analysis
**[0.0s - 12.0s]**
The recording captures a login screen with email and password fields. The user
types credentials, taps a blue "Sign In" button, a circular spinner appears
briefly, then the screen transitions to a dashboard showing user statistics.
```

---

### 2. `medium` - Balanced Analysis

**When to use:** You need a thorough explanation of everything that happens - the default for most tasks.

**Example prompt:**
```
Analyze the video at /path/to/tutorial.mp4 with mode medium
```

**Expected output:**
```
## Video Analysis Results

### Video Information
- Duration: 8.2 seconds
- Resolution: 1170x2532
- FPS: 60.0
- Total Frames: 492

### Analysis Statistics
- Frames Analyzed: 8
- Batches Processed: 2
- Total Tokens Used: 2847
- Extraction Time: 0.52 seconds
- Analysis Time: 6.34 seconds

### Summary
This video demonstrates the checkout flow in an e-commerce iOS app, showing
cart review, payment method selection, and order confirmation.

### Detailed Frame Analysis
**[0.0s - 4.0s]**
1. The screen displays a shopping cart with 3 items listed vertically
2. Each item shows: product thumbnail (left), name and size (center), price (right)
3. A "Subtotal: $127.99" label appears at the bottom
4. The user taps a green "Checkout" button
5. A slide-up animation reveals the payment selection sheet

**[4.0s - 8.2s]**
1. The payment sheet shows 3 options: Apple Pay, Credit Card, PayPal
2. User selects Apple Pay (checkmark appears)
3. Face ID prompt appears briefly
4. Success animation: green checkmark with confetti particles
5. Order confirmation screen shows order #48291 with estimated delivery
```

---

### 3. `high` - Comprehensive Analysis

**When to use:** You need frame-by-frame analysis for animations, bug detection, and accessibility - all in one. Keep recordings short (1-3 seconds) due to higher cost.

**Example prompt:**
```
Record the Simulator for 2 seconds and analyze with mode high
```

**Expected output:**
```
## Video Analysis Results

### Video Information
- Duration: 2.0 seconds
- Resolution: 1170x2532
- FPS: 60.0
- Total Frames: 120

### Analysis Statistics
- Frames Analyzed: 60
- Batches Processed: 12
- Total Tokens Used: 18432
- Extraction Time: 1.24 seconds
- Analysis Time: 24.56 seconds

### Summary
Modal presentation animation with spring physics. Found 1 animation issue and 2 accessibility concerns.

### Detailed Frame Analysis
**[0.00s - 0.17s]** (Frames 1-10)

## ANIMATIONS
TIMING: Animation begins with ease-out curve
SMOOTHNESS: All frames present, no drops detected
- Frame 1: Modal at y=2532 (off-screen)
- Frame 5: Modal at y=1899 (25% visible)
- Frame 10: Modal at y=1266 (50% visible)
Velocity: Consistent deceleration observed

**[0.17s - 0.33s]** (Frames 11-20)
TIMING: Spring overshoot detected - characteristic bounce
SMOOTHNESS: Smooth interpolation between frames
- Frame 15: Modal at y=633 (75% visible)
- Frame 18: Modal at y=-42 (slight overshoot past target)
- Frame 20: Modal at y=12 (bouncing back)

**[0.33s - 0.50s]** (Frames 21-30)
TIMING: Damping phase of spring animation
⚠️ ANIMATION ISSUE: Frame 24-25 shows 8px jump (possible dropped frame)
- Frame 21: Modal at y=8
- Frame 25: Modal at y=0 (final position)
END STATE: Modal correctly positioned at y=0

## VISUAL BUGS
No visual bugs detected.

## ACCESSIBILITY
1. **Insufficient Contrast**
   - Location: Modal header subtitle
   - Issue: Light gray text on white background
   - Fix: Use darker gray (#767676 or darker)

2. **Small Touch Target**
   - Location: Close button (X) in modal header
   - Issue: Appears to be ~30x30pt
   - Required: 44x44pt minimum
   - Fix: Increase tap area

### Issues Summary
| # | Category | Issue | Severity |
|---|----------|-------|----------|
| 1 | Animation | Dropped frame at 0.4s | Minor |
| 2 | Accessibility | Contrast issue | Medium |
| 3 | Accessibility | Small touch target | Medium |
```

---

## Available Tools

| Tool | Description |
|------|-------------|
| `analyze_video` | Analyze a video file with specified mode |
| `record_and_analyze` | Record screen for N seconds, then analyze |
| `record_simulator_and_analyze` | Record iOS Simulator + analyze |
| `record_app_and_analyze` | Record any app window + analyze |
| `select_record_and_analyze` | Select region + record + analyze |

---

## Example Workflows

### Comprehensive Analysis of iOS Simulator

```
You: "Record the Simulator for 2 seconds with high mode"

Claude: [Asks: "Which analysis mode?"]
        - low: Fast overview (~$0.001)
        - medium: Balanced detail (~$0.003)
        - high: Comprehensive analysis (~$0.05+)
You:    [Select "high"]
Claude: [Calls record_simulator_and_analyze with mode=high]
        [Records at 60fps for 2 seconds]
        [Extracts up to 60 frames at 30fps]
        [Returns comprehensive analysis: animations + bugs + accessibility]
```

### Quick Check of a Video File

```
You: "Give me a quick summary of /path/to/demo.mp4"

Claude: [Calls analyze_video with mode=low]
        [Extracts 15 frames at 0.5fps]
        [Single API call with 8 images]
        [Returns brief summary]
```

### Testing a Specific UI Component

```
You: "Let me select a region to test"

Claude: [Calls select_record_and_analyze]
        [Opens visual selector overlay]
You:    [Drag to select the component area]
Claude: [Asks: "Which analysis mode?"]
You:    [Select mode based on need]
Claude: [Records selected region]
        [Analyzes with chosen mode]
        [Returns analysis report]
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Claude Code / Desktop                    │
└───────────────────────────┬─────────────────────────────────┘
                            │ MCP Protocol (stdio)
┌───────────────────────────▼─────────────────────────────────┐
│                      argus-mcp                               │
├──────────────┬──────────────┬──────────────┬────────────────┤
│    Screen    │    Video     │    Video     │    Region      │
│   Recorder   │   Extractor  │   Analyzer   │   Selector     │
│ (ScreenKit)  │(AVFoundation)│  (OpenAI)    │ (argus-select) │
└──────────────┴──────────────┴──────┬───────┴────────────────┘
                                     │
                            ┌────────▼────────┐
                            │  OpenAI Vision  │
                            │   GPT-4o-mini   │
                            └─────────────────┘
```

---

## Permissions

Screen recording requires permissions:
1. System Preferences → Privacy & Security → Screen Recording
2. Enable for Terminal or your IDE

---

## License

MIT
