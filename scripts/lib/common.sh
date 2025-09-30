#!/bin/bash
# Common utility functions for environment setup

# Only set strict mode if not already set
if [ -z "${BASH_STRICT_MODE:-}" ]; then
    set -euo pipefail
    BASH_STRICT_MODE=1
fi

# Color codes for output
if [ -z "${RED:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    # shellcheck disable=SC2034 # CYAN is used for color formatting
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
fi

# Logging functions
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "DEBUG") echo -e "${PURPLE}[DEBUG]${NC} $message" ;;
        "INFO")  echo -e "${BLUE}[INFO]${NC} $message" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
    esac
    
    # Also log to file if LOG_FILE is set
    if [ -n "${LOG_FILE:-}" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

# Error handling
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Retry function with exponential backoff
retry() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local command="$*"
    
    local attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if eval "$command"; then
            return 0
        fi
        
        if [ "$attempt" -lt "$max_attempts" ]; then
            log "WARN" "Command failed (attempt $attempt/$max_attempts). Retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        fi
        
        attempt=$((attempt + 1))
    done
    
    log "ERROR" "Command failed after $max_attempts attempts: $command"
    return 1
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if port is in use
port_in_use() {
    local port="$1"
    lsof -i ":$port" >/dev/null 2>&1
}

# Find next available port
find_free_port() {
    local start_port="$1"
    local port=$start_port
    
    while port_in_use "$port"; do
        port=$((port + 1))
    done
    
    echo "$port"
}

# Atomic file write
atomic_write() {
    local file="$1"
    local content="$2"
    local tmp_file
    tmp_file=$(mktemp)
    
    echo "$content" > "$tmp_file"
    mv "$tmp_file" "$file"
}

# Append to file only if line doesn't exist
append_if_missing() {
    local file="$1"
    local line="$2"
    
    if [ ! -f "$file" ] || ! grep -Fxq "$line" "$file"; then
        echo "$line" >> "$file"
        return 0
    fi
    return 1
}

# Check if running on Apple Silicon
is_apple_silicon() {
    [ "$(uname -m)" = "arm64" ]
}

# Check if Rosetta is installed (for Intel apps on Apple Silicon)
has_rosetta() {
    command_exists arch && arch -x86_64 /usr/bin/true >/dev/null 2>&1
}

# Get available disk space in GB
get_disk_space() {
    df -h . | awk 'NR==2 {print $4}' | sed 's/G//'
}

# Check if we have enough disk space (in GB)
has_disk_space() {
    local required_gb="$1"
    local available_gb
    available_gb=$(get_disk_space | sed 's/G//')
    
    [ "$available_gb" -ge "$required_gb" ]
}

# Preflight checks
preflight_checks() {
    log "INFO" "Running preflight checks..."
    
    # Check OS
    if [[ "$OSTYPE" != "darwin"* ]]; then
        error_exit "This script is designed for macOS only"
    fi
    
    # Check architecture
    if is_apple_silicon; then
        log "INFO" "Running on Apple Silicon (ARM64)"
        if ! has_rosetta; then
            log "WARN" "Rosetta not installed. Some Intel-only apps may not work."
        fi
    else
        log "INFO" "Running on Intel (x86_64)"
    fi
    
    # Check disk space
    if ! has_disk_space 10; then
        log "WARN" "Less than 10GB disk space available. Installation may fail."
    fi
    
    # Check network connectivity
    if ! ping -c 1 github.com >/dev/null 2>&1; then
        log "WARN" "Network check to github.com failed. Some downloads may fail."
    fi
    
    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        error_exit "Do not run this script as root"
    fi
    
    log "SUCCESS" "Preflight checks completed"
}

# Postflight health checks
postflight_checks() {
    log "INFO" "Running postflight health checks..."
    
    local failed_checks=0
    
    # Check critical commands
    local critical_commands=("git" "node" "docker" "brew")
    for cmd in "${critical_commands[@]}"; do
        if command_exists "$cmd"; then
            log "SUCCESS" "$cmd: $(command -v "$cmd")"
        else
            log "ERROR" "$cmd: not found"
            failed_checks=$((failed_checks + 1))
        fi
    done
    
    # Check Docker if installed
    if command_exists docker; then
        if docker info >/dev/null 2>&1; then
            log "SUCCESS" "Docker: running"
        else
            log "WARN" "Docker: installed but not running"
        fi
    fi
    
    # Check database clients
    local db_commands=("psql" "mongosh" "redis-cli")
    for cmd in "${db_commands[@]}"; do
        if command_exists "$cmd"; then
            log "SUCCESS" "$cmd: available"
        else
            log "WARN" "$cmd: not found"
        fi
    done
    
    # Check Ollama if installed
    if command_exists ollama; then
        local model_count
        model_count=$(ollama list 2>/dev/null | wc -l | tr -d ' ')
        log "SUCCESS" "Ollama: $model_count models installed"
    fi
    
    if [ $failed_checks -gt 0 ]; then
        log "WARN" "$failed_checks critical checks failed"
        return 1
    else
        log "SUCCESS" "All health checks passed"
        return 0
    fi
}

# Load configuration
load_config() {
    local config_file="${1:-config.yaml}"
    
    if [ ! -f "$config_file" ]; then
        error_exit "Configuration file not found: $config_file"
    fi
    
    # Check if yq is available for YAML parsing
    if ! command_exists yq; then
        log "WARN" "yq not found. Some advanced features may not work."
        return 1
    fi
    
    # Export config variables
    export CONFIG_FILE="$config_file"
    
    # Core settings
    LOG_LEVEL=$(yq eval '.config.log_level // "info"' "$config_file")
    export LOG_LEVEL
    PARALLEL_JOBS=$(yq eval '.config.parallel_jobs // 3' "$config_file")
    export PARALLEL_JOBS
    RETRY_ATTEMPTS=$(yq eval '.config.retry_attempts // 3' "$config_file")
    export RETRY_ATTEMPTS
    RETRY_DELAY=$(yq eval '.config.retry_delay // 2' "$config_file")
    export RETRY_DELAY
    TIMEOUT_SECONDS=$(yq eval '.config.timeout_seconds // 300' "$config_file")
    export TIMEOUT_SECONDS
    
    # Privacy settings
    DISABLE_ANALYTICS=$(yq eval '.config.disable_analytics // true' "$config_file")
    export DISABLE_ANALYTICS
    DISABLE_TELEMETRY=$(yq eval '.config.disable_telemetry // true' "$config_file")
    export DISABLE_TELEMETRY
    
    # Performance settings
    CPU_DETECTION=$(yq eval '.config.cpu_detection // "auto"' "$config_file")
    export CPU_DETECTION
    BREW_JOB_LIMIT_FORMULA=$(yq eval '.config.brew_job_limit_formula // "cpu_cores - 1"' "$config_file")
    export BREW_JOB_LIMIT_FORMULA
    CASK_JOB_LIMIT_FORMULA=$(yq eval '.config.cask_job_limit_formula // "(cpu_cores + 1) / 2"' "$config_file")
    export CASK_JOB_LIMIT_FORMULA
    
    # Service configuration
    OLLAMA_HOST=$(yq eval '.config.services.ollama.host // "127.0.0.1"' "$config_file")
    export OLLAMA_HOST
    OLLAMA_PORT=$(yq eval '.config.services.ollama.port // 11434' "$config_file")
    export OLLAMA_PORT
    OLLAMA_MODELS_PATH=$(yq eval '.config.services.ollama.models_path // "$HOME/.ollama/models"' "$config_file")
    export OLLAMA_MODELS_PATH
    OLLAMA_KEEP_ALIVE=$(yq eval '.config.services.ollama.keep_alive // "5m"' "$config_file")
    export OLLAMA_KEEP_ALIVE
    
    LM_STUDIO_HOST=$(yq eval '.config.services.lm_studio.host // "127.0.0.1"' "$config_file")
    export LM_STUDIO_HOST
    LM_STUDIO_PORT=$(yq eval '.config.services.lm_studio.port // 1234' "$config_file")
    export LM_STUDIO_PORT
    LM_STUDIO_MODELS_PATH=$(yq eval '.config.services.lm_studio.models_path // "$HOME/.cache/lm-studio/models"' "$config_file")
    export LM_STUDIO_MODELS_PATH
    
    OPEN_WEBUI_HOST=$(yq eval '.config.services.open_webui.host // "127.0.0.1"' "$config_file")
    export OPEN_WEBUI_HOST
    OPEN_WEBUI_PORT=$(yq eval '.config.services.open_webui.port // 3000' "$config_file")
    export OPEN_WEBUI_PORT
    OPEN_WEBUI_DATABASE_URL=$(yq eval '.config.services.open_webui.database_url // "sqlite:///open-webui.db"' "$config_file")
    export OPEN_WEBUI_DATABASE_URL
    OPEN_WEBUI_JWT_SECRET=$(yq eval '.config.services.open_webui.jwt_secret // "your-secret-key-here"' "$config_file")
    if [ "$OPEN_WEBUI_JWT_SECRET" = "your-secret-key-here" ]; then
        log "INFO" "Generating new random secret for Open WebUI..."
        OPEN_WEBUI_JWT_SECRET=$(openssl rand -hex 32)
    fi
    export OPEN_WEBUI_JWT_SECRET
    
    POSTGRES_HOST=$(yq eval '.config.services.postgresql.host // "localhost"' "$config_file")
    export POSTGRES_HOST
    POSTGRES_PORT=$(yq eval '.config.services.postgresql.port // 5432' "$config_file")
    export POSTGRES_PORT
    POSTGRES_USER=$(yq eval '.config.services.postgresql.user // "postgres"' "$config_file")
    export POSTGRES_USER
    POSTGRES_DB=$(yq eval '.config.services.postgresql.database // "postgres"' "$config_file")
    export POSTGRES_DB
    
    MONGODB_HOST=$(yq eval '.config.services.mongodb.host // "localhost"' "$config_file")
    export MONGODB_HOST
    MONGODB_PORT=$(yq eval '.config.services.mongodb.port // 27017' "$config_file")
    export MONGODB_PORT
    MONGODB_URI=$(yq eval '.config.services.mongodb.uri // "mongodb://localhost:27017"' "$config_file")
    export MONGODB_URI
    
    REDIS_HOST=$(yq eval '.config.services.redis.host // "localhost"' "$config_file")
    export REDIS_HOST
    REDIS_PORT=$(yq eval '.config.services.redis.port // 6379' "$config_file")
    export REDIS_PORT
    REDIS_URL=$(yq eval '.config.services.redis.url // "redis://localhost:6379"' "$config_file")
    export REDIS_URL
    
    MYSQL_HOST=$(yq eval '.config.services.mysql.host // "localhost"' "$config_file")
    export MYSQL_HOST
    MYSQL_PORT=$(yq eval '.config.services.mysql.port // 3306' "$config_file")
    export MYSQL_PORT
    
    MINIO_HOST=$(yq eval '.config.services.minio.host // "localhost"' "$config_file")
    export MINIO_HOST
    MINIO_PORT=$(yq eval '.config.services.minio.port // 9000' "$config_file")
    export MINIO_PORT
    MINIO_DATA_PATH=$(yq eval '.config.services.minio.data_path // "$HOME/minio-data"' "$config_file")
    export MINIO_DATA_PATH
    
    GRAFANA_HOST=$(yq eval '.config.services.grafana.host // "localhost"' "$config_file")
    export GRAFANA_HOST
    GRAFANA_PORT=$(yq eval '.config.services.grafana.port // 3001' "$config_file")
    export GRAFANA_PORT
    
    PROMETHEUS_HOST=$(yq eval '.config.services.prometheus.host // "localhost"' "$config_file")
    export PROMETHEUS_HOST
    PROMETHEUS_PORT=$(yq eval '.config.services.prometheus.port // 9090' "$config_file")
    export PROMETHEUS_PORT
    
    # File paths
    DEV_HOME=$(yq eval '.config.paths.development_home // "$HOME/Development"' "$config_file")
    export DEV_HOME
    PROJECTS=$(yq eval '.config.paths.projects // "$HOME/Development/projects"' "$config_file")
    export PROJECTS
    DOTFILES=$(yq eval '.config.paths.dotfiles // "$HOME/Development/dotfiles"' "$config_file")
    export DOTFILES
    WORKSPACE=$(yq eval '.config.paths.workspace // "$HOME/Development/workspace"' "$config_file")
    export WORKSPACE
    SHELL_CONFIG_FILE=$(yq eval '.config.paths.shell_config // "$HOME/.zshrc"' "$config_file")
    export SHELL_CONFIG_FILE
    GIT_CONFIG_FILE=$(yq eval '.config.paths.git_config // "$HOME/.gitconfig"' "$config_file")
    export GIT_CONFIG_FILE
    SSH_CONFIG_FILE=$(yq eval '.config.paths.ssh_config // "$HOME/.ssh/config"' "$config_file")
    export SSH_CONFIG_FILE
    SSH_KEY_FILE=$(yq eval '.config.paths.ssh_key // "$HOME/.ssh/id_ed25519"' "$config_file")
    export SSH_KEY_FILE
    HOMEBREW_APPLE_SILICON=$(yq eval '.config.paths.homebrew_apple_silicon // "/opt/homebrew/bin/brew"' "$config_file")
    export HOMEBREW_APPLE_SILICON
    HOMEBREW_INTEL=$(yq eval '.config.paths.homebrew_intel // "/usr/local/bin/brew"' "$config_file")
    export HOMEBREW_INTEL
    
    # Environment variables
    LANG=$(yq eval '.config.environment.language // "en_US.UTF-8"' "$config_file")
    export LANG
    LC_ALL=$(yq eval '.config.environment.language // "en_US.UTF-8"' "$config_file")
    export LC_ALL
    TZ=$(yq eval '.config.environment.timezone // "America/New_York"' "$config_file")
    export TZ
    GIT_EDITOR=$(yq eval '.config.environment.git_editor // "code --wait"' "$config_file")
    export GIT_EDITOR
    BAT_THEME=$(yq eval '.config.environment.bat_theme // "DarkNeon"' "$config_file")
    export BAT_THEME
    FZF_DEFAULT_OPTS=$(yq eval '.config.environment.fzf_options // "--height 40% --layout=reverse --border"' "$config_file")
    export FZF_DEFAULT_OPTS
    FZF_CTRL_T_OPTS=$(yq eval '.config.environment.fzf_ctrl_t_options // "--preview '\''bat --color=always --style=header,grid --line-range :300 {}'\''"' "$config_file")
    export FZF_CTRL_T_OPTS
    FZF_ALT_C_OPTS=$(yq eval '.config.environment.fzf_alt_c_options // "--preview '\''eza --tree --color=always {}'\''"' "$config_file")
    export FZF_ALT_C_OPTS
    EXA_COLORS=$(yq eval '.config.environment.exa_colors // "di=34:ln=35:so=32:pi=33:ex=31:bd=46:cd=43:su=41:sg=46:tw=42:ow=43"' "$config_file")
    export EXA_COLORS
    HISTSIZE=$(yq eval '.config.environment.histsize // 10000' "$config_file")
    export HISTSIZE
    SAVEHIST=$(yq eval '.config.environment.savehist // 10000' "$config_file")
    export SAVEHIST
    UMASK=$(yq eval '.config.environment.umask // "022"' "$config_file")
    export UMASK
    TIMEOUT=$(yq eval '.config.environment.timeout // 300' "$config_file")
    export TIMEOUT
    
    # Development ports
    DEV_PORT=$(yq eval '.config.ports.dev // 3000' "$config_file")
    export DEV_PORT
    API_PORT=$(yq eval '.config.ports.api // 8000' "$config_file")
    export API_PORT
    DB_PORT=$(yq eval '.config.ports.db // 5432' "$config_file")
    export DB_PORT
    REDIS_PORT=$(yq eval '.config.ports.redis // 6379' "$config_file")
    export REDIS_PORT
    
    # Security settings
    SSH_KEY_TYPE=$(yq eval '.config.security.ssh_key_type // "ed25519"' "$config_file")
    export SSH_KEY_TYPE
    SSH_KEY_COMMENT_FORMAT=$(yq eval '.config.security.ssh_key_comment_format // "$(whoami)@$(hostname)"' "$config_file")
    export SSH_KEY_COMMENT_FORMAT
    SSH_DIR_PERMISSIONS=$(yq eval '.config.security.ssh_permissions.directory // "700"' "$config_file")
    export SSH_DIR_PERMISSIONS
    SSH_CONFIG_PERMISSIONS=$(yq eval '.config.security.ssh_permissions.config // "600"' "$config_file")
    export SSH_CONFIG_PERMISSIONS
    USE_KEYCHAIN=$(yq eval '.config.security.use_keychain // true' "$config_file")
    export USE_KEYCHAIN
    
    # UI settings
    UI_RED=$(yq eval '.config.ui.colors.red // "\\033[0;31m"' "$config_file")
    export UI_RED
    UI_GREEN=$(yq eval '.config.ui.colors.green // "\\033[0;32m"' "$config_file")
    export UI_GREEN
    UI_YELLOW=$(yq eval '.config.ui.colors.yellow // "\\033[1;33m"' "$config_file")
    export UI_YELLOW
    UI_BLUE=$(yq eval '.config.ui.colors.blue // "\\033[0;34m"' "$config_file")
    export UI_BLUE
    UI_NC=$(yq eval '.config.ui.colors.nc // "\\033[0m"' "$config_file")
    export UI_NC
    PROGRESS_FILLED=$(yq eval '.config.ui.progress_chars.filled // "█"' "$config_file")
    export PROGRESS_FILLED
    PROGRESS_EMPTY=$(yq eval '.config.ui.progress_chars.empty // "░"' "$config_file")
    export PROGRESS_EMPTY
    LOG_TIMESTAMP_FORMAT=$(yq eval '.config.ui.log_timestamp_format // "%Y-%m-%d %H:%M:%S"' "$config_file")
    export LOG_TIMESTAMP_FORMAT
    
    # Editor settings
    VSCODE_EXTENSIONS_DIR=$(yq eval '.config.editors.vscode.extensions_dir // "$HOME/.vscode/extensions"' "$config_file")
    export VSCODE_EXTENSIONS_DIR
    VSCODE_IPC_HOOK_CLI=$(yq eval '.config.editors.vscode.ipc_hook_cli // ""' "$config_file")
    export VSCODE_IPC_HOOK_CLI
    VSCODE_LOGS=$(yq eval '.config.editors.vscode.logs // ""' "$config_file")
    export VSCODE_LOGS
    CURSOR_EXTENSIONS_DIR=$(yq eval '.config.editors.cursor.extensions_dir // "$HOME/.cursor/extensions"' "$config_file")
    export CURSOR_EXTENSIONS_DIR
    CURSOR_IPC_HOOK_CLI=$(yq eval '.config.editors.cursor.ipc_hook_cli // ""' "$config_file")
    export CURSOR_IPC_HOOK_CLI
    CURSOR_LOGS=$(yq eval '.config.editors.cursor.logs // ""' "$config_file")
    export CURSOR_LOGS
    VOID_SETTINGS_DIR=$(yq eval '.config.editors.void.settings_dir // "$HOME/Library/Application Support/void/User"' "$config_file")
    export VOID_SETTINGS_DIR
    
    # Documentation settings
    DOCS_OUTPUT_FILENAME=$(yq eval '.config.docs.output_filename // "ENVIRONMENT_SETUP_COMPLETE"' "$config_file")
    export DOCS_OUTPUT_FILENAME
    DOCS_ENABLE_TABLE_SORTING=$(yq eval '.config.docs.enable_table_sorting // true' "$config_file")
    export DOCS_ENABLE_TABLE_SORTING
    DOCS_CSS_STYLES=$(yq eval '.config.docs.css_styles // ""' "$config_file")
    export DOCS_CSS_STYLES
    
    # macOS System Preferences
    # Dock settings
    DOCK_TILESIZE=$(yq eval '.config.macos.dock.tilesize // 48' "$config_file")
    export DOCK_TILESIZE
    DOCK_MAGNIFICATION=$(yq eval '.config.macos.dock.magnification // false' "$config_file")
    export DOCK_MAGNIFICATION
    DOCK_SHOW_RECENTS=$(yq eval '.config.macos.dock.show_recents // false' "$config_file")
    export DOCK_SHOW_RECENTS
    DOCK_AUTOHIDE=$(yq eval '.config.macos.dock.autohide // true' "$config_file")
    export DOCK_AUTOHIDE
    DOCK_AUTOHIDE_DELAY=$(yq eval '.config.macos.dock.autohide_delay // 0' "$config_file")
    export DOCK_AUTOHIDE_DELAY
    DOCK_AUTOHIDE_TIME_MODIFIER=$(yq eval '.config.macos.dock.autohide_time_modifier // 0.5' "$config_file")
    export DOCK_AUTOHIDE_TIME_MODIFIER
    DOCK_POSITION=$(yq eval '.config.macos.dock.position // "bottom"' "$config_file")
    export DOCK_POSITION
    
    # Finder settings
    FINDER_SHOW_PATHBAR=$(yq eval '.config.macos.finder.show_pathbar // true' "$config_file")
    export FINDER_SHOW_PATHBAR
    FINDER_SHOW_STATUSBAR=$(yq eval '.config.macos.finder.show_statusbar // true' "$config_file")
    export FINDER_SHOW_STATUSBAR
    FINDER_SHOW_ALL_EXTENSIONS=$(yq eval '.config.macos.finder.show_all_extensions // true' "$config_file")
    export FINDER_SHOW_ALL_EXTENSIONS
    FINDER_SHOW_HIDDEN_FILES=$(yq eval '.config.macos.finder.show_hidden_files // true' "$config_file")
    export FINDER_SHOW_HIDDEN_FILES
    FINDER_DEFAULT_SEARCH_SCOPE=$(yq eval '.config.macos.finder.default_search_scope // "SCcf"' "$config_file")
    export FINDER_DEFAULT_SEARCH_SCOPE
    
    # Keyboard settings
    KEYBOARD_REPEAT=$(yq eval '.config.macos.keyboard.key_repeat // 1' "$config_file")
    export KEYBOARD_REPEAT
    KEYBOARD_INITIAL_REPEAT=$(yq eval '.config.macos.keyboard.initial_key_repeat // 15' "$config_file")
    export KEYBOARD_INITIAL_REPEAT
    KEYBOARD_PRESS_AND_HOLD_DISABLED=$(yq eval '.config.macos.keyboard.press_and_hold_disabled // true' "$config_file")
    export KEYBOARD_PRESS_AND_HOLD_DISABLED
    
    # Trackpad settings
    TRACKPAD_TAP_TO_CLICK=$(yq eval '.config.macos.trackpad.tap_to_click // true' "$config_file")
    export TRACKPAD_TAP_TO_CLICK
    TRACKPAD_THREE_FINGER_DRAG=$(yq eval '.config.macos.trackpad.three_finger_drag // true' "$config_file")
    export TRACKPAD_THREE_FINGER_DRAG
    TRACKPAD_NATURAL_SCROLLING=$(yq eval '.config.macos.trackpad.natural_scrolling // true' "$config_file")
    export TRACKPAD_NATURAL_SCROLLING
    
    # Display settings
    DISPLAY_NIGHT_SHIFT=$(yq eval '.config.macos.display.night_shift // "auto"' "$config_file")
    export DISPLAY_NIGHT_SHIFT
    DISPLAY_TRUE_TONE=$(yq eval '.config.macos.display.true_tone // "auto"' "$config_file")
    export DISPLAY_TRUE_TONE
    DISPLAY_AUTO_BRIGHTNESS=$(yq eval '.config.macos.display.auto_brightness // true' "$config_file")
    export DISPLAY_AUTO_BRIGHTNESS
    
    # Accessibility settings
    ACCESSIBILITY_REDUCE_MOTION=$(yq eval '.config.macos.accessibility.reduce_motion // false' "$config_file")
    export ACCESSIBILITY_REDUCE_MOTION
    ACCESSIBILITY_REDUCE_TRANSPARENCY=$(yq eval '.config.macos.accessibility.reduce_transparency // false' "$config_file")
    export ACCESSIBILITY_REDUCE_TRANSPARENCY
    ACCESSIBILITY_INCREASE_CONTRAST=$(yq eval '.config.macos.accessibility.increase_contrast // false' "$config_file")
    export ACCESSIBILITY_INCREASE_CONTRAST
    
    # Date & Time settings
    DATETIME_SET_TIMEZONE_AUTO=$(yq eval '.config.macos.date_time.set_timezone_automatically // true' "$config_file")
    export DATETIME_SET_TIMEZONE_AUTO
    DATETIME_SHOW_IN_MENUBAR=$(yq eval '.config.macos.date_time.show_in_menubar // true' "$config_file")
    export DATETIME_SHOW_IN_MENUBAR
    DATETIME_24_HOUR_FORMAT=$(yq eval '.config.macos.date_time.use_24_hour_format // false' "$config_file")
    export DATETIME_24_HOUR_FORMAT
    
    # Sound settings
    SOUND_SHOW_VOLUME_MENUBAR=$(yq eval '.config.macos.sound.show_volume_in_menubar // true' "$config_file")
    export SOUND_SHOW_VOLUME_MENUBAR
    SOUND_PLAY_EFFECTS=$(yq eval '.config.macos.sound.play_sound_effects // true' "$config_file")
    export SOUND_PLAY_EFFECTS
    SOUND_PLAY_VOLUME_FEEDBACK=$(yq eval '.config.macos.sound.play_volume_feedback // true' "$config_file")
    export SOUND_PLAY_VOLUME_FEEDBACK
    
    # Energy Saver settings
    ENERGY_PREVENT_SLEEP=$(yq eval '.config.macos.energy_saver.prevent_sleep_when_display_off // false' "$config_file")
    export ENERGY_PREVENT_SLEEP
    ENERGY_PUT_DISKS_TO_SLEEP=$(yq eval '.config.macos.energy_saver.put_hard_disks_to_sleep // true' "$config_file")
    export ENERGY_PUT_DISKS_TO_SLEEP
    ENERGY_WAKE_FOR_NETWORK=$(yq eval '.config.macos.energy_saver.wake_for_network_access // true' "$config_file")
    export ENERGY_WAKE_FOR_NETWORK
    
# Security settings
SECURITY_REQUIRE_PASSWORD_IMMEDIATELY=$(yq eval '.config.macos.security.require_password_immediately // true' "$config_file")
export SECURITY_REQUIRE_PASSWORD_IMMEDIATELY
SECURITY_ALLOW_APPS_FROM=$(yq eval '.config.macos.security.allow_apps_from // "AppStoreAndIdentifiedDevelopers"' "$config_file")
export SECURITY_ALLOW_APPS_FROM
SECURITY_ENABLE_FILEVAULT=$(yq eval '.config.macos.security.enable_filevault // "ask_user"' "$config_file")
export SECURITY_ENABLE_FILEVAULT

# Shell configuration
SHELL_PLUGIN_MANAGER=$(yq eval '.config.shell.plugin_manager // "zinit"' "$config_file")
export SHELL_PLUGIN_MANAGER
SHELL_THEME=$(yq eval '.config.shell.theme // "powerlevel10k"' "$config_file")
export SHELL_THEME
SHELL_THEME_STYLE=$(yq eval '.config.shell.theme_style // "rainbow"' "$config_file")
export SHELL_THEME_STYLE
SHELL_HISTORY_SIZE=$(yq eval '.config.shell.history.size // 10000' "$config_file")
export SHELL_HISTORY_SIZE
SHELL_HISTORY_DEDUPE=$(yq eval '.config.shell.history.dedupe // true' "$config_file")
export SHELL_HISTORY_DEDUPE
SHELL_HISTORY_SHARE=$(yq eval '.config.shell.history.share // true' "$config_file")
export SHELL_HISTORY_SHARE
SHELL_HISTORY_IGNORE_DUPS=$(yq eval '.config.shell.history.ignore_dups // true' "$config_file")
export SHELL_HISTORY_IGNORE_DUPS
SHELL_HISTORY_IGNORE_SPACE=$(yq eval '.config.shell.history.ignore_space // true' "$config_file")
export SHELL_HISTORY_IGNORE_SPACE
SHELL_HISTORY_FUZZY_SEARCH=$(yq eval '.config.shell.history.fuzzy_search // true' "$config_file")
export SHELL_HISTORY_FUZZY_SEARCH

# Tmux configuration
TMUX_ENABLED=$(yq eval '.config.tmux.enabled // true' "$config_file")
export TMUX_ENABLED
TMUX_CONFIG_FILE=$(yq eval '.config.tmux.config_file // "~/.tmux.conf"' "$config_file")
export TMUX_CONFIG_FILE
TMUX_PREFIX=$(yq eval '.config.tmux.settings.prefix // "C-a"' "$config_file")
export TMUX_PREFIX
TMUX_MOUSE=$(yq eval '.config.tmux.settings.mouse // true' "$config_file")
export TMUX_MOUSE
TMUX_HISTORY_LIMIT=$(yq eval '.config.tmux.settings.history_limit // 10000' "$config_file")
export TMUX_HISTORY_LIMIT
TMUX_DEFAULT_SHELL=$(yq eval '.config.tmux.settings.default_shell // "/bin/zsh"' "$config_file")
export TMUX_DEFAULT_SHELL
    
    log "INFO" "Configuration loaded from $config_file"
}

# Get package list for category
get_packages() {
    local category="$1"
    local type="$2"  # brew or cask
    
    if [ ! -f "${CONFIG_FILE:-config.yaml}" ]; then
        return 1
    fi
    
    # Use yq to get the array and convert to space-separated string
    local packages
    packages=$(yq eval ".packages.${category}.${type}[] // []" "${CONFIG_FILE:-config.yaml}" 2>/dev/null | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$packages"
}

# Get extensions for role
get_extensions() {
    local role="$1"
    
    if [ ! -f "${CONFIG_FILE:-config.yaml}" ]; then
        return 1
    fi
    
    # Use yq to get the array and convert to space-separated string
    local extensions
    extensions=$(yq eval ".extensions.${role}[] // []" "${CONFIG_FILE:-config.yaml}" 2>/dev/null | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$extensions"
}

# Check if category is enabled
is_category_enabled() {
    local category="$1"
    
    if [ ! -f "${CONFIG_FILE:-config.yaml}" ]; then
        return 1
    fi
    
    yq eval ".categories.$category.enabled // false" "${CONFIG_FILE:-config.yaml}" 2>/dev/null
}

# Generate summary report
generate_summary() {
    local log_file="${LOG_FILE:-}"
    local summary_file
    summary_file="logs/setup-summary-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "=== Setup Summary ==="
        echo "Date: $(date)"
        echo "Log file: $log_file"
        echo ""
        echo "=== Installed Tools ==="
        
        # Core tools
        command_exists git && echo "• Git: $(git --version)"
        command_exists node && echo "• Node.js: $(node --version)"
        command_exists pnpm && echo "• pnpm: $(pnpm --version)"
        command_exists bun && echo "• bun: $(bun --version)"
        command_exists docker && echo "• Docker: $(docker --version)"
        command_exists brew && echo "• Homebrew: $(brew --version | head -n1)"
        
        # Databases
        command_exists psql && echo "• PostgreSQL: $(psql --version)"
        command_exists mongosh && echo "• MongoDB Shell: $(mongosh --version)"
        command_exists redis-cli && echo "• Redis CLI: $(redis-cli --version)"
        
        # AI Tools
        if command_exists ollama; then
            local model_count
        model_count=$(ollama list 2>/dev/null | wc -l | tr -d ' ')
            echo "• Ollama: $model_count models installed"
        fi
        
        # Services
        if port_in_use "${LM_STUDIO_PORT:-1234}"; then
            echo "• LM Studio: Running on port ${LM_STUDIO_PORT:-1234}"
        fi
        
        if port_in_use "${OPEN_WEBUI_PORT:-3000}"; then
            echo "• Open WebUI: Running on port ${OPEN_WEBUI_PORT:-3000}"
        fi
        
    } > "$summary_file"
    
    log "INFO" "Summary saved to $summary_file"
    cat "$summary_file"
}







