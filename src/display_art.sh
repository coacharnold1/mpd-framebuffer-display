#!/bin/bash

# Enhanced Album Art Display with Metadata
# Displays album art RIGHT-justified with Artist/Album/Track info on the LEFT
# Original script: /home/fausto/display_art.sh (kept as backup)

# Configuration
ART_FILENAME="cover.jpg"
TEMP_IMAGE="/tmp/mpd_album_art.jpg"
COMPOSITE_IMAGE="/tmp/mpd_composite.jpg"
TARGET_TTY=1
MUSIC_ROOT="/media/music"
FALLBACK_IMAGE="/home/fausto/mpd_assets/default_art.jpg"

# Screen dimensions
SCREEN_WIDTH=1366
SCREEN_HEIGHT=768

# Album art sizing (max dimensions to maintain quality)
# Make it nearly full height to match original look
ART_MAX_WIDTH=950
ART_MAX_HEIGHT=750

# Helper Commands
KILL_FBI="/usr/bin/killall -9 fbi 2>/dev/null; /usr/bin/pkill -9 -f fbi 2>/dev/null"
CHVT_CMD="/usr/bin/chvt ${TARGET_TTY}"
FBI_CMD="/usr/bin/fbi -T ${TARGET_TTY} -d /dev/fb0 -a --noverbose"
MPC_CMD="/usr/bin/mpc current -f"
TR_CMD="/usr/bin/tr"
SLEEP_CMD="/usr/bin/sleep"

# Function to wrap text based on safe character width
wrap_for_display() {
    local text="$1"
    local max_chars="${2:-19}"  # Default 19, but accept custom value
    
    local result=""
    local line=""
    for word in $text; do
        if [ $((${#line} + ${#word} + 1)) -gt $max_chars ]; then
            # Line is full, save it and start new line
            if [ -n "$result" ]; then
                result="${result}
${line}"
            else
                result="$line"
            fi
            line="$word"
        else
            # Add word to current line
            if [ -z "$line" ]; then
                line="$word"
            else
                line="${line} ${word}"
            fi
        fi
    done
    # Add remaining line
    if [ -n "$line" ]; then
        if [ -n "$result" ]; then
            result="${result}
${line}"
        else
            result="$line"
        fi
    fi
    echo "$result"
}

# Function to create composite image with text and art
create_composite() {
    local art_file="$1"
    local artist="$2"
    local album="$3"
    local track_num="$4"
    local track_name="$5"
    
    # Get actual dimensions of the album art
    local art_dims=$(identify -format "%wx%h" "$art_file" 2>/dev/null)
    local orig_width=${art_dims%x*}
    local orig_height=${art_dims#*x}
    
    # Wrap all text elements to stay before art boundary
    artist=$(wrap_for_display "$artist")
    album=$(wrap_for_display "$album" 19)
    track_name=$(wrap_for_display "$track_name" 12)
    
    # Scale art to fill the space while maintaining aspect ratio
    # Use the max dimensions
    local art_width=$ART_MAX_WIDTH
    local art_height=$ART_MAX_HEIGHT
    
    # Maintain aspect ratio when scaling
    if [ "$orig_width" -gt 0 ] && [ "$orig_height" -gt 0 ]; then
        # Calculate what height we'd get with max width
        local calc_height=$((art_width * orig_height / orig_width))
        # If that exceeds max height, scale by height instead
        if [ "$calc_height" -gt "$ART_MAX_HEIGHT" ]; then
            art_height=$ART_MAX_HEIGHT
            art_width=$((art_height * orig_width / orig_height))
        else
            art_height=$calc_height
        fi
    fi
    
    # Calculate where the album art starts on screen
    # The art is right-justified, so it starts at: screen_width - art_width
    local art_start_x=$((SCREEN_WIDTH - art_width))
    # Set wrap limit 120px before the art starts (generous safety margin)
    local wrap_limit=$((art_start_x - 120))
    
    echo "Art starts at x=${art_start_x}, text wrap limit: ${wrap_limit}px"
    
    # Text area on the left (narrow, with padding)
    # Centered in the left half of the screen (~350px wide)
    local text_x=175
    local text_y=80
    local text_max_width=350
    
    # Create the composite image with a dark background
    convert -size ${SCREEN_WIDTH}x${SCREEN_HEIGHT} xc:'#1a1a1a' \
        -font DejaVu-Sans-Bold -pointsize 48 \
        -fill '#ffffff' \
        -annotate +50+80 "Artist:" \
        -pointsize 40 \
        -annotate +100+140 "$artist" \
        \
        -pointsize 48 \
        -fill '#ffffff' \
        -annotate +50+260 "Album:" \
        -pointsize 40 \
        -annotate +100+320 "$album" \
        \
        -pointsize 48 \
        -fill '#ffffff' \
        -annotate +50+520 "Track:" \
        -pointsize 40 \
        -annotate +100+580 "#${track_num} - ${track_name}" \
        \
        \( "$art_file" -resize ${art_width}x${art_height}! -background '#1a1a1a' -gravity center -extent ${art_width}x${art_height} \) \
        -gravity East -composite \
        "$COMPOSITE_IMAGE" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Function to handle stopped/paused state and display fallback art
display_fallback() {
    echo "Maestro-MPD is stopped, paused, or art not found. Displaying fallback image."
    $KILL_FBI
    
    if [ ! -f "$FALLBACK_IMAGE" ]; then
        echo "FATAL ERROR: Fallback image not found at $FALLBACK_IMAGE."
        exit 1
    fi
    
    $CHVT_CMD
    $FBI_CMD "$FALLBACK_IMAGE"
    exit 0
}

# --- Main Script Logic ---

/usr/bin/sleep 2

# 1. Get current song file path
SONG_FILE_REL_PATH=$($MPC_CMD "%file%" | $TR_CMD -d '\n\r')

echo "Processing song: $SONG_FILE_REL_PATH"

if [ -z "$SONG_FILE_REL_PATH" ] || [ "$SONG_FILE_REL_PATH" = "volume: unset" ]; then
    display_fallback
fi

# 2. Extract album directory
SONG_DIR_REL_PATH="${SONG_FILE_REL_PATH%/*}"
ALBUM_DIR="${MUSIC_ROOT}/${SONG_DIR_REL_PATH}"
ART_PATH="${ALBUM_DIR}/${ART_FILENAME}"

# 3. Find the album art file
if [ ! -f "$ART_PATH" ]; then
    ART_PATH="${ALBUM_DIR}/folder.jpg"
    if [ ! -f "$ART_PATH" ]; then
        echo "Album art files not found at: $ALBUM_DIR"
        display_fallback
    fi
fi

# Copy art to temp location
/usr/bin/cp "$ART_PATH" "$TEMP_IMAGE"
echo "Found album art at: $ART_PATH"

# 4. Extract metadata from MPD
ARTIST=$(/usr/bin/mpc current -f "%artist%" | $TR_CMD -d '\n\r')
ALBUM=$(/usr/bin/mpc current -f "%album%" | $TR_CMD -d '\n\r')
TRACK_NUM=$(/usr/bin/mpc current -f "%track%" | $TR_CMD -d '\n\r')
TRACK_NAME=$(/usr/bin/mpc current -f "%title%" | $TR_CMD -d '\n\r')

# Fallback to empty strings if metadata not available
ARTIST="${ARTIST:-Unknown Artist}"
ALBUM="${ALBUM:-Unknown Album}"
TRACK_NUM="${TRACK_NUM:-00}"
TRACK_NAME="${TRACK_NAME:-Unknown Track}"

echo "Metadata - Artist: $ARTIST | Album: $ALBUM | Track: $TRACK_NUM - $TRACK_NAME"

# 5. Create composite image
if create_composite "$TEMP_IMAGE" "$ARTIST" "$ALBUM" "$TRACK_NUM" "$TRACK_NAME"; then
    echo "Composite image created successfully"
    DISPLAY_IMAGE="$COMPOSITE_IMAGE"
else
    echo "Failed to create composite, falling back to original art"
    DISPLAY_IMAGE="$TEMP_IMAGE"
fi

# 6. Display the image
$KILL_FBI
$SLEEP_CMD 2
$CHVT_CMD
$FBI_CMD "$DISPLAY_IMAGE"
$SLEEP_CMD 1
/usr/bin/chvt 2 2>/dev/null || true
$SLEEP_CMD 0.5
$CHVT_CMD

echo "Image successfully displayed on TTY ${TARGET_TTY}."