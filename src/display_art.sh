#!/bin/bash

# Configuration
ART_FILENAME="cover.jpg" # Common name for album art file
TEMP_IMAGE="/tmp/mpd_album_art.jpg"
TARGET_TTY=1             # The Virtual Terminal (console) connected to your monitor

# --- CRITICAL PATHS (Corrected) ---
# This is the new, corrected base path based on your mounts.
# All paths returned by mpc will be relative to this location.
MUSIC_ROOT="/media/music"
# *** CHANGE THIS ***: Replace with the full path to an image file that ACTUALLY EXISTS on your system.
FALLBACK_IMAGE="/home/fausto/mpd_assets/default_art.jpg" 
# --- END OF CONFIGURATION ---

# --- Helper Commands (using full paths for safety) ---
KILL_FBI="/usr/bin/killall -9 fbi 2>/dev/null; /usr/bin/pkill -9 -f fbi 2>/dev/null"
CHVT_CMD="/usr/bin/chvt ${TARGET_TTY}"
FBI_CMD="/usr/bin/fbi -T ${TARGET_TTY} -d /dev/fb0 -a --noverbose"
MPC_CMD="/usr/bin/mpc current -f"
CP_CMD="/usr/bin/cp"
TR_CMD="/usr/bin/tr"
SLEEP_CMD="/usr/bin/sleep"

# Function to handle stopped/paused state and display fallback art
display_fallback() {
    echo "Maestro-MPD is stopped, paused, or art not found. Displaying fallback image."
    $KILL_FBI
    
    # Check if the fallback image exists
    if [ ! -f "$FALLBACK_IMAGE" ]; then
        echo "FATAL ERROR: Fallback image not found at $FALLBACK_IMAGE. Please fix the path."
        exit 1
    fi
    
    $CHVT_CMD
    $FBI_CMD "$FALLBACK_IMAGE"
    exit 0
}

# --- Script Logic ---

# Wait a moment to ensure MPD has fully updated
/usr/bin/sleep 2

# 1. Get the current song's full relative path from MPD
# Trimming newline/carriage-return characters for safety
SONG_FILE_REL_PATH=$($MPC_CMD "%file%" | $TR_CMD -d '\n\r')

# Debug: Log what song we're processing
echo "Processing song: $SONG_FILE_REL_PATH"

# Check if MPD is playing anything
if [ -z "$SONG_FILE_REL_PATH" ] || [ "$SONG_FILE_REL_PATH" = "volume: unset" ]; then
    display_fallback
fi

# 2. Extract the relative album directory path (e.g., 'mrbig/Album Name/...')
# This removes the shortest match for '/*' (the filename) from the end of the string.
SONG_DIR_REL_PATH="${SONG_FILE_REL_PATH%/*}"

# 3. Construct the full absolute path to the album art file
ALBUM_DIR="${MUSIC_ROOT}/${SONG_DIR_REL_PATH}"
ART_PATH="${ALBUM_DIR}/${ART_FILENAME}"

# 4. Check if the album art file exists and prepare the final image
if [ -f "$ART_PATH" ]; then
    $CP_CMD "$ART_PATH" "$TEMP_IMAGE"
    echo "Found and copied album art from: $ART_PATH"
else
    # 4b. If cover.jpg is not found, try the secondary filename (folder.jpg)
    ART_PATH="${ALBUM_DIR}/folder.jpg"
    if [ -f "$ART_PATH" ]; then
        $CP_CMD "$ART_PATH" "$TEMP_IMAGE"
        echo "Found and copied secondary album art from: $ART_PATH"

    else
    # 4-C If the specific cover file is not found, jump to the fallback function
    	echo "Album art files (cover.jpg or folder.jpg) not found at: $ALBUM_DIR"
    	display_fallback
    fi
fi

# 5. Display the prepared image
# Kill old fbi aggressively, wait, then start new fbi and force display refresh
$KILL_FBI
$SLEEP_CMD 2
$CHVT_CMD
$FBI_CMD "$TEMP_IMAGE"
# Force display refresh by briefly switching TTYs
$SLEEP_CMD 1
/usr/bin/chvt 2 2>/dev/null || true
$SLEEP_CMD 0.5
$CHVT_CMD

echo "Image successfully displayed on TTY ${TARGET_TTY}."