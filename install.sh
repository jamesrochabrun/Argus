#!/bin/bash
set -e

# Argus MCP Server Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/jamesrochabrun/Argus/main/install.sh | sh

REPO="jamesrochabrun/Argus"
INSTALL_DIR="$HOME/.local/bin"
BINARY_NAME="argus"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    error "Argus only supports macOS"
fi

info "Installing Argus MCP Server..."

# Check for ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    warn "ffmpeg not found (required for video processing)"
    echo ""
    echo "Install with: brew install ffmpeg"
    echo ""
fi

# Get latest release URL
info "Fetching latest release..."
LATEST_URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | grep "browser_download_url.*argus-macos-universal.tar.gz\"" | cut -d '"' -f 4)

if [[ -z "$LATEST_URL" ]]; then
    error "Could not find latest release. Please check https://github.com/$REPO/releases"
fi

# Create install directory
mkdir -p "$INSTALL_DIR"

# Download and extract
info "Downloading from $LATEST_URL..."
TEMP_DIR=$(mktemp -d)
curl -sL "$LATEST_URL" -o "$TEMP_DIR/argus.tar.gz"
tar -xzf "$TEMP_DIR/argus.tar.gz" -C "$TEMP_DIR"

# Remove old binaries if they exist (migration from 3-binary to single binary)
for old_binary in "argus-mcp" "argus-select" "argus-status"; do
    if [[ -f "$INSTALL_DIR/$old_binary" ]]; then
        info "Removing old $old_binary binary..."
        rm -f "$INSTALL_DIR/$old_binary"
    fi
done

# Install binary
mv "$TEMP_DIR/$BINARY_NAME" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/$BINARY_NAME"

# Cleanup
rm -rf "$TEMP_DIR"

success "Installed $BINARY_NAME to $INSTALL_DIR/"

# Check if install dir is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "$INSTALL_DIR is not in your PATH"
    echo ""
    echo "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
    echo ""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# Claude configuration
echo ""
info "Claude Code Configuration"
echo ""
echo "Add this to ~/.claude.json:"
echo ""
echo -e "${GREEN}{
  \"mcpServers\": {
    \"argus\": {
      \"type\": \"stdio\",
      \"command\": \"$INSTALL_DIR/$BINARY_NAME\",
      \"args\": [\"mcp\"],
      \"env\": {
        \"OPENAI_API_KEY\": \"YOUR_OPENAI_API_KEY\"
      }
    }
  }
}${NC}"
echo ""
warn "Replace YOUR_OPENAI_API_KEY with your actual key"
info "Get your API key at: https://platform.openai.com/api-keys"
echo ""
success "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Install ffmpeg if not already: brew install ffmpeg"
echo "  2. Add the config above to ~/.claude.json"
echo "  3. Restart Claude Code"
echo "  4. Try: analyze_video or design_from_video"
