#!/bin/sh

prompt="$*"

curl -s $API_BASE/chat/completions \
  -H "Authorization: Bearer $VIBE_KEY" \
  -H "Content-Type: application/json" \
  -d "$(printf '%s' "$prompt" | jq -Rs \
    '{model:"xiaomi/mimo-v2.6-flash",messages:[{role:"user",content:.}]}')" |
  jq -r '.choices[0].message.content'
 
