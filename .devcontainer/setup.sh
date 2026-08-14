#!/usr/bin/env bash
# Installs everything needed to run the Godot EDITOR (a GUI app) inside a
# headless Codespace, by giving it a virtual display and exposing that
# display through a browser-based VNC viewer (noVNC) on port 6080.
#
# This is genuinely experimental — I (Claude) could not test this
# end-to-end myself, since my own sandbox has no network access to
# download Godot or apt packages. This script is built from known-working
# patterns for GUI apps in Codespaces, but the first real test of it is
# you actually running it. If something breaks, send me the exact error
# and we'll debug it together rather than me guessing blind.

set -e

echo "=== Installing X11/VNC stack ==="
sudo apt-get update -qq
sudo apt-get install -y -qq \
    xvfb x11vnc novnc websockify \
    fluxbox \
    wget unzip \
    > /dev/null

echo "=== Downloading Godot 4.3 (editor build) ==="
GODOT_VERSION="4.3-stable"
GODOT_ZIP="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${GODOT_ZIP}" -O /tmp/godot.zip
sudo mkdir -p /opt/godot
sudo unzip -q /tmp/godot.zip -d /opt/godot
sudo mv "/opt/godot/Godot_v${GODOT_VERSION}_linux.x86_64" /opt/godot/godot
sudo chmod +x /opt/godot/godot
sudo ln -sf /opt/godot/godot /usr/local/bin/godot
rm /tmp/godot.zip

echo "=== Writing the display-launcher script ==="
# Deliberately does NOT try to auto-locate or auto-launch the project —
# that requires knowing this repo's checkout path, which varies. Instead
# this just brings up the virtual display + VNC stack; you launch Godot
# itself afterward with a plain `godot -e` from inside the project folder,
# in a second terminal tab, with DISPLAY=:1 set.
sudo tee /usr/local/bin/start-godot-display.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
echo "Starting virtual display on :1 ..."
Xvfb :1 -screen 0 1280x800x24 &
sleep 2

export DISPLAY=:1

echo "Starting lightweight window manager..."
fluxbox &
sleep 1echo "Starting VNC server on the virtual display..."
x11vnc -display :1 -forever -nopw -quiet &
sleep 1

echo "Starting noVNC (browser-based VNC client) on port 6080..."
websockify --web=/usr/share/novnc/ 6080 localhost:5900 &
sleep 1

echo ""
echo "================================================================"
echo "  Display is up. Now:"
echo "  1. Open the PORTS tab in this Codespace, find port 6080,"
echo "     open it in your browser, and go to /vnc.html on that URL"
echo "     (or click 'vnc.html' if VS Code offers it directly)."
echo "  2. In a NEW terminal tab in this Codespace, run:"
echo "       cd reading-app"
echo "       DISPLAY=:1 godot -e"
echo "     The Godot editor will open — and since DISPLAY=:1 points at"
echo "     the virtual display this script just started, it'll appear"
echo "     in the browser VNC tab instead of erroring with 'no display'."
echo ""
echo "  This terminal needs to stay open and running — the display"
echo "  stack lives in these background processes."
echo "================================================================"
wait
EOF
sudo chmod +x /usr/local/bin/start-godot-display.sh

echo ""
echo "=== Setup complete ==="
echo "Run: start-godot-display.sh"
echo "(then follow the on-screen instructions it prints)"
