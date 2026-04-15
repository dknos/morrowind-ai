#!/bin/bash
set -e
PROJECT=/home/nemoclaw/morrowind-ai
PYTHON=$(which python3)

echo "=== Morrowind AI Setup ==="

# Create dirs
mkdir -p $PROJECT/{ipc/events,chroma,logs}

# Create venv (isolated)
cd $PROJECT/python
$PYTHON -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt

echo ""
echo "=== Setup complete ==="
echo "Next steps:"
echo "1. Install OpenMW 0.49+"
echo "2. Copy openmw-mod/ into your OpenMW data directory"
echo "3. Add to openmw.cfg: data=\"/home/nemoclaw/morrowind-ai/openmw-mod\""
echo "4. Edit python/config.yaml — set stream.youtube_video_id if streaming"
echo "5. Start: pm2 start /home/nemoclaw/morrowind-ai/pm2.morrowind.config.js"
echo "6. Verify: pm2 list --namespace morrowind"
