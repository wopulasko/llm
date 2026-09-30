#!/usr/bin/env perl

## Interactive shell agent: it holds the context of the conversation  ##
## and keeps a persistent memory of plain Markdown files at           ##
## ~/.agent_memory (index.md, session_log.md and knowledge pages).    ##
## Pass --no-context to work without the previous conversation        ##
## (amnesiac).                                                        ##

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Path qw(make_path);
use POSIX qw(strftime);

# Subdued, conventional ANSI colours:
#   green   - user query
#   yellow  - y/N confirmation
#   cyan    - program output (results of a Bash command), memory notices
#   magenta - the LLM's answer
my $GREEN   = "\e[32m";
my $YELLOW  = "\e[33m";
my $CYAN    = "\e[36m";
my $MAGENTA = "\e[92m";
my $RESET   = "\e[0m";

$| = 1;    # show prompts before reading

# Output comes in logical blocks of text (query, confirmation, command
# output, report).  print_block keeps exactly one blank line between
# them; this flag remembers whether one is already on the screen.
my $after_blank = 0;

## The canonical knowledge base: a directory of Markdown files whose  ##
## lightweight index lives at index.md and whose running session log  ##
## lives at session_log.md.  Everything is plain text: it is          ##
## inspected and edited by hand, and the agent only ever adds to it.  ##
sub home_dir {
    return $ENV{HOME} if defined $ENV{HOME} && length $ENV{HOME};
    my @pw = getpwuid($<);
    return @pw ? $pw[7] : '';
}
my $HOME_DIR = home_dir();
my $MEM_DIR  = length $HOME_DIR ? "$HOME_DIR/.agent_memory" : '';

my $mem_ready    = 0;    # the memory directory is usable
my $session_open = 0;    # a session header was logged; END closes it

END {
    log_event('session ended') if $session_open;
}

## Command line switches ##
my $want_help = grep { $_ eq '--help' || $_ eq '-h' } @ARGV;

if ($want_help) {
    print <<'HELP';
Usage: agenti.pl [--no-context] [--help]

Interactive shell agent with persistent memory.  Type a task,
confirm the shell commands it proposes and it will execute them for
you.  Ordinary conversation is answered directly, with no shell
command involved.

By default the agent holds the context of the conversation: every new
task can build on everything that was asked, executed and answered
before.  It also starts each run from the persistent memory kept in
~/.agent_memory, so knowledge recorded in one session is available in
the next one.

Persistent memory (~/.agent_memory):
The canonical knowledge base: a directory of plain Markdown files
that can be inspected and edited by hand.  Information is only ever
added - new notes, log lines and index entries never destroy what is
already there.
  index.md        lightweight index listing every page and folder
                  with a brief description; relative Markdown links
                  turn the store into a navigable knowledge graph.
  session_log.md  running log of notable events and decisions,
                  appended by every session, never rewritten.
  *.md pages      knowledge preserved from earlier sessions.

Options:
      --no-context   Hold no previous context: every task is
                     handled independently, as if it were the first
                     one, and the persistent memory is not loaded
                     at startup.
  -h, --help         Display this help and exit.

Commands (typed at the agent> prompt, handled locally):
  /codebase [pattern ...]  Read the matching files into the
                           conversation context.  Patterns are
                           shell-like wildcards (* and ?) looked up
                           among the files below the current
                           directory (recursively); several patterns
                           may be combined ("*py *md*"), the default
                           is "*".  Files that match more than one
                           pattern are read only once.
  /memory [pattern ...]    Read pages of the persistent memory
                           (~/.agent_memory) into the conversation
                           context.  Patterns as for /codebase,
                           matched among the memory files; the
                           default "*" reads every page.
  /index                   Show the memory index (index.md).
  /remember [page.md] text Append text as a dated note to the given
                           memory page (notes.md when no page is
                           given); a new page and its index entry
                           are created as needed.
  /log text                Append an entry to session_log.md.
  /prune                   Forget the conversation so far and
                           return to the agent's system prompt, as
                           if the conversation were starting fresh.
                           The persistent memory is left untouched.

The agent itself persists knowledge with replies of the form
  MEMORY: [page.md] <note>
which append a short Markdown note to a memory page.

Environment:
  API_BASE  Base URL of the chat-completions API.
  VIBE_KEY  Bearer token for the API.
  HOME      Home directory whose .agent_memory holds the memory.

Exit status:
  0  success
  2  invalid command-line option
HELP
    exit 0;
}

my $no_context = 0;
for my $arg (@ARGV) {
    if ($arg eq '--no-context') {
        $no_context = 1;
    }
    else {
        print STDERR "agenti.pl: invalid option '$arg'\n";
        print STDERR "Try 'agenti.pl --help' for more information.\n";
        exit 2;
    }
}

# Make sure the knowledge base exists before the first turn: the
# directory, the canonical index and the session log are created on
# demand, so a fresh home directory bootstraps a working memory.
$mem_ready = memory_init();
$session_open = log_session_start() if $mem_ready;

print $CYAN . 'Interactive shell agent. Type a task, or "exit" to quit.'
    . $RESET . "\n";
print $CYAN . 'Persistent memory: '
    . ($mem_ready ? $MEM_DIR : '(unavailable)') . $RESET . "\n";

# The conversation so far, oldest first: every prompt shown to the LLM
# and every answer it gave.  With --no-context this list stays empty,
# so each request carries nothing but the current task (the old
# behaviour) - not even the memory snapshot pushed below.
my @messages;

# A snapshot of the persistent memory (index plus the recent log) is
# the first thing the LLM sees, which is what makes the agent pick up
# where the previous session left off.  /prune returns to it as well.
my $memory_snapshot = $mem_ready ? memory_snapshot() : undef;
push @messages, { role => 'user', content => $memory_snapshot }
    if defined $memory_snapshot && !$no_context;

while (1) {
    print $GREEN . 'agent> ' . $RESET;
    my $task = <STDIN>;
    exit 0 unless defined $task;
    chomp $task;

    # A terminal has already echoed what was typed; print the query in the
    # user-query colour only when the input came from a pipe or a file.
    print $GREEN . $task . $RESET . "\n" unless -t STDIN;
    $after_blank = 0;    # the query now stands on a line of its own

    if ($task eq 'exit' || $task eq 'quit') {
        exit 0;
    }
    next if $task eq '';

    # Local slash commands: they reshape the conversation context on
    # the spot and are never sent to the LLM as a task of their own.
    if ($task =~ m{\A/codebase(?:\s+(.*))?\z}s) {
        # Copy $1 out immediately: any later match would reset it.
        my $patterns = $1 // '';
        $patterns =~ s/\A\s+//;
        $patterns =~ s/\s+\z//;
        $patterns = '*' unless length $patterns;
        codebase_load($patterns);
        next;
    }

    if ($task =~ m{\A/memory(?:\s+(.*))?\z}s) {
        my $patterns = $1 // '';
        $patterns =~ s/\A\s+//;
        $patterns =~ s/\s+\z//;
        $patterns = '*' unless length $patterns;
        memory_load($patterns);
        next;
    }

    if ($task =~ m{\A/index\s*\z}s) {
        show_index();
        next;
    }

    if ($task =~ m{\A/remember(?:\s+(.*))?\z}s) {
        my $args = $1 // '';
        $args =~ s/\A\s+//;
        $args =~ s/\s+\z//;
        if (!length $args
            || $args =~ /\A[A-Za-z0-9][A-Za-z0-9_.\/\-]*\.md\s*\z/i) {
            print_block($YELLOW
                . 'Usage: /remember [page.md] <note text>' . $RESET
                . "\n");
        }
        else {
            my ($page, $note) = ('notes.md', $args);
            if ($args =~ /\A([A-Za-z0-9][A-Za-z0-9_.\/\-]*\.md)\s+(.+)\z/s)
            {
                ($page, $note) = ($1, $2);
            }
            $note =~ s/\A\s+//;
            $note =~ s/\s+\z//;
            my ($rel, $err) = memory_note($page, $note);
            if (defined $rel) {
                print_block($CYAN . "Remembered in $MEM_DIR/$rel"
                    . $RESET . "\n");
                log_event("note appended to $rel");
                push @messages,
                    { role    => 'user',
                      content => "Note appended to the persistent"
                        . " memory page $rel." };
            }
            else {
                print_block($YELLOW . "Not saved: $err" . $RESET . "\n");
            }
        }
        print "\n";
        $after_blank = 1;
        next;
    }

    if ($task =~ m{\A/log(?:\s+(.*))?\z}s) {
        my $text = $1 // '';
        $text =~ s/\A\s+//;
        $text =~ s/\s+\z//;
        if (!length $text) {
            print_block($YELLOW . 'Usage: /log <event text>' . $RESET
                . "\n");
        }
        elsif (log_event($text)) {
            print_block($CYAN . 'Appended to session_log.md.' . $RESET
                . "\n");
        }
        else {
            print_block($YELLOW . 'Could not append to session_log.md.'
                . $RESET . "\n");
        }
        print "\n";
        $after_blank = 1;
        next;
    }

    if ($task =~ m{\A/prune\s*\z}s) {
        # Drop everything the conversation accumulated: the next
        # request starts from the agent's system prompt (plus the
        # persistent memory snapshot), just as if this were the first
        # message ever asked.  The memory files themselves are
        # persistent and stay exactly as they are.
        @messages = ();
        push @messages, { role => 'user', content => $memory_snapshot }
            if defined $memory_snapshot && !$no_context;
        log_event('conversation context pruned');
        print_block($CYAN . 'Context pruned: back to the system prompt,'
            . ' as in a fresh conversation.  Persistent memory kept.'
            . $RESET . "\n");
        print "\n";
        $after_blank = 1;
        next;
    }

    my $history = '';
    my $ran      = 0;
    my $outcome;    # how the task ended, summarised for the session log

    while (1) {
        my $prompt = <<"PROMPT";
You are a shell agent.

Task:
$task

Previous execution:
$history

Persistent memory:
A knowledge base of plain Markdown files lives in ~/.agent_memory;
index.md lists every page and folder with a brief description, and
the user can read pages to you with /memory.  When this task produced
knowledge worth keeping for future sessions, reply once with

MEMORY: [page.md] <short Markdown note>

(page optional, notes.md by default).  The note is appended without
touching anything already stored, so never try to overwrite memory
files through COMMAND.

Return EXACTLY ONE of:
COMMAND: <one shell command>
RESPONSE: <plain-text reply to the user>
MEMORY: <knowledge worth persisting>
DONE: <short explanation>

Use COMMAND only when a shell command must be run to accomplish the
task.  Use RESPONSE for ordinary conversation: greetings, questions,
small talk and any message that needs no shell - answer with text
alone and never invoke a shell just to reply.  Use MEMORY to persist
a short note in the knowledge base; the conversation continues
afterwards, so follow it with DONE (or with the next step).  Use
DONE when the executed commands have completed the task; add a short
explanation.

Do not use markdown fences.
PROMPT
        chomp $prompt;

        my $response = llm_response($prompt, \@messages);
        $response = '' unless defined $response;

        # Remember this exchange so later tasks can refer back to it.
        push @messages, { role => 'user',      content => $prompt },
                        { role => 'assistant', content => $response }
            unless $no_context;

        if ($response =~ /^COMMAND: /) {
            my $cmd = substr($response, length('COMMAND: '));

            print_block($YELLOW . '$ ' . $cmd . $RESET . "\n");
            print $YELLOW . 'Execute? [y/N] ' . $RESET;
            my $answer = <STDIN>;
            $answer = '' unless defined $answer;
            chomp $answer;
            $answer =~ s/^\s+//;
            $answer =~ s/\s+$//;

            # End the confirmation line: a terminal echoed the answer,
            # a pipe did not.  The blank line keeps the answer and
            # whatever it triggered apart as separate blocks of text.
            print "\n" unless -t STDIN;
            print "\n";
            $after_blank = 1;

            if ($answer eq 'y' || $answer eq 'Y') {
                my ($output, $status) = run_command($cmd);
                $ran++;

                print_block($CYAN . $output . $RESET . "\n")
                    if length $output;

                $history .= "\n" . '$ ' . $cmd . "\n" . $output
                    . "\n" . 'exit=' . $status;
                log_event('$ ' . log_summary($cmd));
            }
            else {
                print_block($CYAN . 'Task aborted.' . $RESET . "\n");
                $outcome = 'aborted by the user';
                last;
            }
        }
        elsif ($response =~ /^RESPONSE: /) {
            my $msg = substr($response, length('RESPONSE: '));
            print_block($MAGENTA . $msg . $RESET . "\n");
            # A chat answer ends this turn just like DONE, but nothing
            # was executed, so the execution history stays untouched.
            $outcome = 'replied: ' . log_summary($msg);
            print "\n";
            $after_blank = 1;
            last;
        }
        elsif ($response =~ /^MEMORY:\s*(.*)\z/s) {
            # Persist knowledge: the note is appended to a memory
            # page, nothing that is already stored is touched, and
            # the turn continues so the LLM can follow up with DONE.
            my $rest = $1;
            $rest =~ s/\A[ \t\r\n]+//;
            $rest =~ s/[ \t\r\n]+\z//;
            my ($page, $note) = ('notes.md', $rest);
            if ($rest =~ /\A\[([A-Za-z0-9][A-Za-z0-9_.\/\-]*)\]\s*(.*)\z/s)
            {
                ($page, $note) = ($1, $2);
                $note =~ s/\A\s+//;
                $note =~ s/[ \t\r\n]+\z//;
            }
            if (!length $note) {
                print_block($YELLOW . 'MEMORY needs some text to store.'
                    . $RESET . "\n");
                $history .= "\nMemory: nothing was stored (empty note)."
                    . "  Reply DONE or try again.";
            }
            else {
                my ($rel, $err) = memory_note($page, $note);
                if (defined $rel) {
                    print_block($CYAN . "Remembered in $MEM_DIR/$rel"
                        . $RESET . "\n");
                    log_event("knowledge appended to $rel");
                    $history .= "\nSaved to persistent memory: $rel"
                        . " (appended; existing content untouched)."
                        . "  Reply DONE or continue.";
                }
                else {
                    print_block($YELLOW . "Not saved: $err" . $RESET
                        . "\n");
                    $history .= "\nCould not save to memory: $err."
                        . "  Pick another page or reply DONE.";
                }
            }
            print "\n";
            $after_blank = 1;
            next;
        }
        elsif ($response =~ /^DONE: /) {
            my $msg = substr($response, length('DONE: '));
            print_block($MAGENTA . $msg . $RESET . "\n");
            # The LLM's answer ends this turn: put a new line between
            # it and the prompt where the next question is asked.
            $outcome = 'done: ' . log_summary($msg);
            print "\n";
            $after_blank = 1;
            last;
        }
        else {
            print STDERR ($after_blank ? '' : "\n")
                . $CYAN . 'Unexpected LLM response:' . $RESET . "\n"
                . $MAGENTA . $response . $RESET . "\n";
            # Even a malformed answer ends this turn: keep the next
            # question on the far side of a new line as well.
            $outcome = 'gave an unexpected response';
            print "\n";
            $after_blank = 1;
            last;
        }
    }

    # One session-log line per task: what was asked, how many shell
    # commands ran and how the turn ended.
    if (defined $outcome) {
        my $ran_part = $ran
            ? " after $ran executed command" . ($ran == 1 ? '' : 's')
            : '';
        log_event('task "' . log_summary($task) . '"' . $ran_part
            . ' - ' . $outcome);
    }
}

## (Re)create the memory directory with its canonical skeleton:      ##
## index.md and session_log.md, both plain Markdown, both described  ##
## in the index.  Returns true when the directory is usable.         ##
sub memory_init {
    return 0 unless length $MEM_DIR;

    if (!-d $MEM_DIR) {
        eval { make_path($MEM_DIR) };
        if ($@ || !-d $MEM_DIR) {
            my $why = $@ || $! || 'unknown error';
            $why =~ s/\s+at \S+ line \d+\.?\s*\z//;
            print STDERR "agenti.pl: cannot create $MEM_DIR: $why\n";
            return 0;
        }
    }

    my @skeleton = (['index.md', bootstrap_index()],
                    ['session_log.md', bootstrap_log()]);
    for my $part (@skeleton) {
        my ($name, $boot) = @$part;
        next if -e "$MEM_DIR/$name";
        unless (append_file("$MEM_DIR/$name", $boot)) {
            print STDERR "agenti.pl: cannot create $MEM_DIR/$name: $!\n";
            return 0;
        }
    }

    # Keep the index complete: the system files are always listed,
    # and any page or folder a hand edit may have dropped from the
    # index is listed again with a generic description.
    memory_index_ensure('session_log.md',
        'running log of notable events and decisions, appended by every session');
    memory_heal_index();
    return 1;
}

## The canonical starting index; also written to ~/.agent_memory/    ##
## index.md the first time the agent runs.                           ##
sub bootstrap_index {
    return <<'INDEX';
# Memory Index

Lightweight index of the knowledge base kept in `~/.agent_memory`:
every page and folder listed with a brief description for quick
lookup.  All memory is plain Markdown, inspected and edited by hand;
entries are only ever added, existing ones are left alone.  The
relative Markdown links turn the whole store into a navigable
knowledge graph.

## Pages

- [session_log.md](session_log.md) — running log of notable events and decisions, appended by every session.

## Folders

- Sub-folders of the knowledge base are listed here as folder links.
INDEX
}

## The canonical starting session log.                              ##
sub bootstrap_log {
    return <<'LOG';
# Session Log

A running log of notable events and decisions from each session,
appended at the bottom and never rewritten, so old context always
outlives new entries.  Newest session last.
LOG
}

## Make sure $rel is listed in index.md with a brief description.    ##
## An existing entry (hand-written or not) is never touched; only a  ##
## missing bullet is added, under "## Pages" (or "## Folders" for    ##
## directories) when that section exists, at the end of the file     ##
## otherwise.                                                        ##
sub memory_index_ensure {
    my ($rel, $desc) = @_;
    return 0 unless length $MEM_DIR;

    my $idx = "$MEM_DIR/index.md";
    my $content = slurp($idx);
    if (!defined $content) {
        # The index went missing; restore the canonical skeleton and
        # list the page inside it.
        append_file($idx, bootstrap_index());
        $content = slurp($idx);
        $content = '' unless defined $content;
    }
    return 1 if $content =~ /\]\(\Q$rel\E\)/;   # already linked

    $desc = 'knowledge page' unless defined $desc && length $desc;
    $desc =~ s/[\r\n]+/ /g;
    $desc =~ s/\s+/ /g;
    $desc =~ s/[\[\]]//g;
    $desc =~ s/\s+\z//;
    $desc = substr($desc, 0, 70) . '...' if length $desc > 73;

    my $is_dir = $rel =~ m{/\z};
    my $section = $is_dir ? 'Folders' : 'Pages';
    my $bullet = "- [$rel]($rel) — $desc";

    my @lines = split /\n/, $content, -1;
    my $head  = -1;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /\A##\s+\Q$section\E\s*\z/) {
            $head = $i;
            last;
        }
    }

    if ($head >= 0) {
        # Insert right before the next section (or at the end of the
        # file), keeping every existing byte of the old content.
        my $at = $#lines + 1;
        for my $i ($head + 1 .. $#lines) {
            if ($lines[$i] =~ /\A##\s+/) {
                $at = $i;
                last;
            }
        }
        while ($at > $head + 1 && $lines[$at - 1] =~ /\A\s*\z/) {
            $at--;
        }
        splice @lines, $at, 0, $bullet;
        my $new = join("\n", @lines);
        return 1 if rewrite_file($idx, $new);
    }

    # No matching section: add one at the end of the index.
    my $cur = slurp($idx);
    $cur = $content unless defined $cur;
    return append_file($idx, "## $section\n\n$bullet\n") if $cur eq '';
    return append_file($idx, "\n## $section\n\n$bullet\n");
}

## Walk the knowledge base and (re)list every page and folder that   ##
## is missing from the index, so the graph stays navigable even      ##
## after manual edits.                                               ##
sub memory_heal_index {
    return unless length $MEM_DIR;

    my $root = $MEM_DIR;
    $root =~ s{/\z}{};
    my @tree = list_files($root);
    s{\A\Q$root\E/}{} for @tree;

    my %dirs;
    for my $rel (@tree) {
        my $dir = $rel;
        while ($dir =~ s{/[^/]+\z}{}) {
            $dirs{$dir} = 1;
        }
    }
    for my $dir (sort keys %dirs) {
        memory_index_ensure("$dir/", 'sub-folder of related memory pages');
    }
    for my $rel (sort @tree) {
        next if $rel eq 'index.md';
        next unless $rel =~ /\.md\z/i;
        memory_index_ensure($rel, 'knowledge page');
    }
    return 1;
}

## Append one note to a memory page, creating the page (and its      ##
## index entry, and any missing sub-folder) when needed.  Notes land  ##
## under a "## YYYY-MM-DD" heading, so days accumulate instead of     ##
## replacing each other.  Returns ($relative_path, undef) on success  ##
## or (undef, $reason) on failure.                                    ##
sub memory_note {
    my ($page, $text, $desc) = @_;
    return (undef, 'no persistent memory available') unless length $MEM_DIR;

    $page = 'notes.md' unless defined $page && length $page;
    $page =~ s/\A\s+//;
    $page =~ s/\s+\z//;
    $page = 'notes.md' unless length $page;

    $text = '' unless defined $text;
    $text =~ s/\A[\s]+//;
    $text =~ s/[\s]+\z//;
    return (undef, 'the note is empty') unless length $text;

    my $rel = $page;
    $rel .= '.md' if $rel !~ /\.md\z/i;
    my @parts = split m{/}, $rel, -1;
    if (grep { $_ eq '' || $_ eq '.' || $_ eq '..' } @parts
        || $rel !~ m{\A[A-Za-z0-9][A-Za-z0-9_.\-]*(?:/[A-Za-z0-9][A-Za-z0-9_.\-]*)*\z}) {
        return (undef, "invalid memory page name '$page'");
    }
    return (undef, 'index.md is maintained by the agent itself')
        if lc $rel eq 'index.md';
    return (undef, 'session_log.md is written with /log')
        if lc $rel eq 'session_log.md';

    # Create missing sub-folders and list each new one in the index.
    if (@parts > 1) {
        my $sub = '';
        for my $i (0 .. $#parts - 1) {
            $sub = length $sub ? "$sub/$parts[$i]" : $parts[$i];
            next if -d "$MEM_DIR/$sub";
            eval { make_path("$MEM_DIR/$sub") };
            if ($@ || !-d "$MEM_DIR/$sub") {
                return (undef, "cannot create folder $sub");
            }
            memory_index_ensure("$sub/",
                'sub-folder of related memory pages');
        }
    }

    my $abs   = "$MEM_DIR/$rel";
    my $is_new = !-e $abs;
    my $old   = $is_new ? '' : (slurp($abs) // '');
    $is_new = 1 unless length $old;

    my $append;
    if ($text =~ /\A#/) {
        # Long-form content (it brings its own heading): appended
        # verbatim, separated from what is already there.
        $append = ($old =~ /\S/ ? "\n---\n\n" : '') . $text . "\n";
    }
    else {
        my $prefix = '';
        if ($is_new) {
            my $stem = $rel;
            $stem =~ s{.*/}{};
            $stem =~ s/\.md\z//i;
            $prefix = '# ' . ucfirst($stem) . "\n";
        }
        my $last = '';
        for my $line (split /\n/, $old) {
            $last = $1 if $line =~ /\A##\s+(.*)\z/;
        }
        my $date  = strftime('%Y-%m-%d', localtime);
        my $head  = $last eq $date ? '' : "\n## $date\n";
        my @rows  = split /\n/, $text, -1;
        my $bullet = '- ' . (shift(@rows) // '');
        $bullet .= join('', map { "\n  $_" } @rows);
        $append = $prefix . $head . $bullet . "\n";
    }

    return (undef, "cannot append to $rel") unless append_file($abs, $append);
    memory_index_ensure($rel,
        defined $desc && length $desc ? $desc : note_desc($text));
    return ($rel, undef);
}

## A brief one-line description of a note, for the index entry of a  ##
## newly created page.                                               ##
sub note_desc {
    my ($text) = @_;
    $text = '' unless defined $text;
    my ($first) = split /\n/, $text;
    $first = '' unless defined $first;
    $first =~ s/\A#+\s*//;
    $first =~ s/\A[-*\s]+//;
    $first =~ s/\s+/ /g;
    $first =~ s/[\[\]]//g;
    $first =~ s/\s+\z//;
    return 'knowledge page' unless length $first;
    return substr($first, 0, 70) . '...' if length $first > 73;
    return $first;
}

## Append one timestamped line to session_log.md: the running log    ##
## of notable events and decisions.  Returns true on success.        ##
sub log_event {
    my ($text) = @_;
    return 0 unless length $MEM_DIR;
    $text = '' unless defined $text;
    $text =~ s/[\r\n]+/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/\s+\z//;
    return 0 unless length $text;
    my $hms = strftime('%H:%M:%S', localtime);
    return append_file("$MEM_DIR/session_log.md", "- $hms $text\n");
}

## Open a session section in the session log and record the start.   ##
sub log_session_start {
    return 0 unless length $MEM_DIR;
    my $stamp = strftime('%Y-%m-%d %H:%M:%S', localtime);
    my $hms   = strftime('%H:%M:%S', localtime);
    my $cwd   = getcwd();
    return append_file("$MEM_DIR/session_log.md",
        "\n## $stamp (agenti.pl pid $$)\n\n- $hms session started in $cwd\n");
}

## The memory as the LLM first sees it: the index in full (the       ##
## navigable map of every page) plus the tail of the session log     ##
## (what happened most recently).                                    ##
sub memory_snapshot {
    my $index = slurp("$MEM_DIR/index.md");
    return undef unless defined $index && $index =~ /\S/;
    my $log = slurp("$MEM_DIR/session_log.md");
    $log = '' unless defined $log;
    my @lines = split /\n/, $log;
    my $tail  = @lines > 60 ? join("\n", @lines[-60 .. $#lines]) : $log;

    return <<"SNAP";
Persistent memory: the canonical knowledge base at $MEM_DIR.
Plain Markdown files, appended to and edited by hand, never rewritten
by the agent.  index.md is the lightweight index of every page and
folder; the user can read pages with /memory.

=== index.md ===
$index

Recent session log (tail):

=== session_log.md ===
$tail
SNAP
}

## Print the memory index at the prompt.                             ##
sub show_index {
    my $content =
        length $MEM_DIR ? slurp("$MEM_DIR/index.md") : undef;
    if (!defined $content) {
        print_block($YELLOW . 'No memory index at '
            . (length $MEM_DIR ? "$MEM_DIR/index.md" : '~/.agent_memory')
            . $RESET . "\n");
    }
    else {
        $content .= "\n" unless $content =~ /\n\z/;
        print_block($CYAN . $content . $RESET . "\n");
    }
    print "\n";
    $after_blank = 1;
}

## Read memory pages matching the /memory patterns into the         ##
## conversation context (@messages).  Patterns work as for          ##
## /codebase but are matched among the files of ~/.agent_memory;     ##
## the default "*" pulls in the whole knowledge base.                ##
sub memory_load {
    my ($patterns) = @_;

    if (!length $MEM_DIR || !-d $MEM_DIR) {
        print_block($YELLOW . 'Persistent memory unavailable: no '
            . (length $MEM_DIR ? $MEM_DIR : '~/.agent_memory') . $RESET
            . "\n");
        print "\n";
        $after_blank = 1;
        return;
    }

    my @pat = grep { length } split ' ', $patterns;
    @pat = ('*') unless @pat;

    my $root = $MEM_DIR;
    $root =~ s{/\z}{};
    my @tree = list_files($root);
    s{\A\Q$root\E/}{} for @tree;

    my (@found, %seen);
    for my $pat (@pat) {
        if ($pat !~ /[*?]/ && -f "$root/$pat") {    # an explicit page
            push @found, $pat unless $seen{$pat}++;
            next;
        }
        my $re = pattern_to_regex($pat);
        for my $file (@tree) {
            my $base = $file;
            $base =~ s{.*/}{};
            if ($file =~ $re || $base =~ $re) {
                push @found, $file unless $seen{$file}++;
            }
        }
    }
    @found = sort @found;

    my $dump = 'The following pages of the persistent memory'
        . ' (~/.agent_memory) are now part of the conversation'
        . ' context:';
    my @listed;
    for my $file (@found) {
        my $content = slurp("$root/$file");
        if (!defined $content) {
            print STDERR "agenti.pl: cannot read $root/$file: $!\n";
            next;
        }
        $dump .= "\n\n=== $file ===\n" . $content;
        push @listed, sprintf('%s (%d bytes)', $file, length $content);
    }

    if (@listed) {
        push @messages, { role => 'user', content => $dump };
        print_block($CYAN . 'Added to the context:' . $RESET . "\n"
            . join('', map { "  $_\n" } @listed));
    }
    else {
        print_block($YELLOW . 'No memory pages matched: ' . $patterns
            . $RESET . "\n");
    }
    print "\n";
    $after_blank = 1;
}

## Read the files matching the /codebase patterns into the context  ##
## (@messages).  Patterns are shell-like wildcards: "*" and "?" are   ##
## recognised, every other character stands for itself; a plain path  ##
## (no wildcard) is read as given, absolute or not.  Wildcards are    ##
## matched against every regular file below the current directory     ##
## (recursively), against the path as well as against the bare file   ##
## name, so "*py", "*md*" and just "*" all work as expected.          ##
sub codebase_load {
    my ($patterns) = @_;

    my @pat = grep { length } split ' ', $patterns;
    @pat = ('*') unless @pat;

    my @tree = list_files('.');
    my (@found, %seen);
    for my $pat (@pat) {
        if ($pat !~ /[*?]/ && -f $pat) {    # an explicit path: keep it
            push @found, $pat unless $seen{$pat}++;
            next;
        }
        my $re = pattern_to_regex($pat);
        for my $file (@tree) {
            my $base = $file;
            $base =~ s{.*/}{};
            if ($file =~ $re || $base =~ $re) {
                push @found, $file unless $seen{$file}++;
            }
        }
    }
    @found = sort @found;

    my $dump = 'The following files are now part of the conversation'
             . ' context (loaded with /codebase):';
    my @listed;
    for my $file (@found) {
        my $content = slurp($file);
        if (!defined $content) {
            print STDERR "agenti.pl: cannot read $file: $!\n";
            next;
        }
        $dump .= "\n\n=== $file ===\n" . $content;
        push @listed, sprintf('%s (%d bytes)', $file, length $content);
    }

    if (@listed) {
        # One user message carrying the file dump: the LLM sees the
        # sources from the next request on, until they are pruned.
        push @messages, { role => 'user', content => $dump };
        print_block($CYAN . 'Added to the context:' . $RESET . "\n"
            . join('', map { "  $_\n" } @listed));
    }
    else {
        print_block($YELLOW . 'No files matched: ' . $patterns . $RESET
            . "\n");
    }
    print "\n";
    $after_blank = 1;
}

## Every regular file under $dir, recursively, as a path relative to  ##
## the current directory; version-control bookkeeping (.git) and      ##
## symlinks are skipped so a plain "*" stays a sane codebase.         ##
sub list_files {
    my ($dir) = @_;
    my @found;

    opendir my $dh, $dir or return ();
    for my $entry (sort readdir $dh) {
        next if $entry eq '.' || $entry eq '..' || $entry eq '.git';
        my $path = "$dir/$entry";
        $path =~ s{\A\./}{};    # keep the reported paths tidy
        next if -l $path;
        if (-d $path) {
            push @found, list_files($path);
        }
        elsif (-f $path) {
            push @found, $path;
        }
    }
    closedir $dh;
    return @found;
}

## Turn one shell-like wildcard into an anchored regex: * -> .*,     ##
## ? -> ., every other character quoted so it matches only itself.    ##
sub pattern_to_regex {
    my ($pat) = @_;
    my $re = '';
    for my $ch (split //, $pat) {
        $re .= $ch eq '*' ? '.*'
             : $ch eq '?' ?  '.'
             :              quotemeta($ch);
    }
    return qr/\A$re\z/;
}

## Slurp a file whole, byte for byte; undef when it cannot be read.   ##
## NUL bytes are left in place and only stripped later, when the       ##
## context is embedded into the jq/curl request (see san).            ##
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $content = <$fh>;
    close $fh;
    return defined $content ? $content : '';
}

## Append text to a file, creating it when missing; an existing file  ##
## is never rewritten, only extended (from a fresh line when needed). ##
sub append_file {
    my ($path, $text) = @_;
    return 0 unless defined $path && length $path;
    $text = '' unless defined $text;
    if (-e $path && -s $path) {
        my $cur = slurp($path);
        $text = "\n" . $text
            if defined $cur && length $cur && $cur !~ /\n\z/;
    }
    open my $fh, '>>:raw', $path or return 0;
    my $ok = print $fh $text;
    close $fh;
    return $ok ? 1 : 0;
}

## Replace a file's content atomically (write a temporary file,      ##
## then rename it into place); used only to insert an index bullet,   ##
## never to remove or alter existing lines.                           ##
sub rewrite_file {
    my ($path, $content) = @_;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return 0;
    my $ok = print $fh $content;
    close $fh;
    return 0 unless $ok;
    return 1 if rename $tmp, $path;
    unlink $tmp;
    return 0;
}

## Shorten one line of text for the session log.                     ##
sub log_summary {
    my ($str) = @_;
    $str = '' unless defined $str;
    $str =~ s/\s+/ /g;
    $str =~ s/\A\s+//;
    $str =~ s/\s+\z//;
    $str = substr($str, 0, 120) . '...' if length $str > 123;
    return $str;
}

## Print one block of output, preceded by a single blank line so      ##
## the blocks stay visually apart.  A blank line already waiting on    ##
## screen (e.g. right after the y/N confirmation) is never doubled.    ##
sub print_block {
    my ($text) = @_;
    print "\n" unless $after_blank;
    print $text;
    $after_blank = 0;
}

## Ask the LLM for the next step; returns its raw answer ##
## $messages carries the conversation so far (oldest first) so the LLM ##
## keeps the context of everything that happened before this request.  ##
sub llm_response {
    my ($prompt, $messages) = @_;

    # Replay every earlier turn as its own message, then ask about the
    # current prompt; with an empty $messages this degenerates to a
    # single user message, i.e. exactly the old request format.
    my (@jq_args, @jq_msgs);
    my $i = 0;
    for my $msg (@$messages) {
        my $var = 'c' . $i++;
        push @jq_args, '--arg', $var, san($msg->{content});
        push @jq_msgs, '{role:"' . $msg->{role} . '",content:$' . $var . '}';
    }
    push @jq_args, '--arg', 'p', san($prompt);
    push @jq_msgs, '{role:"user",content:$p}';

    my $jq_program = '{model:"xiaomi/mimo-v2.6-flash",'
        . 'messages:[' . join(',', @jq_msgs) . '],'
        . 'temperature:0}';
    my $build = 'jq -n '
        . join(' ', map { sh_quote($_) } @jq_args) . ' '
        . sh_quote($jq_program);
    my $payload = qx{$build};
    $payload =~ s/\n+\z//;    # command substitution would strip them

    my $call = 'curl -s '
        . sh_quote(($ENV{API_BASE} // '') . '/chat/completions')
        . ' -H ' . sh_quote('Authorization: Bearer ' . ($ENV{VIBE_KEY} // ''))
        . ' -H ' . sh_quote('Content-Type: application/json')
        . ' -d ' . sh_quote($payload)
        . ' | jq -r ' . sh_quote('.choices[0].message.content');
    my $response = qx{$call};
    $response =~ s/\n+\z//;
    return $response;
}

## Run one shell command, stdout and stderr merged, like $(sh -c ...) ##
sub run_command {
    my ($cmd) = @_;

    my $line = 'sh -c ' . sh_quote($cmd) . ' 2>&1';
    my $output = qx{$line};
    my $rc = $?;
    $output = '' unless defined $output;

    my $status =
          $rc == -1  ? 127
        : ($rc & 127) ? 128 + ($rc & 127)    # killed by a signal, as in sh
        :               $rc >> 8;

    $output =~ s/\n+\z//;    # command substitution would strip them
    return ($output, $status);
}

## Single-quote a string so the shell takes it literally ##
sub sh_quote {
    my ($str) = @_;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

## Strip NUL bytes before a string becomes part of a shell command ##
## Command output with binary data (e.g. head -c on an executable) ##
## ends up in $history and then inside the prompt: execve() takes   ##
## NUL-terminated strings, so a single NUL would silently truncate  ##
## the jq command line and leave the shell with a broken,           ##
## half-quoted program (Syntax error: Unterminated quoted string).  ##
sub san {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/\0//g;
    return $str;
}
