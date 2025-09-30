#!/bin/bash

# =============================================================================
# Populate Zoxide Database with Home Directory
# =============================================================================
# This script finds all directories under ~ and adds them to zoxide
# for better directory navigation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if zoxide is installed
if ! command -v zoxide &> /dev/null; then
    print_error "zoxide is not installed. Please install it first."
    exit 1
fi

print_status "Starting zoxide database population..."

# Get home directory
HOME_DIR="$HOME"
print_status "Scanning directories under: $HOME_DIR"

# Counter for statistics
total_dirs=0
added_dirs=0
skipped_dirs=0

# Directories to exclude (common system/hidden directories)
EXCLUDE_DIRS=(
    ".Trash"
    ".cache"
    ".config"
    ".local/share/Trash"
    ".npm"
    ".yarn"
    ".cargo/registry"
    ".rustup"
    "Library/Caches"
    "Library/Application Support"
    "Library/Logs"
    "Library/Preferences"
    "Library/Saved Application State"
    "Library/WebKit"
    "Library/Containers"
    "Library/Group Containers"
    "Library/Developer/Xcode/DerivedData"
    "Library/Developer/Xcode/Archives"
    "Library/Developer/Xcode/iOS DeviceSupport"
    "Library/Developer/Xcode/UserData"
    "node_modules"
    ".git"
    ".vscode"
    ".idea"
    "venv"
    "env"
    ".venv"
    ".env"
    "__pycache__"
    ".pytest_cache"
    "target"
    "build"
    "dist"
    ".next"
    ".nuxt"
    ".output"
    ".vuepress/dist"
    "coverage"
    ".nyc_output"
    ".nyc_output"
    ".coverage"
    "htmlcov"
    ".tox"
    ".mypy_cache"
    ".ruff_cache"
    ".black"
    ".isort"
    ".bandit"
    ".safety"
    ".pytest_cache"
    ".hypothesis"
    ".mypy_cache"
    ".ruff_cache"
    ".black"
    ".isort"
    ".bandit"
    ".safety"
    ".pytest_cache"
    ".hypothesis"
)

# Function to check if directory should be excluded
should_exclude() {
    local dir="$1"
    local basename=$(basename "$dir")
    
    # Check if it's a hidden directory (starts with .)
    if [[ "$basename" =~ ^\..* ]]; then
        return 0
    fi
    
    # Check against exclude list
    for exclude in "${EXCLUDE_DIRS[@]}"; do
        if [[ "$dir" == *"$exclude"* ]]; then
            return 0
        fi
    done
    
    return 1
}

# Function to add directory to zoxide
add_directory() {
    local dir="$1"
    
    if should_exclude "$dir"; then
        ((skipped_dirs++))
        return 0
    fi
    
    # Check if directory is accessible and readable
    if [ -r "$dir" ] && [ -x "$dir" ]; then
        if zoxide add "$dir" 2>/dev/null; then
            ((added_dirs++))
            print_success "Added: $dir"
        else
            ((skipped_dirs++))
            print_warning "Failed to add: $dir"
        fi
    else
        ((skipped_dirs++))
        print_warning "Skipped (not accessible): $dir"
    fi
}

print_status "Finding all directories under $HOME_DIR..."

# Find all directories and process them
while IFS= read -r -d '' dir; do
    ((total_dirs++))
    add_directory "$dir"
done < <(find "$HOME_DIR" -type d -print0 2>/dev/null)

# Print statistics
echo
print_status "=== POPULATION COMPLETE ==="
print_success "Total directories found: $total_dirs"
print_success "Directories added to zoxide: $added_dirs"
print_warning "Directories skipped: $skipped_dirs"

# Show current zoxide database size
current_size=$(zoxide query --list | wc -l)
print_status "Current zoxide database size: $current_size directories"

# Show some examples of what was added
echo
print_status "Sample of directories now available:"
zoxide query --list --score | head -10

echo
print_success "Zoxide database populated successfully!"
print_status "You can now use 'z <directory_name>' to navigate to any directory under your home folder."
print_status "Use 'z' (without arguments) for interactive directory selection."

