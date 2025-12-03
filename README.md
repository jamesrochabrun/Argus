# Argus MCP - Video Analysis Server

A high-performance MCP (Model Context Protocol) server for video analysis using OpenAI's Vision API. Argus extracts frames from videos and sends them in batches to GPT-4o for detailed analysis.

## Features

- **Video Analysis**: Extract frames from any video file and analyze them using OpenAI's Vision API
- **Screen Recording**: Record your screen using ScreenCaptureKit (macOS 14+)
- **Batch Processing**: Efficiently process frames in batches to minimize API calls
- **Configurable Quality**: Choose between fast, default, and detailed analysis modes
- **Custom Prompts**: Provide custom system prompts for specialized analysis

## Requirements

- macOS 14.0+
- Swift 6.0+
- OpenAI API key

## Installation

### Build from Source

```bash
swift build -c release
```

The binary will be at `.build/release/argus-mcp`.

### Configure Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "argus": {
      "command": "/path/to/argus-mcp",
      "env": {
        "OPENAI_API_KEY": "sk-your-openai-api-key"
      }
    }
  }
}
```

### Configure Claude Code

Add to `.claude/mcp.json` in your project:

```json
{
  "mcpServers": {
    "argus": {
      "command": "/path/to/argus-mcp",
      "env": {
        "OPENAI_API_KEY": "sk-your-openai-api-key"
      }
    }
  }
}
```

## Available Tools

### `analyze_video`

Analyze a video file by extracting frames and sending them to OpenAI's Vision API.

**Parameters:**
- `video_path` (required): Absolute path to the video file
- `frames_per_second`: Number of frames to extract per second (default: 1.0)
- `max_frames`: Maximum number of frames to extract (default: 30)
- `quality`: Analysis quality - `fast`, `default`, or `detailed`
- `custom_prompt`: Optional custom system prompt for analysis

**Example:**
```
Analyze the video at /Users/me/recording.mp4 with detailed quality
```

### `start_screen_recording`

Start recording the screen using ScreenCaptureKit.

**Parameters:**
- `output_path`: Optional path for the output video file
- `width`: Recording width in pixels (default: 1920)
- `height`: Recording height in pixels (default: 1080)
- `fps`: Frames per second (default: 30)
- `quality`: Recording quality - `low`, `medium`, or `high`

### `stop_screen_recording`

Stop the current screen recording and save the video file.

### `list_displays`

List all available displays for screen recording.

### `list_windows`

List all available windows for screen recording.

### `record_and_analyze`

Record the screen for a specified duration and automatically analyze the recording.

**Parameters:**
- `duration_seconds` (required): Duration to record in seconds
- `analysis_quality`: Analysis quality - `fast`, `default`, or `detailed`
- `custom_prompt`: Optional custom system prompt for analysis

**Example:**
```
Record my screen for 10 seconds and analyze what happens
```

## Quality Presets

### Fast
- 0.5 frames per second
- Max 15 frames
- 512px width
- Low detail analysis

### Default
- 1 frame per second
- Max 30 frames
- 1024px width
- Auto detail analysis

### Detailed
- 2 frames per second
- Max 60 frames
- 1920px width
- High detail analysis

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    MCP Client                           │
│                (Claude Desktop/Code)                    │
└─────────────────────┬───────────────────────────────────┘
                      │ MCP Protocol (stdio)
┌─────────────────────▼───────────────────────────────────┐
│                  Argus MCP Server                       │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │   Screen    │  │    Video    │  │     Video       │  │
│  │  Recorder   │  │   Frame     │  │    Analyzer     │  │
│  │             │  │  Extractor  │  │                 │  │
│  └──────┬──────┘  └──────┬──────┘  └────────┬────────┘  │
│         │                │                  │           │
│         │    AVFoundation/ScreenCaptureKit  │           │
│         │                │                  │           │
│         └────────────────┼──────────────────┘           │
│                          │                              │
└──────────────────────────┼──────────────────────────────┘
                           │ OpenAI Vision API
┌──────────────────────────▼──────────────────────────────┐
│                     GPT-4o                              │
│              (Vision Analysis)                          │
└─────────────────────────────────────────────────────────┘
```

## Performance Considerations

- **Frame Extraction**: Uses AVFoundation with Metal-accelerated JPEG compression
- **Batch Processing**: Frames are sent in configurable batches (default: 5 frames per batch)
- **Sequential API Calls**: Batches are processed sequentially to avoid rate limits
- **Memory Efficient**: Frames are encoded as base64 JPEG to minimize memory usage

## Permissions

The screen recording feature requires screen recording permissions:
1. Go to System Preferences > Privacy & Security > Screen Recording
2. Enable permission for your terminal or the application running the MCP server

## License

MIT
