#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== chuk_chat Flatpak Build Script ===${NC}"

# Check if flatpak-builder is installed
if ! command -v flatpak-builder &> /dev/null; then
    echo -e "${RED}Error: flatpak-builder not found${NC}"
    echo "Install with: sudo apt install flatpak-builder"
    exit 1
fi

# Check if Freedesktop runtime is installed
if ! flatpak list --runtime | grep -q "org.freedesktop.Platform.*23.08"; then
    echo -e "${YELLOW}Installing Freedesktop runtime 23.08...${NC}"
    flatpak install -y flathub org.freedesktop.Platform//23.08 org.freedesktop.Sdk//23.08
fi

# Load environment variables if .env exists
if [ -f .env ]; then
    echo -e "${GREEN}Loading .env file...${NC}"
    export $(grep -v '^#' .env | xargs)
else
    echo -e "${YELLOW}Warning: .env file not found. Building without Supabase credentials.${NC}"
    echo "The app will need credentials configured at runtime."
fi

# Clean previous build
echo -e "${GREEN}Cleaning previous build...${NC}"
rm -rf build-dir .flatpak-builder

# Build the Flatpak
echo -e "${GREEN}Building Flatpak...${NC}"
flatpak-builder --force-clean --ccache \
    --repo=repo \
    build-dir \
    dev.chuk.chat.yml

# Create single-file bundle (optional, for distribution)
if [ "$1" == "--bundle" ]; then
    echo -e "${GREEN}Creating single-file bundle...${NC}"
    flatpak build-bundle repo chuk_chat.flatpak dev.chuk.chat
    echo -e "${GREEN}Bundle created: chuk_chat.flatpak${NC}"
    echo "Install with: flatpak install chuk_chat.flatpak"
fi

# Install locally (optional)
if [ "$1" == "--install" ]; then
    echo -e "${GREEN}Installing locally...${NC}"
    flatpak --user remote-add --if-not-exists --no-gpg-verify chuk-chat-repo repo
    flatpak --user install -y chuk-chat-repo dev.chuk.chat
    echo -e "${GREEN}Installed! Run with: flatpak run dev.chuk.chat${NC}"
fi

echo -e "${GREEN}Build complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Test:    flatpak-builder --run build-dir dev.chuk.chat.yml chuk_chat_launcher.sh"
echo "  2. Install: ./build_flatpak.sh --install"
echo "  3. Bundle:  ./build_flatpak.sh --bundle"
