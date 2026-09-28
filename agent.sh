#!/bin/sh

task="$*"
history=""

while :; do
    prompt=$(cat <<EOF
You are a shell agent.

Task:
$task

Previous execution:
$history

Return EXACTLY ONE of:
COMMAND: <one shell command>
DONE: <short explanation>

Do not use markdown fences.
EOF
)

    response=$(curl -s $API_BASE/chat/completions \
      -H "Authorization: Bearer $VIBE_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg p "$prompt" \
        '{model:"xiaomi/mimo-v2.6-flash",
          messages:[{role:"user",content:$p}],
          temperature:0}')" |
      jq -r '.choices[0].message.content')

    case "$response" in
        COMMAND:\ *)
            cmd=${response#COMMAND: }

            printf '\n$ %s\n' "$cmd"
            printf 'Execute? [y/N] '
            read answer

            case "$answer" in
                y|Y)
                    output=$(sh -c "$cmd" 2>&1)
                    status=$?

                    printf '%s\n' "$output"

                    history="$history
$ $cmd
$output
exit=$status"
                    ;;
                *)
                    exit 0
                    ;;
            esac
            ;;
        DONE:\ *)
            printf '%s\n' "${response#DONE: }"
            exit 0
            ;;
        *)
            printf 'Unexpected LLM response:\n%s\n' "$response" >&2
            exit 1
            ;;
    esac
done
