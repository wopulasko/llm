#!/bin/sh

## Interactive shell agent: no conversation history ##

printf 'Interactive shell agent. Type a task, or "exit" to quit.\n'

while :; do
    printf 'agent> '
    IFS= read -r task || exit 0

    case "$task" in
        exit|quit)
            exit 0
            ;;
        '')
            continue
            ;;
    esac

    history=""

    while :; do
        prompt=$(cat <<PROMPT
You are a shell agent.

Task:
$task

Previous execution:
$history

Return EXACTLY ONE of:
COMMAND: <one shell command>
DONE: <short explanation>

Do not use markdown fences.
PROMPT
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
                        printf 'Task aborted.\n'
                        break
                        ;;
                esac
                ;;
            DONE:\ *)
                printf '%s\n' "${response#DONE: }"
                break
                ;;
            *)
                printf 'Unexpected LLM response:\n%s\n' "$response" >&2
                break
                ;;
        esac
    done
done
