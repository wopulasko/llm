# llm — a handful of LLM command-line scripts

Not really a project: just a **collection of unrelated scripts** that all
talk to an OpenAI-compatible chat-completions API — a couple of one-shot
prompt tools and three human-in-the-loop shell agents.

## Requirements

- `sh`, `curl`, `jq` (shell scripts); Perl 5 (Perl scripts)
- Environment: `API_BASE` (API base URL) and `VIBE_KEY` (bearer token)
- Model `xiaomi/mimo-v2.6-flash` is hard-coded in every script

## The scripts

| Script | Language | What it does |
|--------|----------|--------------|
| `llm.sh`  | shell | Send one prompt (as arguments), print the reply. |
| `llm.pl`  | Perl  | Rewrite of `llm.sh`: multi-line/piped input, UTF-8, real error handling. |
| `agent.sh`   | shell | One-shot agent: run a task given on the command line, one confirmed command at a time. |
| `agenti.sh`  | shell | Interactive agent REPL; each task is handled independently (no memory between tasks). |
| `agenti.pl`  | Perl  | Interactive agent REPL with full conversation context (`--no-context` to disable), colours and `--help`. |

The shell agents (`agent.sh`, `agenti.sh`) ask the LLM for exactly one
of `COMMAND: <shell command>` or `DONE: <explanation>`, and nothing runs
until you answer `y` to the `Execute? [y/N]` prompt.  `agenti.pl` adds a
third reply type, `RESPONSE: <text>`: it decides on its own whether a
message needs a shell command or is just conversation, so ordinary chat
is answered with plain text and never triggers an unprovoked Bash
invocation.

Binary output is tolerated: `agenti.pl` strips NUL bytes from the
conversation before they are embedded in the `jq`/`curl` request, so
commands that print raw bytes cannot break the request pipeline.

## Quick start

```sh
export API_BASE="https://api.example.com/v1"
export VIBE_KEY="sk-…"

./llm.sh "Say hello"
perl llm.pl "Write a haiku about shells"
./agent.sh "show the three largest files under /tmp"
./agenti.sh
perl agenti.pl
```

See [PROJECT.md](PROJECT.md) for the detailed description of each script.
