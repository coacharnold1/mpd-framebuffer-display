# MPD Framebuffer Display Service

A lightweight service that displays MPD (Music Player Daemon) album artwork on framebuffer devices like small TFT screens. Perfect for Raspberry Pi, mini PCs, or any Linux system with a framebuffer display.

## Features

- **Real-time Album Art Display**: Automatically fetches and displays album artwork from MPD
- **HTTP API**: Serves current album art and track info via HTTP endpoints
- **Framebuffer Support**: Direct rendering to framebuffer devices (e.g., `/dev/fb0`)
- **Automatic Updates**: Uses MPD IDLE to detect track changes instantly
- **Fallback Image**: Displays default artwork when none is available
- **Systemd Integration**: Runs as a reliable system service
- **Low Resource Usage**: Minimal CPU and memory footprint
- **SSH Tunnel Friendly**: Access via localhost for secure remote viewing

## Requirements

### System Dependencies
- **Python 3** (3.7 or newer)
- **MPD** (Music Player Daemon) - running and accessible
- **fbi** - framebuffer image viewer (`fbida` package on Arch, `fbi` on Debian/Ubuntu)
- **Framebuffer device** (e.g., `/dev/fb0`) - typically `/dev/tty1` for console

### Python Dependencies
- `python-mpd2` - MPD client library
- `Pillow` - Image processing

## Installation

### Quick Install

1. Clone or download this repository:
```bash
cd /tmp
git clone <repository-url> mpd-framebuffer-display
cd mpd-framebuffer-display
```

2. Run the installer (requires root):
```bash
sudo ./install.sh
```

The installer will:
- Check and prompt for missing dependencies
- Create a dedicated `mpdviewer` system user
- Install files to `/opt/mpd_framebuffer/`
- Set up the systemd service
- Configure and start the service

### Manual Installation

If you prefer manual setup:

1. Install system dependencies:
```bash
# Arch Linux
sudo pacman -S python python-pip fbida

# Debian/Ubuntu
sudo apt install python3 python3-pip fbi
```

2. Install Python dependencies:
```bash
pip3 install -r requirements.txt
```

3. Create service user:
```bash
sudo useradd -r -s /bin/false -d /home/mpdviewer -G video,tty mpdviewer
sudo mkdir -p /home/mpdviewer
```

4. Copy files:
```bash
sudo mkdir -p /opt/mpd_framebuffer
sudo cp src/mpd_framebuffer_service_http.py /opt/mpd_framebuffer/
sudo cp -r assets /opt/mpd_framebuffer/
sudo chmod +x /opt/mpd_framebuffer/mpd_framebuffer_service_http.py
```

5. Run initial setup:
```bash
sudo -u mpdviewer python3 /opt/mpd_framebuffer/mpd_framebuffer_service_http.py --setup
```

6. Install systemd service:
```bash
sudo cp systemd/mpd_framebuffer.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable mpd_framebuffer.service
sudo systemctl start mpd_framebuffer.service
```

## Configuration

The service is configured via JSON file located at:
```
/home/mpdviewer/.config/mpd_framebuffer_service/config.json
```

### Configuration Options

```json
{
  "mpd_host": "localhost",
  "mpd_port": 6600,
  "mpd_socket": "",
  "use_socket": false,
  "mpd_password": "",
  "output_dir": "/home/mpdviewer/.cache/mpd_framebuffer_service",
  "current_filename": "current_cover.jpg",
  "default_image": "/opt/mpd_framebuffer/assets/default_art.jpg",
  "resize": [800, 480],
  "display_method": "auto",
  "display_cmd": "fbi -T 1 {path}",
  "http_bind": "127.0.0.1",
  "http_port": 8080,
  "http_token": "<generated-token>"
}
```

**Key Settings:**
- `resize`: Dimensions for your display `[width, height]`
- `display_cmd`: Command to render images (use `fbi -T 1 {path}` for VT1)
- `default_image`: Path to fallback artwork
- `http_port`: Port for HTTP API (default: 8080)

To edit configuration:
```bash
sudo nano /home/mpdviewer/.config/mpd_framebuffer_service/config.json
sudo systemctl restart mpd_framebuffer.service
```

## Usage

### Service Management

```bash
# Check status
sudo systemctl status mpd_framebuffer.service

# Start service
sudo systemctl start mpd_framebuffer.service

# Stop service
sudo systemctl stop mpd_framebuffer.service

# Restart service
sudo systemctl restart mpd_framebuffer.service

# View logs
sudo journalctl -u mpd_framebuffer.service -f

# View application logs
sudo tail -f /home/mpdviewer/.cache/mpd_framebuffer_service/service.log
```

### HTTP API

The service provides HTTP endpoints for remote access:

#### Get Current Album Art
```bash
curl http://localhost:8080/current.jpg -o album.jpg
```

#### Get Track Status (JSON)
```bash
curl http://localhost:8080/status.json
```

Response:
```json
{
  "artist": "Artist Name",
  "album": "Album Title",
  "title": "Track Title",
  "last_fetch": 1703361234.56,
  "last_error": ""
}
```

#### Force Refresh (with token)
```bash
curl -X POST "http://localhost:8080/fetch?token=<your-token>"
```

### Remote Access via SSH Tunnel

To access from a remote machine:

```bash
# On your remote workstation
ssh -L 8080:localhost:8080 user@your-server

# Then open in browser or curl
curl http://localhost:8080/current.jpg -o album.jpg
```

## Display Configuration

### Virtual Terminal (TTY) Setup

To display on a specific TTY (e.g., TTY1 connected to a monitor):

1. Ensure the service user can access the TTY:
```bash
sudo usermod -a -G tty,video mpdviewer
```

2. Set `display_cmd` in config to use `fbi` with specific TTY:
```json
"display_cmd": "fbi -T 1 {path}"
```

3. The systemd service is already configured for TTY1 in the provided service file

### Framebuffer Device

If you have a dedicated framebuffer device:

```json
"display_cmd": "fbi -d /dev/fb0 -T 1 --noverbose {path}"
```

## Troubleshooting

### Service won't start
```bash
# Check service status
sudo systemctl status mpd_framebuffer.service

# Check logs
sudo journalctl -u mpd_framebuffer.service -n 50
```

### No image displays
1. Verify fbi is installed: `which fbi`
2. Check framebuffer access: `ls -la /dev/fb0`
3. Verify TTY permissions: `groups mpdviewer` should include `video` and `tty`
4. Check display_cmd in config

### Cannot connect to MPD
1. Verify MPD is running: `systemctl status mpd`
2. Check MPD connection settings in config.json
3. Test MPD connection: `mpc status`

### Album art not updating
1. Ensure MPD has album art embedded or in music folders
2. Check logs for errors: `tail -f /home/mpdviewer/.cache/mpd_framebuffer_service/service.log`
3. Manually trigger fetch via HTTP API

## Uninstallation

To remove the service:

```bash
sudo ./uninstall.sh
```

The uninstaller will:
- Stop and disable the service
- Remove service files
- Optionally remove the service user and data

## Project Structure

```
mpd-framebuffer-display/
├── src/
│   ├── mpd_framebuffer_service_http.py  # Main service script
│   └── display_art.sh                   # Legacy shell script (optional)
├── systemd/
│   └── mpd_framebuffer.service          # Systemd service file
├── assets/
│   └── default_art.jpg                  # Default fallback image
├── install.sh                            # Installation script
├── uninstall.sh                          # Uninstallation script
├── requirements.txt                      # Python dependencies
└── README.md                             # This file
```

## Development

To test without installing:

```bash
# Install dependencies in a virtual environment
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Run setup
python3 src/mpd_framebuffer_service_http.py --setup

# Run service
python3 src/mpd_framebuffer_service_http.py
```

## License

This project is provided as-is for personal and educational use.

## Contributing

Contributions welcome! Feel free to submit issues or pull requests.

## Credits

Created for displaying album artwork on small framebuffer displays with MPD music servers.
