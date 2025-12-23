#!/bin/bash
# MPD Framebuffer Display Service - Uninstallation Script
# This script removes the MPD album art display service

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
SERVICE_USER="mpdviewer"
SERVICE_GROUP="mpdviewer"
INSTALL_DIR="/opt/mpd_framebuffer"
SERVICE_NAME="mpd_framebuffer.service"

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

confirm_uninstall() {
    echo ""
    print_warning "This will remove the MPD Framebuffer Display Service"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_info "Uninstallation cancelled"
        exit 0
    fi
}

stop_service() {
    print_info "Stopping service..."
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        systemctl stop $SERVICE_NAME
        print_info "Service stopped"
    else
        print_info "Service is not running"
    fi
    
    if systemctl is-enabled --quiet $SERVICE_NAME 2>/dev/null; then
        systemctl disable $SERVICE_NAME
        print_info "Service disabled"
    fi
}

remove_service_file() {
    print_info "Removing systemd service file..."
    
    if [ -f "/etc/systemd/system/$SERVICE_NAME" ]; then
        rm "/etc/systemd/system/$SERVICE_NAME"
        systemctl daemon-reload
        print_info "Service file removed"
    else
        print_info "Service file not found"
    fi
}

remove_files() {
    print_info "Removing installation files..."
    
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        print_info "Installation directory removed"
    else
        print_info "Installation directory not found"
    fi
}

remove_user() {
    print_warning "User data cleanup options:"
    echo "  1. Keep user and configuration (default)"
    echo "  2. Remove user but keep home directory"
    echo "  3. Remove user and all data"
    read -p "Choose option (1-3): " -r USER_CHOICE
    
    case $USER_CHOICE in
        2)
            if id "$SERVICE_USER" &>/dev/null; then
                userdel "$SERVICE_USER"
                print_info "User removed, home directory preserved at /home/$SERVICE_USER"
            fi
            ;;
        3)
            if id "$SERVICE_USER" &>/dev/null; then
                userdel -r "$SERVICE_USER" 2>/dev/null || userdel "$SERVICE_USER"
                print_info "User and home directory removed"
            fi
            ;;
        *)
            print_info "User and configuration preserved at /home/$SERVICE_USER"
            ;;
    esac
}

show_completion() {
    echo ""
    print_info "Uninstallation complete!"
    echo ""
    if id "$SERVICE_USER" &>/dev/null; then
        echo "Note: User '$SERVICE_USER' still exists with configuration at:"
        echo "  /home/$SERVICE_USER/.config/mpd_framebuffer_service/"
        echo ""
        echo "To manually remove later:"
        echo "  sudo userdel -r $SERVICE_USER"
    fi
}

main() {
    echo "======================================"
    echo "MPD Framebuffer Display Service"
    echo "Uninstallation Script"
    echo "======================================"
    
    check_root
    confirm_uninstall
    stop_service
    remove_service_file
    remove_files
    remove_user
    show_completion
}

main "$@"
