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

Argus supports 6 analysis modes, each optimized for different use cases:

| Mode | FPS | Max Frames | Resolution | Batch Size | Image Detail | Tokens/Batch | Best For |
|------|-----|------------|------------|------------|--------------|--------------|----------|
| `quick_look` | 0.5 | 15 | 512px | 8 | low | 500 | Fast overview, getting the gist |
| `explain` | 1.0 | 30 | 1024px | 5 | auto | 1500 | Detailed step-by-step explanation |
| `test_animation` | 60.0 | 180 | 1024px | 10 | high | 2000 | QA testing animations at 60fps |
| `find_bugs` | 2.0 | 60 | 1920px | 5 | high | 1500 | Finding visual glitches & UI issues |
| `accessibility` | 1.0 | 30 | 1920px | 5 | high | 1500 | Checking contrast, text size, touch targets |
| `compare_frames` | 30.0 | 120 | 1280px | 6 | high | 2000 | Pixel-level comparison between frames |

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
| `quick_look` | 2 | 1 | ~1,500 | ~200 | ~$0.001 |
| `explain` | 3 | 1 | ~2,500 | ~600 | ~$0.002 |
| `find_bugs` | 6 | 2 | ~8,000 | ~1,200 | ~$0.006 |
| `accessibility` | 3 | 1 | ~4,000 | ~800 | ~$0.003 |
| `test_animation` | 180 | 18 | ~120,000 | ~12,000 | ~$0.08 |
| `compare_frames` | 90 | 15 | ~90,000 | ~10,000 | ~$0.06 |

#### Token Usage Disclaimers

**🔴 High Token Usage Modes:**

- **`test_animation`**: Captures at 60fps and can send up to **180 frames** per analysis. Each frame is a base64 JPEG image (~85 tokens per image at 1024px). For a 3-second recording, expect **~120,000 input tokens**.

- **`compare_frames`**: Captures at 30fps with up to **120 frames**. Designed for detailed pixel comparison, uses high-detail image mode. Expect **~90,000 input tokens** for a 4-second video.

**🟡 Medium Token Usage Modes:**

- **`find_bugs`**: Captures at 2fps with high resolution (1920px). More tokens per image due to larger size. Expect **~8,000-15,000 input tokens** for typical recordings.

- **`accessibility`**: Similar to find_bugs but fewer frames. Expect **~4,000-8,000 input tokens**.

**🟢 Low Token Usage Modes:**

- **`quick_look`**: Minimal frames (0.5fps), low resolution (512px), low detail mode. Most economical option. Expect **~1,500-3,000 input tokens**.

- **`explain`**: Balanced approach with 1fps and auto detail. Expect **~2,500-5,000 input tokens**.

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
| "What's in this video?" | `quick_look` | Cheapest, fastest |
| "Explain the user flow" | `explain` | Good balance |
| "Check for visual bugs" | `find_bugs` | Worth the extra tokens for bug detection |
| "Test this animation" | `test_animation` | **Use only when you need frame-by-frame analysis** |
| "Is this accessible?" | `accessibility` | Focused analysis, reasonable cost |
| "What changed between states?" | `compare_frames` | **Use for short clips only (1-2 seconds)** |

#### Cost Control Tips

1. **Start with `quick_look`** - Use it first to see if deeper analysis is needed
2. **Limit recording duration** - For `test_animation`, keep recordings under 3 seconds
3. **Use region selection** - Record only the specific UI component, not full screen
4. **Custom `max_frames`** - Override default with lower values: `max_frames: 30`

---

## Mode Examples

### 1. `quick_look` - Fast Overview

**When to use:** You want a quick summary of what happens in a video without detailed analysis.

**Example prompt:**
```
Analyze the video at /path/to/demo.mp4 with mode quick_look
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

### 2. `explain` - Detailed Explanation

**When to use:** You need a thorough, educational breakdown of everything that happens.

**Example prompt:**
```
Analyze the video at /path/to/tutorial.mp4 with mode explain
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

### 3. `test_animation` - Animation QA Testing

**When to use:** You're testing UI animations and need frame-by-frame analysis of timing, smoothness, and easing curves.

**Example prompt:**
```
Record the Simulator for 2 seconds and analyze with mode test_animation
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
- Frames Analyzed: 120
- Batches Processed: 12
- Total Tokens Used: 18432
- Extraction Time: 1.24 seconds
- Analysis Time: 24.56 seconds

### Summary
Modal presentation animation with spring physics. Generally smooth with one
minor timing inconsistency detected.

### Detailed Frame Analysis
**[0.00s - 0.17s]** (Frames 1-10)
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
ISSUE: Overshoot of 42px may be intentional spring effect

**[0.33s - 0.50s]** (Frames 21-30)
TIMING: Damping phase of spring animation
CONSISTENCY: ⚠️ Frame 24-25 shows 8px jump (possible dropped frame)
- Frame 21: Modal at y=8
- Frame 25: Modal at y=0 (final position)
END STATE: Modal correctly positioned at y=0

### Issues Found
1. **Frame 24-25**: Possible dropped frame causing 8px position jump
   - Severity: Minor
   - Location: During spring damping phase
   - Recommendation: Check for main thread blocking during this transition
```

---

### 4. `find_bugs` - Visual Bug Detection

**When to use:** QA testing to find visual glitches, layout issues, or rendering problems.

**Example prompt:**
```
Select a region, record for 5 seconds, and find bugs
```

**Expected output:**
```
## Video Analysis Results

### Video Information
- Duration: 5.0 seconds
- Resolution: 800x600
- FPS: 30.0
- Total Frames: 150

### Analysis Statistics
- Frames Analyzed: 10
- Batches Processed: 2
- Total Tokens Used: 2156
- Extraction Time: 0.67 seconds
- Analysis Time: 5.89 seconds

### Summary
Found 3 visual issues in the analyzed screen region.

### Detailed Frame Analysis
**[0.0s - 2.5s]**
BUG #1 - TEXT TRUNCATION
- Location: Navigation bar title
- Frame: 2 (0.5s)
- Issue: Title "Shopping Cart Items" truncated to "Shopping Cart It..."
- Expected: Full title or proper ellipsis placement
- Severity: Medium

BUG #2 - LAYOUT OVERLAP
- Location: Bottom sheet, lower-right corner
- Frames: 3-6 (1.0s - 2.0s)
- Issue: "Apply Coupon" button overlaps with price total label by 12px
- Cause: Likely missing bottom padding on button container
- Severity: High

**[2.5s - 5.0s]**
BUG #3 - Z-INDEX ISSUE
- Location: Dropdown menu
- Frame: 8 (3.5s)
- Issue: Dropdown renders behind the floating action button
- Expected: Dropdown should appear above all other elements
- Severity: High

### Summary of Issues
| # | Type | Location | Severity |
|---|------|----------|----------|
| 1 | Text Truncation | Nav bar title | Medium |
| 2 | Layout Overlap | Bottom sheet | High |
| 3 | Z-Index | Dropdown menu | High |
```

---

### 5. `accessibility` - Accessibility Audit

**When to use:** Checking if your UI meets accessibility guidelines (contrast, text size, touch targets).

**Example prompt:**
```
Analyze /path/to/app-screenshot.mp4 with mode accessibility
```

**Expected output:**
```
## Video Analysis Results

### Video Information
- Duration: 3.0 seconds
- Resolution: 1170x2532
- FPS: 60.0
- Total Frames: 180

### Analysis Statistics
- Frames Analyzed: 3
- Batches Processed: 1
- Total Tokens Used: 1834
- Extraction Time: 0.41 seconds
- Analysis Time: 4.23 seconds

### Summary
Found 4 accessibility concerns that should be addressed.

### Detailed Frame Analysis
**[0.0s - 3.0s]**

#### TEXT ISSUES
1. **Insufficient Contrast**
   - Location: Gray placeholder text in search field
   - Issue: Light gray (#999) on white background fails WCAG AA
   - Current ratio: ~2.8:1
   - Required: 4.5:1 minimum
   - Fix: Use #767676 or darker

2. **Small Text Size**
   - Location: Footer links ("Terms", "Privacy", "Help")
   - Issue: Text appears to be ~10pt, below recommended 12pt minimum
   - Fix: Increase to at least 12pt (16px)

#### TOUCH TARGET ISSUES
3. **Small Touch Target**
   - Location: "X" close button (top-right of modal)
   - Issue: Button appears to be ~30x30pt
   - Required: 44x44pt minimum per Apple HIG
   - Fix: Increase tap area with padding or larger hit area

#### COLOR ISSUES
4. **Color-Only Indicator**
   - Location: Required field indicators
   - Issue: Required fields marked only with red asterisk (*)
   - Problem: Users with color blindness may not distinguish
   - Fix: Add text label "Required" or additional visual indicator

### Accessibility Score: 6/10
Recommended priority: Fix contrast and touch target issues first.
```

---

### 6. `compare_frames` - Frame Comparison

**When to use:** You need precise pixel-level differences between consecutive frames (debugging state changes, transitions).

**Example prompt:**
```
Analyze the video at /path/to/state-change.mp4 with mode compare_frames
```

**Expected output:**
```
## Video Analysis Results

### Video Information
- Duration: 1.0 seconds
- Resolution: 1920x1080
- FPS: 30.0
- Total Frames: 30

### Analysis Statistics
- Frames Analyzed: 30
- Batches Processed: 5
- Total Tokens Used: 8934
- Extraction Time: 0.38 seconds
- Analysis Time: 12.67 seconds

### Summary
Detected button state transition with color change, scale animation, and label update.

### Detailed Frame Analysis
**[0.00s - 0.20s]** (Frames 1-6)
POSITION CHANGES:
- Button container: No movement (centered at x=960, y=540)

SIZE CHANGES:
- Frame 1→2: Button scale 1.0 → 0.95 (press-down effect)
- Frame 3→4: Button scale 0.95 → 1.0 (release)

OPACITY/COLOR:
- Frame 1: Button background #007AFF (blue)
- Frame 2: Button background #0056B3 (darker blue - pressed state)
- Frame 3: Button background #007AFF (returning to normal)

**[0.20s - 0.40s]** (Frames 7-12)
POSITION CHANGES:
- Checkmark icon: Appears at center of button
- Frame 7: Checkmark at scale 0
- Frame 12: Checkmark at scale 1.0 (pop-in animation)

VISIBILITY:
- "Submit" label: Fades out (opacity 1.0 → 0.0)
- Checkmark icon: Fades in (opacity 0.0 → 1.0)

COLOR:
- Frame 7→12: Button transitions #007AFF → #34C759 (blue to green)

**[0.40s - 0.60s]** (Frames 13-18)
STATE CHANGES:
- Button now shows checkmark icon
- Color stabilized at #34C759 (success green)
- All animations complete

MEASUREMENTS:
- Total color transition: 6 frames (0.2s)
- Checkmark scale animation: 5 frames (0.17s)
- Label crossfade: 4 frames (0.13s)
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

### Testing an Animation in iOS Simulator

```
You: "Record the Simulator for 3 seconds and test the animation"

Claude: [Calls record_simulator_and_analyze with mode=test_animation]
        [Records at 60fps for 3 seconds]
        [Extracts up to 180 frames]
        [Sends to OpenAI in batches of 10]
        [Returns detailed animation analysis]
```

### Quick Check of a Video File

```
You: "Give me a quick summary of /path/to/demo.mp4"

Claude: [Calls analyze_video with mode=quick_look]
        [Extracts 15 frames at 0.5fps]
        [Single API call with 8 images]
        [Returns brief summary]
```

### Testing a Specific UI Component

```
You: "Let me select a region to test for bugs"

Claude: [Calls select_record_and_analyze]
        [Opens visual selector overlay]
You:    [Drag to select the component area]
Claude: [Records selected region for specified duration]
        [Analyzes with find_bugs mode]
        [Returns bug report]
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
