# PROJECT.md — Detailed Description

## What this is

This repository is **not a single cohesive project**. It is a small
**collection of unrelated scripts** that happen to share a common theme:
they all talk to an OpenAI-compatible **chat-completions API** from the
command line. There is no shared library, no build system, no package
manifest and no test suite — each script is standalone and can be copied
out and used on its own.

The scripts come in two flavours:

* **Shell scripts** (`sh` + `curl` + `jq`) — the original, minimal versions.
* **Perl scripts** (Perl 5, core modules only) — richer rewrites of some of
  the shell scripts, with better input handling, error reporting and UX.

## Environment and dependencies

All scripts are configured through two environment variables:

| Variable    | Meaning                                              |
|-------------|------------------------------------------------------|
| `API_BASE`  | Base URL of the chat-completions API (no trailing `/chat/completions`; the scripts append it). |
| `VIBE_KEY`  | Bearer token sent as `Authorization: Bearer …`.      |

The model used by every script is hard-coded to `xiaomi/mimo-v2.6-flash`
with `temperature: 0` where the agent loops set it.

External tools required:

* **Shell scripts**: a POSIX `sh`, plus `curl` and `jq`.
* **Perl scripts**: Perl 5 with `JSON::PP` (in `llm.pl`; part of the Perl
  core distribution). The other Perl script shells out to `curl`/`jq` as
  well (`agenti.pl`).

## The scripts in detail

### 1. `llm.sh` — one-shot prompt (shell)

The simplest possible LLM client.

* Takes the prompt as command-line arguments (`"$*"` — single line).
* Builds a JSON request body with `jq -Rs` (the `-R`/`-s` flags slurp the
  prompt, so embedded newlines would be handled, although the argument
  form only passes one line).
* POSTs it to `$API_BASE/chat/completions` with `curl -s`.
* Extracts and prints `choices[0].message.content` with `jq -r`.

No error handling: a failed request or an API error object simply prints
nothing or the raw `null`.

### 2. `llm.pl` — one-shot prompt (Perl rewrite of `llm.sh`)

A sturdier reimplementation with the same purpose:

* **Input**: command-line arguments win if given; otherwise the whole of
  stdin is slurped, so multi-line prompts and piped files
  (`cat file.txt | perl llm.pl`) arrive intact. Interactive typing is
  possible too (finish with Ctrl-D).
* **Encoding**: input bytes are decoded as UTF-8 and output is re-encoded
  as UTF-8.
* **Request**: the JSON body is built with `JSON::PP` (canonical key
  order) and passed to `curl` via an open-pipe (list form, so no shell
  interpolation).
* **Response handling** — this is where it diverges from `llm.sh`:
  * propagates `curl` failures as warnings and a non-zero exit status;
  * validates the response structure (`choices[0].message.content`);
  * distinguishes "valid JSON but no content" (e.g. an API error object)
    from "not JSON at all" and reports both on stderr;
  * guarantees a trailing newline on success.

Exit status: `0` success, `1` bad/empty response, or `curl`'s own code.

### 3. `agent.sh` — non-interactive shell agent

A one-task agent loop driven from the command line:

```sh
./agent.sh <task described in words>
```

Protocol — the LLM must answer with exactly one of:

```
COMMAND: <one shell command>
DONE: <short explanation>
```

Loop:

1. Build a prompt containing the original task plus the *previous
   execution* history (commands run, their output, their exit status).
2. Call the API (temperature 0) and inspect the answer.
3. On `COMMAND:`: show the command, ask `Execute? [y/N]`. On `y` run it
   with `sh -c … 2>&1`, append the output and exit status to the history
   and loop again. On anything else, quit.
4. On `DONE:`: print the explanation and stop.
5. Anything else: print `Unexpected LLM response` on stderr and exit 1.

Context scope: **only the current task** — the history starts empty on
each invocation of the script. There is no conversation memory between
separate runs.

Safety: nothing is executed without the explicit `y` confirmation.

### 4. `agenti.sh` — interactive shell agent (shell)

The same agent loop as `agent.sh`, wrapped in a REPL:

* Prints a banner and repeatedly prompts `agent> `.
* `exit`/`quit` (or EOF) leave the loop; empty lines are skipped.
* Each task gets a **fresh, empty history**: the conversation context is
  *not* carried from one task to the next (the script header calls this
  "no conversation history").
* Aborting a command (`N`) aborts only the current task and returns to
  the `agent> ` prompt instead of terminating the script.

Otherwise identical protocol, API call and confirmation flow to
`agent.sh`.

### 5. `agenti.pl` — interactive shell agent with context (Perl)

The most elaborate script: a Perl rewrite of the interactive agent that
adds real conversation memory and polish.

* **Conversation context (default)**: every prompt sent to the LLM and
  every answer received is kept in `@messages` and replayed with each
  new request, so later tasks can build on everything asked, executed
  and answered before. With `--no-context` the list stays empty and each
  request carries only the current task (the amnesiac/old behaviour).
* **Command line**: `--no-context` and `-h/--help` (usage text describing
  options, environment and exit status); unknown options exit with
  status 2.
* **Same `COMMAND:`/`DONE:` protocol** and y/N confirmation as the shell
  agents; per-task execution history (`$history`) still feeds the prompt.
* **Colours**: subdued ANSI colours distinguish the parts of the output —
  green (user query/prompt), yellow (command + confirmation), cyan
  (program output), magenta (LLM answer).
* **Layout**: `print_block` keeps exactly one blank line between logical
  blocks of text, tracking whether a blank line is already on screen; it
  also behaves correctly when input comes from a pipe rather than a
  terminal (`-t STDIN` checks avoid double-echoing or missing newlines).
* **Implementation notes**: the JSON payload is built through
  `jq -n --arg …` (values passed as arguments, so quotes/newlines are
  safe), the API is called through a `curl | jq` pipeline via `qx{}`, and
  shell arguments are single-quote escaped by `sh_quote`. Command exit
  statuses are computed the way `sh` reports them (exit code, or
  `128+signal` when killed by a signal, `127` if exec failed).

## Typical session

```sh
export API_BASE="https://api.example.com/v1"
export VIBE_KEY="sk-…"

./llm.sh "Say hello"
perl llm.pl "Write a haiku about shells"

./agent.sh "show the three largest files under /tmp"

./agenti.sh                 # amnesiac REPL (shell)
perl agenti.pl               # REPL that remembers the conversation
perl agenti.pl --no-context  # same, but forgets previous tasks
```

## State of the repository

* No shared code — the two agent shell scripts and the Perl agent each
  contain their own copy of the prompt template and API-call logic.
* No tests, no CI, no dependency pinning; the model name is hard-coded
  in all five scripts.
* History/evolution visible in the scripts: `llm.sh` → `llm.pl`,
  `agent.sh` → `agenti.sh` → `agenti.pl`.

In short: five standalone command-line front-ends for a chat-completions
API — two one-shot prompt tools and three human-in-the-loop shell
agents — collected in one directory rather than a unified project.
