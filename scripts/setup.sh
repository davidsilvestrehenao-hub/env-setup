#!/bin/bash
# Simplified Environment Setup Script v1.0
# Comprehensive development environment setup with AI tools

set -euo pipefail

# Script configuration
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.yaml}"

# Auto-detect CPU cores and set intelligent defaults
detECT_CPU_CORES() {
    if command -v nproc >/dev/null 2>&1;
 then
        nproc
    elif command -v sysctl >/dev/null 2>&1;
 then
        sysctl -n hw.ncpu 2>/dev/null || echo "1"
    else
        echo "1"
    fi
}

# Get CPU core count
CPU_CORES=$(detect_cpu_cores)

# Set intelligent defaults based on CPU cores
# Leave 1 core free for system tasks, but ensure at least 1 job
BREW_JOBS_DEFAULT=$((CPU_CORES > 1 ? CPU_CORES - 1 : 1))
CASK_JOBS_DEFAULT=$((CPU_CORES > 2 ? (CPU_CORES + 1) / 2 : 1))

# Concurrency settings with auto-tuned defaults
MAX_BREW_JOBS="${MAX_BREW_JOBS:-$BREW_JOBS_DEFAULT}"
MAX_CASK_JOBS="${MAX_CASK_JOBS:-$CASK_JOBS_DEFAULT}"

# Color codes (will be loaded from config)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log() {
    local level="$1"
    shift
    local message="$*"
    # Simple logging without timestamp (timestamp handled by common.sh log function)
    
    # Use config colors if available, fallback to defaults
    local red="${UI_RED:-$RED}"
    local green="${UI_GREEN:-$GREEN}"
    local yellow="${UI_YELLOW:-$YELLOW}"
    local blue="${UI_BLUE:-$BLUE}"
    local nc="${UI_NC:-$NC}"
    
    case "$level" in
        "INFO")  echo -e "${blue}[INFO]${nc} $message" ;;
        "WARN")  echo -e "${yellow}[WARN]${nc} $message" ;;
        "ERROR") echo -e "${red}[ERROR]${nc} $message" ;;
        "SUCCESS") echo -e "${green}[SUCCESS]${nc} $message" ;;
    esac
}

# Progress tracking variables
TOTAL_PACKAGES=0
COMPLETED_PACKAGES=0
START_TIME=0
PACKAGE_TIMES=()
PROGRESS_FILE=""
SUMMARY_FILE=""

# Progress indicator with ETA
SHOW_PROGRESS() {
    local current="$1"
    local total="$2"
    local package_name="$3"
    local percentage=$((current * 100 / total))
    local bar_length=50
    local filled_length=$((percentage * bar_length / 100))
    local bar=""
    
    # Create progress bar using config characters
    local filled_char="${PROGRESS_FILLED:-█}"
    local empty_char="${PROGRESS_EMPTY:-░}"
    
    for ((i=0; i<filled_length; i++)); do
        bar+="$filled_char"
    done
    for ((i=filled_length; i<bar_length; i++)); do
        bar+="$empty_char"
    done
    
    # Calculate ETA
    local elapsed_time=$(($(date +%s) - START_TIME))
    local eta=""
    if [ "$current" -gt 0 ] && [ "$elapsed_time" -gt 0 ]; then
        local avg_time_per_package=$((elapsed_time / current))
        local remaining_packages=$((total - current))
        local estimated_remaining=$((remaining_packages * avg_time_per_package))
        eta=" (ETA: ${estimated_remaining}s)"
    fi
    
    printf "\r[%s] %d%% (%d/%d)%s - %s" "$bar" "$percentage" "$current" "$total" "$eta" "$package_name"
}

# Format time duration
FORMAT_DURATION() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        local minutes=$((seconds / 60))
        local remaining_seconds=$((seconds % 60))
        echo "${minutes}m ${remaining_seconds}s"
    else
        local hours=$((seconds / 3600))
        local minutes=$(((seconds % 3600) / 60))
        echo "${hours}h ${minutes}m"
    fi
}

# Check if command exists
COMMAND_EXISTS() {
    command -v "$1" >/dev/null 2>&1
}

# Count total packages for categories being processed
COUNT_TOTAL_PACKAGES() {
    local total=0
    local categories=()
    
    # Determine which categories to process
    if [ -n "$ONLY_CATEGORY" ]; then
        categories=("$ONLY_CATEGORY")
    else
        categories=("core" "frontend" "backend" "business" "ai")
    fi
    
    # Collect all packages and deduplicate
    local all_packages=()
    
    for category in "${categories[@]}"; do
        # Get brew packages for this category
        local brew_packages
        brew_packages=$(yq eval ".packages.$category.brew[] // []" "$CONFIG_FILE" 2>/dev/null | grep -v "^[]$" | tr -d ' ')
        if [ -n "$brew_packages" ]; then
            while IFS= read -r package; do
                if [ -n "$package" ]; then
                    all_packages+=("$package")
                fi
            done <<< "$brew_packages"
        fi
        
        # Get cask packages for this category
        local cask_packages
        cask_packages=$(yq eval ".packages.$category.cask[] // []" "$CONFIG_FILE" 2>/dev/null | grep -v "^[]$" | tr -d ' ')
        if [ -n "$cask_packages" ]; then
            while IFS= read -r package; do
                if [ -n "$package" ]; then
                    all_packages+=("$package")
                fi
            done <<< "$cask_packages"
        fi
    done
    
    # Remove duplicates and count
    if [ ${#all_packages[@]} -gt 0 ]; then
        # Sort and get unique packages
        local unique_packages
        IFS=$'\n' read -d '' -r -a unique_packages < <(printf '%s\n' "${all_packages[@]}" | sort -u)
        total=${#unique_packages[@]}
    fi
    
    echo "$total"
}

# Initialize progress tracking
INIT_PROGRESS() {
    TOTAL_PACKAGES=$(count_total_packages)
    # Progress tracking variables (used in progress functions)
    # shellcheck disable=SC2034 # COMPLETED_PACKAGES is used in progress tracking
    COMPLETED_PACKAGES=0
    START_TIME=$(date +%s)
    # shellcheck disable=SC2034 # PACKAGE_TIMES is used in progress tracking
    PACKAGE_TIMES=()
    PROGRESS_FILE="/tmp/setup_progress_$$"
    SUMMARY_FILE="/tmp/setup_summary_$$"
    echo "0" > "$PROGRESS_FILE"
    touch "$SUMMARY_FILE"
    
    if [ "$TOTAL_PACKAGES" -gt 0 ]; then
        log "INFO" "Total packages to process: $TOTAL_PACKAGES"
    fi
}

# Show final summary
SHOW_SUMMARY() {
        local end_time
        end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))
    
    # Count actual processed packages from summary file (remove duplicates)
    local actual_processed=0
    if [ -f "$SUMMARY_FILE" ]; then
        # Remove duplicates and count unique packages
        actual_processed=$(sort "$SUMMARY_FILE" | uniq | wc -l | tr -d ' ')
    fi
    
    echo ""
    log "INFO" "Installation Summary:"
    log "INFO" "Total time: $(format_duration $total_duration)"
    log "INFO" "Packages processed: $actual_processed/$TOTAL_PACKAGES"
    
    # Count different statuses
    local installed_count=0
    local updated_count=0
    local skipped_count=0
    local errored_count=0
    
    if [ -f "$SUMMARY_FILE" ]; then
        # Use deduplicated file for counting
        local dedup_file
        dedup_file=$(mktemp)
        sort "$SUMMARY_FILE" | uniq > "$dedup_file"
        
        installed_count=$(grep -c "^installed:" "$dedup_file" 2>/dev/null || echo "0")
        updated_count=$(grep -c "^updated:" "$dedup_file" 2>/dev/null || echo "0")
        skipped_count=$(grep -c "^skipped:" "$dedup_file" 2>/dev/null || echo "0")
        errored_count=$(grep -c "^errored:" "$dedup_file" 2>/dev/null || echo "0")
        
        rm -f "$dedup_file"
    fi
    
    # Ensure counts are numeric and handle any whitespace
    installed_count=$(echo "$installed_count" | tr -d ' ' | head -1)
    updated_count=$(echo "$updated_count" | tr -d ' ' | head -1)
    skipped_count=$(echo "$skipped_count" | tr -d ' ' | head -1)
    errored_count=$(echo "$errored_count" | tr -d ' ' | head -1)
    
    # Convert to integers safely
    installed_count=$((installed_count + 0))
    updated_count=$((updated_count + 0))
    skipped_count=$((skipped_count + 0))
    errored_count=$((errored_count + 0))
    
    echo ""
    log "INFO" "Package Status Breakdown:"
    if [ $installed_count -gt 0 ]; then
        log "SUCCESS" "  ✅ Newly installed: $installed_count"
    fi
    if [ $updated_count -gt 0 ]; then
        log "INFO" "  🔄 Updated: $updated_count"
    fi
    if [ $skipped_count -gt 0 ]; then
        log "INFO" "  ⏭️  Already up to date: $skipped_count"
    fi
    if [ $errored_count -gt 0 ]; then
        log "WARN" "  ❌ Failed: $errored_count"
    fi
    
    # Show total breakdown
    local total_processed=$((installed_count + updated_count + skipped_count + errored_count))
    if [ $total_processed -gt 0 ]; then
        echo ""
        log "INFO" "Total: $total_processed packages ($installed_count installed, $updated_count updated, $skipped_count skipped, $errored_count failed)"
    fi
    
    # Clean up temporary files
    rm -f "$PROGRESS_FILE" "$SUMMARY_FILE" 2>/dev/null || true
}

# Parse arguments
DRY_RUN=false
ONLY_CATEGORY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;i
        --only)
            ONLY_CATEGORY="$2"
            shift 2
            ;;i
        --help)
            echo "Usage: $0 [--dry-run] [--only CATEGORY]"
            echo "Categories: core, frontend, backend, business"
            exit 0
            ;;i
        *)
            log "ERROR" "Unknown option: $1"
            exit 1
            ;;i
    esac
done

# Install Homebrew if not present
INSTALL_HOMEBREW() {
    if command_exists brew;
 then
        log "INFO" "Homebrew already installed"
        return 0
    fi
    
    log "INFO" "Installing Homebrew..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "INFO" "DRY RUN: Would install Homebrew"
        return 0
    fi
    
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # Add to PATH for Apple Silicon
    if [[ "$(uname -m)" == "arm64" ]]; then
        local brew_path="${HOMEBREW_APPLE_SILICON:-/opt/homebrew/bin/brew}"
        echo "eval \"$($brew_path shellenv)\"" >> ~/.zshrc
        eval "$($brew_path shellenv)"
    else
        local brew_path="${HOMEBREW_INTEL:-/usr/local/bin/brew}"
        echo "eval \"$($brew_path shellenv)\"" >> ~/.zshrc
        eval "$($brew_path shellenv)"
    fi
    
    log "SUCCESS" "Homebrew installed"
}

# Install packages from YAML config
INSTALL_PACKAGES() {
    local category="$1"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log "ERROR" "Config file not found: $CONFIG_FILE"
        return 1
    fi
    
    if ! command_exists yq;
 then
        log "ERROR" "yq is required but not installed"
        return 1
    fi
    
    log "INFO" "Installing packages for category: $category"
    
    # Install brew packages
    local brew_packages
    brew_packages=$(yq eval ".packages.$category.brew[] // []" "$CONFIG_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/^[] *$//')
    
    if [ -n "$brew_packages" ] && [ "$brew_packages" != " " ] && [ "$brew_packages" != "[]" ]; then
        log "INFO" "Brew packages: $brew_packages"
        
        if [ "$DRY_RUN" = "true" ]; then
            log "INFO" "DRY RUN: Would install brew packages: $brew_packages"
        else
            # Process packages in parallel
            local pids=()
            local max_jobs=$MAX_BREW_JOBS
            
            for package in $brew_packages;
 do
                if [ -n "$package" ]; then
                    # Wait if we've hit the job limit
                    while [ ${#pids[@]} -ge "$max_jobs" ]; do
                        for i in "${!pids[@]}"; do
                            if ! kill -0 "${pids[$i]}" 2>/dev/null;
 then
                                unset "pids[$i]"
                            fi
                        done
                        sleep 0.1
                    done
                    
                    # Start package installation in background
                    (
                        local package_start_time
                        package_start_time=$(date +%s)
                        local status=""
                        
                        if brew list "$package" >/dev/null 2>&1;
 then
                            status="already_installed"
                        else
                            if brew install "$package" >/dev/null 2>&1;
 then
                                status="installed"
                            else
                                status="failed"
                            fi
                        fi
                        
                        local package_end_time
                        package_end_time=$(date +%s)
                        local package_duration=$((package_end_time - package_start_time))
                        
                        # Update progress atomically
                        local current_progress
                        current_progress=$(cat "$PROGRESS_FILE" 2>/dev/null || echo "0")
                        current_progress=$((current_progress + 1))
                        echo "$current_progress" > "$PROGRESS_FILE"
                        
                        # Show progress
                        show_progress $current_progress "$TOTAL_PACKAGES" "$package"
                        echo ""  # New line after progress
                        
                        # Record status in summary file and log result with timing
                        case $status in
                            "already_installed")
                                # Check if package already recorded to avoid duplicates
                                if ! grep -q "^skipped:$package$" "$SUMMARY_FILE" 2>/dev/null;
 then
                                    echo "skipped:$package" >> "$SUMMARY_FILE"
                                fi
                                log "INFO" "$package: already installed and up to date ($(format_duration $package_duration))"
                                ;;i
                            "installed")
                                # Check if package already recorded to avoid duplicates
                                if ! grep -q "^installed:$package$" "$SUMMARY_FILE" 2>/dev/null;
 then
                                    echo "installed:$package" >> "$SUMMARY_FILE"
                                fi
                                log "SUCCESS" "$package installed ($(format_duration $package_duration))"
                                ;;i
                            "failed")
                                # Check if package already recorded to avoid duplicates
                                if ! grep -q "^errored:$package$" "$SUMMARY_FILE" 2>/dev/null;
 then
                                    echo "errored:$package" >> "$SUMMARY_FILE"
                                fi
                                log "WARN" "$package installation failed ($(format_duration $package_duration))"
                                ;;i
                        esac
                    ) &
                    pids+=($!)
                fi
            done
            
            # Wait for all background jobs to complete
            for pid in "${pids[@]}"; do
                wait "$pid"
            done
        fi
    fi
    
    # Install cask packages
    local cask_packages
    cask_packages=$(yq eval ".packages.$category.cask[] // []" "$CONFIG_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/^[] *$//')
    
    if [ -n "$cask_packages" ] && [ "$cask_packages" != " " ] && [ "$cask_packages" != "[]" ]; then
        log "INFO" "Cask packages: $cask_packages"
        
        if [ "$DRY_RUN" = "true" ]; then
            log "INFO" "DRY RUN: Would install cask packages: $cask_packages"
        else
            # Process cask packages in parallel
            local cask_pids=()
            local max_cask_jobs=$MAX_CASK_JOBS
            
            for package in $cask_packages;
 do
                if [ -n "$package" ]; then
                    # Wait if we've hit the job limit
                    while [ ${#cask_pids[@]} -ge "$max_cask_jobs" ]; do
                        for i in "${!cask_pids[@]}"; do
                            if ! kill -0 "${cask_pids[$i]}" 2>/dev/null;
 then
                                unset "cask_pids[$i]"
                            fi
                        done
                        sleep 0.1
                    done
                    
                    # Start cask installation in background
                    (
                        local package_start_time
                        package_start_time=$(date +%s)
                        local status=""
                        
                        if brew list --cask "$package" >/dev/null 2>&1;
 then
                            status="already_installed"
                        else
                            if brew install --cask "$package" >/dev/null 2>&1;
 then
                                status="installed"
                            else
                                status="failed"
                            fi
                        fi
                        
                        local package_end_time
                        package_end_time=$(date +%s)
                        local package_duration=$((package_end_time - package_start_time))
                        
                        # Update progress atomically
                        local current_progress
                        current_progress=$(cat "$PROGRESS_FILE" 2>/dev/null || echo "0")
                        current_progress=$((current_progress + 1))
                        echo "$current_progress" > "$PROGRESS_FILE"
                        
                        # Show progress
                        show_progress $current_progress "$TOTAL_PACKAGES" "$package"
                        echo ""  # New line after progress
                        
                        # Record status in summary file and log result with timing
                        case $status in
                            "already_installed")
                                # Check if package already recorded to avoid duplicates
                                if ! grep -q "^skipped:$package$" "$SUMMARY_FILE" 2>/dev/null;
 then
                                    echo "skipped:$package" >> "$SUMMARY_FILE"
                                fi
                                log "INFO" "$package: already installed and up to date ($(format_duration $package_duration))"
                                ;;i
                            "installed")
                                # Check if package already recorded to avoid duplicates
                                if ! grep -q "^installed:$package$" "$SUMMARY_FILE" 2>/dev/null;
 then
                                    echo "installed:$package" >> "$SUMMARY_FILE"
                                fi
                                log "SUCCESS" "$package installed ($(format_duration $package_duration))"
                                ;;i
                            "failed")
                                # Check if package already recorded to avoid duplicates
                                if ! grep -q "^errored:$package$" "$SUMMARY_FILE" 2>/dev/null;
 then
                                    echo "errored:$package" >> "$SUMMARY_FILE"
                                fi
                                log "WARN" "$package installation failed ($(format_duration $package_duration))"
                                ;;i
                        esac
                    ) &
                    cask_pids+=($!)
                fi
            done
            
            # Wait for all background cask jobs to complete
            for pid in "${cask_pids[@]}"; do
                wait "$pid"
            done
        fi
    fi
}

# Install pipx packages from YAML config
INSTALL_PIPX_PACKAGES() {
    if ! command_exists pipx;
 then
        log "WARN" "pipx not found, skipping installation of Python packages."
        return 1
    fi

    if ! command_exists yq;
 then
        log "ERROR" "yq is required but not installed"
        return 1
    fi

    log "INFO" "Installing pipx packages..."

    local pipx_packages
    pipx_packages=$(yq eval '.ai_python_packages[] // []' "$CONFIG_FILE" 2>/dev/null | tr '\n' ' ')

    if [ -n "$pipx_packages" ]; then
        log "INFO" "pipx packages: $pipx_packages"

        if [ "$DRY_RUN" = "true" ]; then
            log "INFO" "DRY RUN: Would install pipx packages: $pipx_packages"
        else
            for package in $pipx_packages;
 do
                if [ -n "$package" ]; then
                    log "INFO" "Installing $package with pipx..."
                    if pipx install "$package" >/dev/null 2>&1;
 then
                        log "SUCCESS" "$package installed"
                    else
                        log "WARN" "$package installation failed"
                    fi
                fi
            done
        fi
    fi
}

# Main function
MAIN() {
    log "INFO" "Starting Environment Setup v1.0"
    log "INFO" "Detected $CPU_CORES CPU cores - using $MAX_BREW_JOBS brew jobs, $MAX_CASK_JOBS cask jobs"

    # Bootstrap: Install Homebrew and yq if not present
    install_homebrew
    if ! command -v yq >/dev/null 2>&1;
 then
        log "INFO" "Bootstrapping: yq not found, installing..."
        brew install yq
    fi
    
    # Initialize progress tracking
    init_progress
    
    # Install packages
    if [ -n "$ONLY_CATEGORY" ]; then
        log "INFO" "Installing only category: $ONLY_CATEGORY"
        install_packages "$ONLY_CATEGORY"
    else
        # Install all categories
        local categories=("core" "frontend" "backend" "business" "ai")
        for category in "${categories[@]}"; do
            install_packages "$category"
        done
    fi

    # Install pipx packages
    install_pipx_packages
    
    # Configure shell environment
    if [ "$DRY_RUN" = "false" ]; then
        log "INFO" "Configuring shell environment..."
        
        # Load shell configuration from YAML
        SHELL_PLUGIN_MANAGER=$(yq eval '.shell.plugin_manager // "zinit"' "$CONFIG_FILE")
        SHELL_THEME=$(yq eval '.shell.theme // "powerlevel10k"' "$CONFIG_FILE")
        SHELL_THEME_STYLE=$(yq eval '.shell.theme_style // "rainbow"' "$CONFIG_FILE")
        
        # Load Oh My Zsh plugins if using oh-my-zsh
        if [ "$SHELL_PLUGIN_MANAGER" = "oh-my-zsh" ]; then
            SHELL_OH_MY_ZSH_PLUGINS=$(yq eval '.shell.oh_my_zsh_plugins[] // []' "$CONFIG_FILE" 2>/dev/null | tr -d ' ' | grep -v '^$' || echo "")
            log "INFO" "Loaded Oh My Zsh plugins: ${SHELL_OH_MY_ZSH_PLUGINS:-none}"
        fi
        
        source "$SCRIPT_DIR/lib/shell.sh"
        configure_shell
        configure_terminals
        test_terminal_config
        
        # Configure dotfiles and system settings
        log "INFO" "Configuring dotfiles and system settings..."
        source "$SCRIPT_DIR/lib/dotfiles.sh"
        configure_dotfiles
        
        # Setup SSH for GitHub
        log "INFO" "Setting up SSH for GitHub..."
        if [ -f "$SCRIPT_DIR/ssh-setup.sh" ]; then
            "$SCRIPT_DIR/ssh-setup.sh" auth
        else
            log "WARN" "SSH setup script not found"
        fi
        
        # Setup GPG for Git signing
        log "INFO" "Setting up GPG for Git signing..."
        if [ -f "$SCRIPT_DIR/gpg-setup.sh" ]; then
            "$SCRIPT_DIR/gpg-setup.sh"
        else
            log "WARN" "GPG setup script not found"
        fi
    else
        log "INFO" "DRY RUN: Would configure shell environment"
        log "INFO" "DRY RUN: Would configure dotfiles and system settings"
        log "INFO" "DRY RUN: Would setup SSH for GitHub"
        log "INFO" "DRY RUN: Would setup GPG for Git signing"
    fi
    
    log "SUCCESS" "Setup completed!"
    
    # Show final summary
    show_summary
    
    if [ "$DRY_RUN" = "true" ]; then
        log "INFO" "This was a dry run. No changes were made."
    else
        echo ""
        echo "✅ Installation complete!"
    echo "💡 Next steps:"
    echo "  1. Restart your terminal or run: source ~/.zshrc"
    echo "  2. Check status: make services-status"
    echo "  3. View docs: open docs/quickstart/README.md"
    echo "  4. Enjoy your beautiful terminal with Starship prompt! ✨"
    echo ""
    echo "✅ SSH key uploaded to GitHub - Git operations ready!"
    echo ""
    
    # Show services status
    echo "🔍 Checking services status..."
    if command -v make >/dev/null 2>&1 && [ -f "Makefile" ]; then
        make services-status 2>/dev/null || echo "   (No services currently running)"
    else
        echo "   (Make not available or no Makefile found)"
    fi
    echo ""
    
    # Generate and open comprehensive README
    echo "📚 Generating comprehensive documentation..."
    if [ -f "scripts/generate-csv-readme.sh" ]; then
        ./scripts/generate-csv-readme.sh >/dev/null 2>&1 && echo "✅ Documentation generated successfully!"
    else
        echo "⚠️  README generator not found"
    fi
    
    # Open the generated comprehensive documentation
    echo "📖 Opening comprehensive documentation..."
    echo "   Current directory: $(pwd)"
    
    # Use config filename
    local docs_filename="${DOCS_OUTPUT_FILENAME:-ENVIRONMENT_SETUP_COMPLETE}"
    local markdown_file="docs/${docs_filename}.md"
    local html_file="docs/${docs_filename}.html"
    
    echo "   File exists: $([ -f "$markdown_file" ] && echo "Yes" || echo "No")"
    
    # Convert Markdown to HTML for proper browser rendering
    if command -v pandoc >/dev/null 2>&1;
 then
        echo "   Converting Markdown to HTML for browser rendering..."
        local css_styles="${DOCS_CSS_STYLES:-body{font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,\"Helvetica Neue\",Arial,sans-serif;max-width:1200px;margin:0 auto;padding:20px;line-height:1.6}table{border-collapse:collapse;width:100%;margin:20px 0}th,td{border:1px solid #ddd;padding:12px;text-align:left}th{background-color:#f2f2f2;font-weight:600}tr:nth-child(even){background-color:#f9f9f9}th[data-sortable="true"]:hover{background-color:#e0e0e0;cursor:pointer}}"
        pandoc "$markdown_file" -o "$html_file" --standalone --css=<(echo "$css_styles") 2>/dev/null
        HTML_FILE="$html_file"
    else
        echo "   (Pandoc not available - opening raw Markdown)"
        HTML_FILE="$markdown_file"
    fi
    
    if command -v open >/dev/null 2>&1;
 then
        # Open HTML file in default browser for interactive tables
        if [ -f "$HTML_FILE" ]; then
            echo "   Opening HTML version in default browser for interactive tables..."
            if open "$HTML_FILE"; then
                echo "✅ Package catalog opened in default browser (interactive tables)"
            else
                echo "   (Could not open HTML in browser)"
            fi
        fi
        
        # Also open Markdown file in default macOS application (VS Code)
        if [ -f "docs/ENVIRONMENT_SETUP_COMPLETE.md" ]; then
            echo "   Opening Markdown version in VS Code for editing..."
            if open "docs/ENVIRONMENT_SETUP_COMPLETE.md"; then
                echo "✅ Environment setup documentation opened in VS Code (editable Markdown)"
            else
                echo "   (Could not open Markdown file)"
            fi
        fi
    else
        echo "   (Open command not available)"
    fi
    fi
}

# Run main function
main "$@"