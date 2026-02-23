#!/usr/bin/env python3
"""
this is the current working version !!   
MPD Album Art Framebuffer Service + HTTP endpoint (lightweight)

Features:
- Connects to MPD and IDLE for changes.
- Fetches albumart via python-mpd2 and normalizes responses to bytes.
- Saves resized current_cover.jpg to an output directory.
- Runs a small HTTP server (binds to 127.0.0.1 by default) that serves:
    GET /current.jpg      -> latest image file (404 if none)
    GET /status.json      -> JSON with artist/album/title/last_fetch/last_error
    POST /fetch?token=... -> trigger an immediate fetch (protected by token)
- Config file: ~/.config/mpd_framebuffer/config.json (created with --setup)
- Logs to: ~/.cache/mpd_framebuffer/service.log

Run:
  python3 mpd_framebuffer_service_http.py --setup
  python3 mpd_framebuffer_service_http.py

Remote access:
  Use an SSH tunnel: on your remote workstation
  ssh -L 8080:localhost:8080 user@mini-pc
  then open http://localhost:8080/current.jpg or /status.json

Note: keep the HTTP server bound to localhost unless you intentionally expose it.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import logging
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional

# Optional imports, handled gracefully if missing
try:
    from mpd import MPDClient, MPDError, CommandError
except Exception:
    MPDClient = None  # type: ignore
    MPDError = Exception  # type: ignore
    CommandError = Exception  # type: ignore

try:
    from PIL import Image, ImageDraw, ImageFont
except Exception:
    Image = None  # type: ignore
    ImageDraw = None  # type: ignore
    ImageFont = None  # type: ignore

APP_NAME = "mpd_framebuffer_service"
DEFAULT_CONFIG = {
    "mpd_host": "localhost",
    "mpd_port": 6600,
    "mpd_socket": "",
    "use_socket": False,
    "mpd_password": "",
    "output_dir": str(Path.home() / ".cache" / APP_NAME),
    "current_filename": "current_cover.jpg",
    "default_image": "",
    "resize": [800, 480],
    "display_method": "auto",
    "display_cmd": "",
    "http_bind": "127.0.0.1",
    "http_port": 8080,
    "http_token": "",  # generate one during setup if empty
}
CONFIG_PATH = Path.home() / ".config" / APP_NAME / "config.json"
LOG_PATH = Path.home() / ".cache" / APP_NAME / "service.log"

os.makedirs(LOG_PATH.parent, exist_ok=True)
logging.basicConfig(
    filename=str(LOG_PATH),
    level=logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s"
)

_SHUTDOWN = False
_STATE_LOCK = threading.Lock()
_STATE: dict[str, Any] = {
    "artist": "",
    "album": "",
    "title": "",
    "last_fetch": None,
    "last_error": ""
}


def signal_handler(signum, frame):
    global _SHUTDOWN
    logging.info("Received signal %s, shutting down...", signum)
    _SHUTDOWN = True


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


def read_config() -> dict:
    if not CONFIG_PATH.exists():
        return DEFAULT_CONFIG.copy()
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        cfg = DEFAULT_CONFIG.copy()
        cfg.update(data or {})
        return cfg
    except Exception:
        logging.exception("Failed to read config; using defaults")
        return DEFAULT_CONFIG.copy()


def write_config_interactive() -> None:
    cfg_dir = CONFIG_PATH.parent
    cfg_dir.mkdir(parents=True, exist_ok=True)

    print("MPD Framebuffer Service - interactive setup")
    host = input(f"MPD host [{DEFAULT_CONFIG['mpd_host']}]: ") or DEFAULT_CONFIG["mpd_host"]
    port = input(f"MPD port [{DEFAULT_CONFIG['mpd_port']}]: ") or str(DEFAULT_CONFIG["mpd_port"])
    use_socket = input("Use UNIX socket? (y/N): ").lower().startswith("y")
    socket_path = ""
    if use_socket:
        socket_path = input("Socket path [/run/mpd/socket]: ") or "/run/mpd/socket"
    password = input("MPD password (leave empty if none): ")
    outdir = input(f"Output directory [{DEFAULT_CONFIG['output_dir']}]: ") or DEFAULT_CONFIG["output_dir"]
    default_img = input("Default image path (fallback, optional): ") or ""
    width = input(f"Target width [{DEFAULT_CONFIG['resize'][0]}]: ") or str(DEFAULT_CONFIG['resize'][0])
    height = input(f"Target height [{DEFAULT_CONFIG['resize'][1]}]: ") or str(DEFAULT_CONFIG['resize'][1])
    http_bind = input(f"HTTP bind [{DEFAULT_CONFIG['http_bind']}]: ") or DEFAULT_CONFIG['http_bind']
    http_port = input(f"HTTP port [{DEFAULT_CONFIG['http_port']}]: ") or str(DEFAULT_CONFIG['http_port'])
    token = input("HTTP secret token (leave blank to auto-generate): ") or ""

    if not token:
        token = hashlib.sha256(os.urandom(32)).hexdigest()[:20]
        print("Generated token:", token)

    cfg = {
        "mpd_host": host,
        "mpd_port": int(port),
        "mpd_socket": socket_path,
        "use_socket": bool(use_socket),
        "mpd_password": password,
        "output_dir": outdir,
        "current_filename": "current_cover.jpg",
        "default_image": default_img,
        "resize": [int(width), int(height)],
        "display_method": "auto",
        "display_cmd": "",
        "http_bind": http_bind,
        "http_port": int(http_port),
        "http_token": token,
    }
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    print(f"Saved config to {CONFIG_PATH}")


def ensure_output_dir(cfg: dict) -> Path:
    outdir = Path(cfg["output_dir"])
    outdir.mkdir(parents=True, exist_ok=True)
    return outdir


def normalize_albumart_response(resp: Any) -> Optional[bytes]:
    if resp is None:
        return None
    if isinstance(resp, (bytes, bytearray)):
        return bytes(resp)
    if isinstance(resp, (list, tuple)):
        parts = []
        for item in resp:
            b = normalize_albumart_response(item)
            if b:
                parts.append(b)
        return b"".join(parts) if parts else None
    if isinstance(resp, dict):
        for key in ("data", b"data", "binary", "image", "image_data", "file"):
            if key in resp:
                return normalize_albumart_response(resp[key])
        for v in resp.values():
            b = normalize_albumart_response(v)
            if b:
                return b
        return None
    if hasattr(resp, "data"):
        try:
            return normalize_albumart_response(getattr(resp, "data"))
        except Exception:
            return None
    return None


def try_resize_and_save(img_bytes: bytes, path: Path, size: tuple[int, int], metadata: dict = None) -> None:
    if Image is None:
        path.write_bytes(img_bytes)
        return
    try:
        from io import BytesIO
        im = Image.open(BytesIO(img_bytes))
        im = im.convert("RGB")
        
        # If metadata provided, create composite image with text overlay
        if metadata and ImageDraw and ImageFont:
            im = create_composite_with_metadata(im, size, metadata)
        else:
            # Just resize the image
            im.thumbnail(size, Image.Resampling.LANCZOS if hasattr(Image, "Resampling") else Image.ANTIALIAS)
        
        im.save(str(path), format="JPEG", quality=85)
    except Exception:
        logging.exception("Image processing failed; writing raw bytes")
        try:
            path.write_bytes(img_bytes)
        except Exception:
            logging.exception("Failed to write image file")


def create_composite_with_metadata(art_img: Image.Image, canvas_size: tuple[int, int], metadata: dict) -> Image.Image:
    """Create composite image with album art on right and metadata text on left"""
    try:
        canvas_width, canvas_height = canvas_size
        
        # Scale art to fit (max 70% of canvas width)
        art_max_width = int(canvas_width * 0.7)
        art_max_height = canvas_height  
        
        # Resize art maintaining aspect ratio
        art_img.thumbnail((art_max_width, art_max_height), Image.Resampling.LANCZOS if hasattr(Image, "Resampling") else Image.ANTIALIAS)
        art_width, art_height = art_img.size
        
        # Create dark canvas
        canvas = Image.new('RGB', canvas_size, color='#1a1a1a')
        
        # Place art on the right side, vertically centered
        art_x = canvas_width - art_width
        art_y = (canvas_height - art_height) // 2
        canvas.paste(art_img, (art_x, art_y))
        
        # Draw metadata text on the left
        draw = ImageDraw.Draw(canvas)
        
        # Try to load a font, fallback to default
        try:
            font_large = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 36)
            font_medium = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 28)
            font_small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 24)
        except:
            font_large = font_medium = font_small = ImageFont.load_default()
        
        # Starting position for text (left side with padding)
        text_x = 40
        text_y = 20  # Moved up further (was 40, originally 80)
        max_text_width = art_x - 80  # Leave space before art
        
        # Draw Artist
        artist = metadata.get('artist', 'Unknown Artist')
        if artist:
            draw.text((text_x, text_y), f"Artist:", font=font_small, fill='#888888')
            text_y += 35
            # Wrap artist name if too long
            artist_lines = wrap_text(artist, draw, font_large, max_text_width)
            for line in artist_lines:
                draw.text((text_x, text_y), line, font=font_large, fill='#ffffff')
                text_y += 45
        
        text_y += 10  # Reduced spacing more (was 15)
        
        # Draw Album
        album = metadata.get('album', '')
        if album:
            draw.text((text_x, text_y), f"Album:", font=font_small, fill='#888888')
            text_y += 35
            album_lines = wrap_text(album, draw, font_medium, max_text_width)
            for line in album_lines:
                draw.text((text_x, text_y), line, font=font_medium, fill='#cccccc')
                text_y += 38
        
        text_y += 10  # Reduced spacing more (was 15)
        
        # Draw Title
        title = metadata.get('title', '')
        if title:
            draw.text((text_x, text_y), f"Track:", font=font_small, fill='#888888')
            text_y += 35
            title_lines = wrap_text(title, draw, font_medium, max_text_width)
            for line in title_lines:
                draw.text((text_x, text_y), line, font=font_medium, fill='#cccccc')
                text_y += 38
        
        return canvas
    except Exception:
        logging.exception("Failed to create composite, returning resized art only")
        art_img.thumbnail(canvas_size, Image.Resampling.LANCZOS if hasattr(Image, "Resampling") else Image.ANTIALIAS)
        return art_img


def wrap_text(text: str, draw, font, max_width: int) -> list:
    """Wrap text to fit within max_width"""
    words = text.split()
    lines = []
    current_line = []
    
    for word in words:
        test_line = ' '.join(current_line + [word])
        bbox = draw.textbbox((0, 0), test_line, font=font)
        width = bbox[2] - bbox[0]
        
        if width <= max_width:
            current_line.append(word)
        else:
            if current_line:
                lines.append(' '.join(current_line))
            current_line = [word]
    
    if current_line:
        lines.append(' '.join(current_line))
    
    return lines if lines else [text]


def fetch_and_save(client: MPDClient, cfg: dict, outdir: Path) -> None:
    try:
        song = client.currentsong() or {}
        if not song:
            logging.info("No song playing")
            with _STATE_LOCK:
                _STATE.update({"artist": "", "album": "", "title": "", "last_error": "No song"})
            return
        uri = song.get("file")
        with _STATE_LOCK:
            _STATE["artist"] = song.get("artist", "")
            _STATE["album"] = song.get("album", "")
            _STATE["title"] = song.get("title", "")
        if not uri:
            logging.info("No file URI in currentsong")
            return
        resp = client.albumart(uri)
        data = normalize_albumart_response(resp)
        if not data:
            logging.info("No albumart bytes extracted")
            if cfg.get("default_image"):
                try:
                    dst = outdir / cfg["current_filename"]
                    shutil.copy(cfg["default_image"], str(dst))
                    with _STATE_LOCK:
                        _STATE["last_fetch"] = time.time()
                        _STATE["last_error"] = "default image used"
                    return
                except Exception:
                    logging.exception("Failed to copy default image")
                    with _STATE_LOCK:
                        _STATE["last_error"] = "failed to use default"
                    return
            with _STATE_LOCK:
                _STATE["last_error"] = "no album art"
            return
        target = outdir / cfg["current_filename"]
        size = tuple(cfg.get("resize", [800, 480]))
        metadata = {
            'artist': song.get('artist', ''),
            'album': song.get('album', ''),
            'title': song.get('title', '')
        }
        try_resize_and_save(data, target, size, metadata)
        with _STATE_LOCK:
            _STATE["last_fetch"] = time.time()
            _STATE["last_error"] = ""
        logging.info("Saved current art to %s", target)
    except (MPDError, CommandError) as e:
        logging.exception("MPD error fetching albumart: %s", e)
        with _STATE_LOCK:
            _STATE["last_error"] = str(e)
    except Exception:
        logging.exception("Unexpected error in fetch_and_save")
        with _STATE_LOCK:
            _STATE["last_error"] = "unexpected error"


class MiniHandler(BaseHTTPRequestHandler):
    server_version = "mpd-art-http/0.1"

    def do_GET(self):
        cfg = self.server.cfg
        outdir = Path(cfg["output_dir"])
        if self.path.startswith("/current.jpg"):
            path = outdir / cfg["current_filename"]
            if not path.exists():
                self.send_error(HTTPStatus.NOT_FOUND, "No image")
                return
            try:
                with open(path, "rb") as f:
                    data = f.read()
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception:
                logging.exception("Failed to serve current.jpg")
                self.send_error(HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        if self.path.startswith("/status.json"):
            with _STATE_LOCK:
                st = dict(_STATE)
            if st.get("last_fetch"):
                st["last_fetch"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st["last_fetch"]))
            else:
                st["last_fetch"] = None
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(st).encode("utf-8"))
            return

        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_POST(self):
        cfg = self.server.cfg
        if self.path.startswith("/fetch"):
            try:
                from urllib.parse import urlparse, parse_qs
                q = urlparse(self.path).query
                params = parse_qs(q)
                token = params.get("token", [""])[0]
                if token != cfg.get("http_token"):
                    self.send_error(HTTPStatus.FORBIDDEN, "Invalid token")
                    return
                t = threading.Thread(target=self.server.trigger_fetch)
                t.daemon = True
                t.start()
                self.send_response(HTTPStatus.ACCEPTED)
                self.end_headers()
                self.wfile.write(b"fetching\n")
                return
            except Exception:
                logging.exception("Failed to handle /fetch")
                self.send_error(HTTPStatus.INTERNAL_SERVER_ERROR)
                return
        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def log_message(self, format, *args):
        logging.info("%s - - %s", self.address_string(), format % args)


class MiniHTTPServer(ThreadingHTTPServer):
    def __init__(self, server_address, RequestHandlerClass, cfg, trigger_cb):
        super().__init__(server_address, RequestHandlerClass)
        self.cfg = cfg
        self.trigger_cb = trigger_cb

    def trigger_fetch(self):
        try:
            self.trigger_cb()
        except Exception:
            logging.exception("trigger_fetch callback failed")


def display_image(path: str, cfg: dict) -> None:
    logging.info("display_image called with path: %s", path)
    cmd_override = cfg.get("display_cmd", "").strip()
    if cmd_override:
        cmd = cmd_override.format(path=path)
        try:
            subprocess.run(cmd, shell=True, check=True)
            return
        except Exception:
            logging.exception("Custom display failed, falling back")

    # Use fbi to display the image (which now has metadata overlay from Python)
    fbi = shutil.which("fbi")
    logging.info("fbi path: %s", fbi)
    if fbi:
        # Kill any existing fbi processes first
        logging.info("Killing existing fbi processes")
        subprocess.run(["pkill", "-f", "fbi"], check=False)
        
        # Try fbi with full options for proper framebuffer display
        try:
            fbi_cmd = [
                fbi,
                "-T", "1",           # Target TTY 1
                "-d", "/dev/fb0",    # Framebuffer device
                "-a",                # Autozoom to fill screen
                "--noverbose",       # Hide filename/info text
                path
            ]
            logging.info("Running fbi command: %s", " ".join(fbi_cmd))
            subprocess.run(fbi_cmd, check=True)
            logging.info("FBI command completed successfully")
            return
        except Exception:
            logging.exception("fbi with TTY/FB options failed; trying simple mode")
            # Fallback: try without TTY specification
            try:
                subprocess.run([
                    fbi,
                    "-d", "/dev/fb0",
                    "-a",
                    "--noverbose",
                    path
                ], check=True)
                return
            except Exception as e:
                logging.exception("fbi fallback failed: %s", str(e))
    else:
        logging.error("fbi not found - cannot display images")

    # HTTP consumer will read current file; no-op otherwise


def run_http_server(cfg: dict, trigger_cb):
    bind = cfg.get("http_bind", "127.0.0.1")
    port = int(cfg.get("http_port", 8080))
    server = MiniHTTPServer((bind, port), MiniHandler, cfg, trigger_cb)
    logging.info("Starting HTTP server on %s:%d", bind, port)
    try:
        server.serve_forever()
    except Exception:
        logging.exception("HTTP server exited")


def run_service(cfg: dict):
    outdir = ensure_output_dir(cfg)
    logging.info("Service config: %s", json.dumps(cfg))
    http_thread = threading.Thread(target=run_http_server, args=(cfg, lambda: trigger_fetch_once(cfg, outdir)))
    http_thread.daemon = True
    http_thread.start()

    while not _SHUTDOWN:
        if MPDClient is None:
            logging.error("python-mpd2 not installed; sleeping")
            time.sleep(10)
            continue
        client = MPDClient()
        client.timeout = 3600
        client.idletimeout = None
        try:
            if cfg.get("use_socket") and cfg.get("mpd_socket"):
                client.connect(unixsocket=cfg["mpd_socket"])  # type: ignore[arg-type]
            else:
                client.connect(cfg.get("mpd_host", "localhost"), int(cfg.get("mpd_port", 6600)))
            if cfg.get("mpd_password"):
                try:
                    client.password(cfg.get("mpd_password"))
                except Exception:
                    logging.exception("MPD password failed")
            logging.info("Connected to MPD, fetching initial art")
            fetch_and_save(client, cfg, outdir)
            # Display immediately after the initial fetch if the file exists
            current = outdir / cfg["current_filename"]
            if current.exists():
                display_image(str(current), cfg)
            while not _SHUTDOWN:
                try:
                    subsystems = client.idle("player")
                    logging.info("IDLE change: %s", subsystems)
                    fetch_and_save(client, cfg, outdir)
                    current = outdir / cfg["current_filename"]
                    if current.exists():
                        display_image(str(current), cfg)
                except Exception:
                    logging.exception("Error in idle loop, will reconnect")
                    break
        except Exception:
            logging.exception("MPD connect failed, retrying")
            time.sleep(5)
        finally:
            try:
                client.close()
                client.disconnect()
            except Exception:
                pass
        time.sleep(2)
    logging.info("Service stopped")


def trigger_fetch_once(cfg: dict, outdir: Path):
    if MPDClient is None:
        logging.error("python-mpd2 not available for manual fetch")
        return
    client = MPDClient()
    try:
        if cfg.get("use_socket") and cfg.get("mpd_socket"):
            client.connect(unixsocket=cfg["mpd_socket"])  # type: ignore[arg-type]
        else:
            client.connect(cfg.get("mpd_host", "localhost"), int(cfg.get("mpd_port", 6600)))
        if cfg.get("mpd_password"):
            try:
                client.password(cfg.get("mpd_password"))
            except Exception:
                pass
        fetch_and_save(client, cfg, outdir)
    except Exception:
        logging.exception("trigger_fetch_once failed")
    finally:
        try:
            client.close()
            client.disconnect()
        except Exception:
            pass


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--setup", action="store_true", help="Interactive setup")
    parser.add_argument("--config", help="Alternate config path")
    args = parser.parse_args(argv or sys.argv[1:])
    global CONFIG_PATH
    if args.config:
        CONFIG_PATH = Path(args.config)
    if args.setup:
        write_config_interactive()
        return 0
    cfg = read_config()
    Path(cfg["output_dir"]).mkdir(parents=True, exist_ok=True)
    try:
        run_service(cfg)
    except KeyboardInterrupt:
        logging.info("KeyboardInterrupt - exiting")
    except Exception:
        logging.exception("Unhandled exception")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
