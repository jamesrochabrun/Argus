#!/bin/bash
set -e

# Argus MCP Server Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/jamesrochabrun/Argus/main/install.sh | sh

REPO="jamesrochabrun/Argus"
INSTALL_DIR="$HOME/.local/bin"
BINARY_NAME="argus-mcp"
SELECT_BINARY="argus-select"

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
    error "Argus only supports macOS (uses ScreenCaptureKit for screen recording)"
fi

info "Installing Argus MCP Server..."

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

# Install binaries
mv "$TEMP_DIR/$BINARY_NAME" "$INSTALL_DIR/"
mv "$TEMP_DIR/$SELECT_BINARY" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/$BINARY_NAME"
chmod +x "$INSTALL_DIR/$SELECT_BINARY"

# Cleanup
rm -rf "$TEMP_DIR"

success "Installed $BINARY_NAME to $INSTALL_DIR/"
success "Installed $SELECT_BINARY to $INSTALL_DIR/"

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
CLAUDE_CONFIG="$HOME/.claude.json"
echo ""
info "Claude Code Configuration"
echo ""

if [[ -f "$CLAUDE_CONFIG" ]]; then
    info "Found existing ~/.claude.json"
else
    info "No ~/.claude.json found"
fi

echo "To use Argus with Claude Code, add this to your ~/.claude.json:"
echo ""
echo -e "${GREEN}{
  \"mcpServers\": {
    \"argus\": {
      \"type\": \"stdio\",
      \"command\": \"$INSTALL_DIR/$BINARY_NAME\",
      \"env\": {
        \"OPENAI_API_KEY\": \"YOUR_OPENAI_API_KEY\"
      }
    }
  }
}${NC}"
echo ""
warn "Remember to replace YOUR_OPENAI_API_KEY with your actual OpenAI API key"
echo ""
info "Get your API key at: https://platform.openai.com/api-keys"
echo ""
success "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Add the configuration above to ~/.claude.json"
echo "  2. Restart Claude Code"
echo "  3. Use: record_and_analyze, select_record_and_analyze, or analyze_video"
