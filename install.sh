#!/bin/bash
# MPD Framebuffer Display Service - Installation Script
# This script installs the MPD album art display service for framebuffer devices

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SERVICE_USER="mpdviewer"
SERVICE_GROUP="mpdviewer"
INSTALL_DIR="/opt/mpd_framebuffer"
SERVICE_NAME="mpd_framebuffer.service"
SCRIPT_NAME="mpd_framebuffer_service_http.py"
DISPLAY_SCRIPT="display_art.sh"

# Functions
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_package_manager() {
    if command -v pacman &> /dev/null; then
        echo "pacman"
    elif command -v apt &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    else
        echo "unknown"
    fi
}

install_system_packages() {
    local pkg_manager=$1
    shift
    local packages=("$@")
    
    print_info "Installing system packages: ${packages[*]}"
    
    case "$pkg_manager" in
        pacman)
            pacman -S --noconfirm "${packages[@]}"
            ;;
        apt)
            apt update
            apt install -y "${packages[@]}"
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
        yum)
            yum install -y "${packages[@]}"
            ;;
        *)
            print_error "Unknown package manager. Please install manually: ${packages[*]}"
            return 1
            ;;
    esac
}

check_dependencies() {
    print_info "Checking system dependencies..."
    
    local pkg_manager=$(detect_package_manager)
    local missing_packages=()
    
    # Check for Python 3
    if ! command -v python3 &> /dev/null; then
        case "$pkg_manager" in
            pacman) missing_packages+=("python") ;;
            apt) missing_packages+=("python3") ;;
            dnf|yum) missing_packages+=("python3") ;;
        esac
    fi
    
    # Check for pip
    if ! command -v pip3 &> /dev/null; then
        case "$pkg_manager" in
            pacman) missing_packages+=("python-pip") ;;
            apt) missing_packages+=("python3-pip") ;;
            dnf|yum) missing_packages+=("python3-pip") ;;
        esac
    fi
    
    # Check for venv module (needed for virtual environments on Debian/Ubuntu)
    if [[ "$pkg_manager" == "apt" ]]; then
        if ! dpkg -l | grep -q python3-venv; then
            missing_packages+=("python3-venv")
        fi
    fi
    
    # Check for fbi (framebuffer image viewer)
    if ! command -v fbi &> /dev/null; then
        case "$pkg_manager" in
            pacman) missing_packages+=("fbida") ;;
            apt) missing_packages+=("fbi") ;;
            dnf|yum) missing_packages+=("fbi") ;;
        esac
    fi
    
    if [ ${#missing_packages[@]} -ne 0 ]; then
        print_warning "Missing dependencies detected: ${missing_packages[*]}"
        print_info "Attempting to install automatically..."
        
        if install_system_packages "$pkg_manager" "${missing_packages[@]}"; then
            print_info "Dependencies installed successfully"
        else
            print_error "Failed to install dependencies automatically"
            print_info "On Arch: sudo pacman -S python python-pip fbida"
            print_info "On Debian/Ubuntu: sudo apt install python3 python3-pip fbi"
            print_info "On Fedora: sudo dnf install python3 python3-pip fbi"
            exit 1
        fi
    else
        print_info "All system dependencies found"
    fi
}

install_python_deps() {
    print_info "Creating Python virtual environment..."
    
    # Ensure installation directory exists
    mkdir -p "$INSTALL_DIR"
    
    # Create venv in the installation directory
    python3 -m venv "$INSTALL_DIR/venv"
    
    print_info "Installing Python dependencies..."
    
    if [ -f "requirements.txt" ]; then
        "$INSTALL_DIR/venv/bin/pip" install -r requirements.txt
        print_info "Python dependencies installed"
    else
        print_warning "requirements.txt not found, installing manually..."
        "$INSTALL_DIR/venv/bin/pip" install python-mpd2 Pillow
    fi
}

create_service_user() {
    if id "$SERVICE_USER" &>/dev/null; then
        print_info "User $SERVICE_USER already exists"
    else
        print_info "Creating service user: $SERVICE_USER"
        useradd -r -s /bin/false -d /home/$SERVICE_USER -G video,tty $SERVICE_USER
        mkdir -p /home/$SERVICE_USER
        chown $SERVICE_USER:$SERVICE_GROUP /home/$SERVICE_USER
    fi
}

install_files() {
    print_info "Installing files to $INSTALL_DIR..."
    
    # Create installation directory
    mkdir -p "$INSTALL_DIR"
    
    # Copy Python service script
    if [ -f "src/$SCRIPT_NAME" ]; then
        cp "src/$SCRIPT_NAME" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
        print_info "Installed $SCRIPT_NAME"
    else
        print_error "src/$SCRIPT_NAME not found!"
        exit 1
    fi
    
    # Copy display script (optional, for legacy use)
    if [ -f "src/$DISPLAY_SCRIPT" ]; then
        cp "src/$DISPLAY_SCRIPT" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/$DISPLAY_SCRIPT"
        print_info "Installed $DISPLAY_SCRIPT"
    fi
    
    # Copy default image
    if [ -f "assets/default_art.jpg" ]; then
        mkdir -p "$INSTALL_DIR/assets"
        cp "assets/default_art.jpg" "$INSTALL_DIR/assets/"
        print_info "Installed default album art"
    fi
}

setup_service_config() {
    print_info "Setting up service configuration..."
    
    # Create config and cache directories for service user
    local config_dir="/home/$SERVICE_USER/.config/mpd_framebuffer_service"
    local cache_dir="/home/$SERVICE_USER/.cache/mpd_framebuffer_service"
    mkdir -p "$config_dir"
    mkdir -p "$cache_dir"
    
    # Set ownership BEFORE running setup
    chown -R $SERVICE_USER:$SERVICE_GROUP /home/$SERVICE_USER
    
    # Run setup as service user if config doesn't exist
    if [ ! -f "$config_dir/config.json" ]; then
        print_info "Running initial setup for $SERVICE_USER..."
        sudo -u $SERVICE_USER "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/$SCRIPT_NAME" --setup
    else
        print_info "Configuration already exists at $config_dir/config.json"
    fi
    
    # Ensure proper ownership of venv
    chown -R $SERVICE_USER:$SERVICE_GROUP "$INSTALL_DIR/venv"
}

setup_sudoers() {
    print_info "Setting up sudoers for framebuffer access..."
    
    if [ -f "sudoers.d/mpd_framebuffer" ]; then
        # Install sudoers file with proper permissions
        cp "sudoers.d/mpd_framebuffer" "/etc/sudoers.d/mpd_framebuffer"
        chmod 0440 "/etc/sudoers.d/mpd_framebuffer"
        
        # Validate sudoers file
        if visudo -c -f "/etc/sudoers.d/mpd_framebuffer" &>/dev/null; then
            print_info "Sudoers file installed for passwordless fbi access"
        else
            print_error "Sudoers file validation failed, removing it"
            rm "/etc/sudoers.d/mpd_framebuffer"
            exit 1
        fi
    else
        print_warning "sudoers.d/mpd_framebuffer not found, fbi may not work properly"
    fi
}

install_systemd_service() {
    print_info "Installing systemd service..."
    
    if [ -f "systemd/$SERVICE_NAME" ]; then
        # Update the ExecStart to use venv Python and correct script path
        sed "s|ExecStart=.*|ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/$SCRIPT_NAME|g" \
            "systemd/$SERVICE_NAME" > "/etc/systemd/system/$SERVICE_NAME"
        
        # Reload systemd
        systemctl daemon-reload
        print_info "Systemd service installed"
    else
        print_error "systemd/$SERVICE_NAME not found!"
        exit 1
    fi
}

enable_service() {
    print_info "Enabling and starting service..."
    
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME
    
    sleep 2
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        print_info "Service is running successfully!"
    else
        print_warning "Service may have issues. Check status with: sudo systemctl status $SERVICE_NAME"
    fi
}

show_info() {
    echo ""
    print_info "Installation complete!"
    echo ""
    echo "Service commands:"
    echo "  Status:  sudo systemctl status $SERVICE_NAME"
    echo "  Start:   sudo systemctl start $SERVICE_NAME"
    echo "  Stop:    sudo systemctl stop $SERVICE_NAME"
    echo "  Restart: sudo systemctl restart $SERVICE_NAME"
    echo "  Logs:    sudo journalctl -u $SERVICE_NAME -f"
    echo ""
    echo "Installation paths:"
    echo "  Service:  $INSTALL_DIR/"
    echo "  Venv:     $INSTALL_DIR/venv/"
    echo ""
    echo "Configuration:"
    echo "  Config:   /home/$SERVICE_USER/.config/mpd_framebuffer_service/config.json"
    echo "  Logs:     /home/$SERVICE_USER/.cache/mpd_framebuffer_service/service.log"
    echo ""
    echo "HTTP endpoints (localhost only by default):"
    echo "  Current art: http://localhost:8080/current.jpg"
    echo "  Status JSON: http://localhost:8080/status.json"
    echo ""
}

# Main installation flow
main() {
    echo "======================================"
    echo "MPD Framebuffer Display Service"
    echo "Installation Script"
    echo "======================================"
    echo ""
    
    check_root
    check_dependencies
    install_python_deps
    create_service_user
    install_files
    setup_service_config
    setup_sudoers
    install_systemd_service
    enable_service
    show_info
}

main "$@"
