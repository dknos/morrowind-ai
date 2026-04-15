#!/bin/bash
# Usage: ./switch-model.sh lore_agent gemini gemini-2.5-pro
#        ./switch-model.sh lore_agent ollama llama3.2
#        ./switch-model.sh lore_agent anthropic claude-sonnet-4-6
AGENT=$1
PROVIDER=$2
MODEL=$3
CONFIG=/home/nemoclaw/morrowind-ai/python/config.yaml

if [ -z "$AGENT" ] || [ -z "$PROVIDER" ]; then
  echo "Usage: $0 <agent> <provider> [model]"
  echo "Agents: lore_agent pixel_agent obs_director"
  echo "Providers: gemini openai anthropic ollama llamacpp"
  exit 1
fi

# Use Python to update the YAML safely (not sed -i)
python3 - <<EOF
import yaml, sys
with open('$CONFIG') as f:
    cfg = yaml.safe_load(f)
cfg['models']['$AGENT']['provider'] = '$PROVIDER'
if '$MODEL':
    cfg['models']['$AGENT']['model'] = '$MODEL'
with open('$CONFIG', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
print(f"Switched $AGENT -> provider=$PROVIDER model=${MODEL:-unchanged}")
print("Restart mw-bridge to apply: pm2 restart mw-bridge --namespace morrowind")
EOF
