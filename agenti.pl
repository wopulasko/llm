#!/usr/bin/env perl

## Interactive shell agent: it holds the context of the conversation. ##
## Pass --no-context to work without any previous context (amnesiac). ##
## Persistent memory (~/.agent_memory/index.md + skills/skills.md) is  ##
## loaded at the very start and actively managed: saved, pruned and   ##
## word-capped (3000 / 1000) by the agent itself.                      ##

use strict;
use warnings;

use File::Path qw(make_path);    # ~/.agent_memory/ is created on demand

# Subdued, conventional ANSI colours:
#   green   - user query
#   yellow  - y/N confirmation
#   cyan    - program output (results of a Bash command)
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

## Command line switches ##
my $want_help = grep { $_ eq '--help' || $_ eq '-h' } @ARGV;

if ($want_help) {
    print <<'HELP';
Usage: agenti.pl [--no-context] [--help]

Interactive shell agent. Type a task, confirm the shell commands it
proposes and it will execute them for you.  Ordinary conversation is
answered directly, with no shell command involved.

By default the agent holds the context of the conversation: every new
task can build on everything that was asked, executed and answered
before.

Options:
      --no-context   Hold no previous context: every task is handled
                     independently, as if it were the first one (the
                     persistent memory files are still loaded).
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
  /prune                   Forget the conversation so far and
                           return to the agent's system prompt, as
                           if the conversation were starting fresh.

Persistent memory:
  The agent keeps its memory in ~/.agent_memory/index.md (never more
  than 3000 words) and its skills in ~/.agent_memory/skills/skills.md
  (never more than 1000 words).  Both are plain Markdown so they can
  be inspected manually, both are loaded into the context of the
  conversation at the very start of every run, and both are actively
  managed by the agent itself: it automatically decides when to save
  a new memory or skill and when to prune an old one, keeping the
  files within their word limits.  They are loaded even with
  --no-context: persistent memory is not conversation context.

Environment:
  API_BASE  Base URL of the chat-completions API.
  VIBE_KEY  Bearer token for the API.

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

print $CYAN . 'Interactive shell agent. Type a task, or "exit" to quit.'
    . $RESET . "\n";

# The conversation so far, oldest first: every prompt shown to the LLM
# and every answer it gave.  Its very first message is the persistent
# memory (loaded below at the very start of the program).  With
# --no-context nothing else is kept, so each request carries the
# memory and the current task (the old behaviour had only the task).
my @messages;

## Persistent memory: plain-Markdown files below ~/.agent_memory/,     ##
## always loaded into the context at the very start of the program.    ##
## index.md never exceeds 3000 words, skills.md never exceeds 1000:    ##
## the caps are re-enforced on load and after every executed command,  ##
## while the agent itself decides what to save and what to prune.      ##
my $MEMORY_DIR =
      defined $ENV{HOME} && length $ENV{HOME}
    ? "$ENV{HOME}/.agent_memory"
    : '';
my $INDEX_FILE   = "$MEMORY_DIR/index.md";
my $SKILLS_FILE  = "$MEMORY_DIR/skills/skills.md";
my $INDEX_LIMIT  = 3000;
my $SKILLS_LIMIT = 1000;
my $MEM_MARKER   = 'Persistent memory';    # how the context message starts
my $mem_slot;    # position of that message inside @messages

memory_load();

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

    if ($task =~ m{\A/prune\s*\z}s) {
        # Drop everything the conversation accumulated: the next
        # request starts from the agent's system prompt alone, just
        # as if this were the first message ever asked.
        @messages = ();
        # A fresh conversation starts the way this program started:
        # with the persistent memory loaded into the context.
        memory_load();
        print_block($CYAN . 'Context pruned: back to the system prompt,'
            . ' as in a fresh conversation.' . $RESET . "\n");
        print "\n";
        $after_blank = 1;
        next;
    }

    my $history = '';

    while (1) {
        my $prompt = <<"PROMPT";
You are a shell agent.

Task:
$task

Previous execution:
$history

Persistent memory:
Your persistent memory lives in ~/.agent_memory/index.md (at most
3000 words) and ~/.agent_memory/skills/skills.md (at most 1000
words), both loaded as plain Markdown at the start of this
conversation.  You manage them yourself: whenever a task produces
something worth remembering (a fact, a preference, an outcome, a
lesson), save it into index.md and prune what went stale; when a
task yields a reusable skill, put the script in
~/.agent_memory/skills/ and describe it in skills.md.  Rewrite the
files with a shell command when needed and never let either file
exceed its word limit.

Return EXACTLY ONE of:
COMMAND: <one shell command>
RESPONSE: <plain-text reply to the user>
DONE: <short explanation>

Use COMMAND only when a shell command must be run to accomplish the
task.  Use RESPONSE for ordinary conversation: greetings, questions,
small talk and any message that needs no shell - answer with text
alone and never invoke a shell just to reply.  Use DONE when the
executed commands have completed the task; add a short explanation.

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
                memory_sync();    # the command may have just rewritten
                                   # the memory files: cap + refresh now

                print_block($CYAN . $output . $RESET . "\n")
                    if length $output;

                $history .= "\n" . '$ ' . $cmd . "\n" . $output
                    . "\n" . 'exit=' . $status;
            }
            else {
                print_block($CYAN . 'Task aborted.' . $RESET . "\n");
                last;
            }
        }
        elsif ($response =~ /^RESPONSE: /) {
            my $msg = substr($response, length('RESPONSE: '));
            print_block($MAGENTA . $msg . $RESET . "\n");
            # A chat answer ends this turn just like DONE, but nothing
            # was executed, so the execution history stays untouched.
            print "\n";
            $after_blank = 1;
            last;
        }
        elsif ($response =~ /^DONE: /) {
            my $msg = substr($response, length('DONE: '));
            print_block($MAGENTA . $msg . $RESET . "\n");
            # The LLM's answer ends this turn: put a new line between
            # it and the prompt where the next question is asked.
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
            print "\n";
            $after_blank = 1;
            last;
        }
    }

    # The turn is over: re-enforce the memory word caps (its last
    # command may have rewritten the files) and refresh the memory
    # message in the context so the next task sees it as it stands.
    memory_sync();
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


## ---- Persistent memory: ~/.agent_memory ------------------------------ ##

## Number of whitespace-separated words in a text; the very same      ##
## notion of "word" that keeps index.md <= 3000 and skills.md <= 1000 ##
sub count_words {
    my ($text) = @_;
    return 0 unless defined $text;
    return scalar(() = $text =~ /\S+/g);
}

## Hard-cap a text at $limit words: when it already fits, it is        ##
## returned untouched; otherwise everything past the limit is cut off  ##
## at a word boundary (the original line breaks of the kept part are   ##
## preserved) and a short prune note is appended, itself counted       ##
## towards the limit so the result can never exceed it.                ##
sub cap_text {
    my ($text, $limit) = @_;
    return $text if count_words($text) <= $limit;

    my @parts = ($text =~ /(\S+\s*)/g);
    my $note  = "\n\n*(pruned to keep this file at most $limit words)*";
    my $keep  = $limit - count_words($note);
    if ($keep <= 0) {    # pathological limit: the plain cap wins
        my $out = join '', @parts[0 .. $limit - 1];
        $out =~ s/\s+\z//;
        return $out;
    }
    my $out = join '', @parts[0 .. $keep - 1];
    $out =~ s/\s+\z//;
    return $out . "\n" . $note;
}

## Read one memory file: seed it when it does not exist yet, enforce  ##
## its word cap (writing the file back when the cap trimmed it), and   ##
## return the text that is fit for the conversation context.           ##
sub read_or_seed {
    my ($path, $seed, $limit) = @_;
    my $text = slurp($path);
    if (!defined $text) {    # missing or unreadable: (re)create it
        my $capped = cap_text($seed, $limit);
        write_file($path, $capped);
        return $capped;
    }
    my $capped = cap_text($text, $limit);
    write_file($path, $capped) if $capped ne $text;
    return $capped;
}

## Write one plain-Markdown memory file, creating its folder on demand ##
sub write_file {
    my ($path, $text) = @_;
    if ($path =~ m{\A(.+)/[^/]+\z}) {
        my $dir = $1;
        if (length $dir && !-d $dir) {
            eval { make_path($dir); 1 }
                or do {
                    warn "agenti.pl: cannot create directory $dir: $!\n";
                    return;
                };
        }
    }
    open my $fh, '>:raw', $path
        or do {
            warn "agenti.pl: cannot write $path: $!\n";
            return;
        };
    print {$fh} $text;
    close $fh;
}

## Both memory files as they stand right now, word-capped             ##
sub memory_read_all {
    # Seeds: index.md must mention where the skills live; skills.md
    # must describe what a skill is.  Both are plain Markdown.
    my $index_seed = <<'INDEX_MD';
# Persistent memory

This file is `~/.agent_memory/index.md`, the shell agent's persistent
memory.  It is plain Markdown so it can be inspected manually, it is
always loaded into the context of the conversation at the very start
of the program, and the shell agent actively manages it itself: the
agent automatically decides when to save a new memory here and when
to prune an old one, so this file never exceeds 3000 words.

## Skills

Skills will be stored in the `~/.agent_memory/skills/` folder, with
`skills.md` (i.e. `~/.agent_memory/skills/skills.md`) containing a
description of each skill script or program - typically written in
Perl, Bash or Python; but it may also be just another MD file with
instructions or even knowledge data.  `skills.md` is loaded to the
context of the conversation at the start as well, hard capped at
1000 words, and it is managed by the shell agent too, which writes
down new skills and their descriptions so it can decide when to
invoke a particular skill - a very common task.

## Memories

- (no memories saved yet)
INDEX_MD

    my $skills_seed = <<'SKILLS_MD';
# Skills

This file is `~/.agent_memory/skills/skills.md`, the index of the
shell agent's skills.  It is plain Markdown, loaded to the context
of the conversation at the start of the program (hard capped at
1000 words) and actively managed by the shell agent: new skills and
their descriptions are written down here and stale ones are pruned,
so the agent can decide when to invoke a particular skill.

A skill is a script or program - typically written in Perl, Bash or
Python - kept in the `~/.agent_memory/skills/` folder; it may also
be just another MD file with instructions or even knowledge data.
Each entry below names the file and says when it is worth using.

## Registered skills

- (no skills registered yet)
SKILLS_MD

    my $index  = read_or_seed($INDEX_FILE,  $index_seed,  $INDEX_LIMIT);
    my $skills = read_or_seed($SKILLS_FILE, $skills_seed, $SKILLS_LIMIT);
    return ($index, $skills);
}

## The memory files packed into one message for the conversation       ##
sub memory_context_message {
    my ($index, $skills) = @_;
    return $MEM_MARKER . ' of the shell agent, loaded at the very start'
        . ' of this conversation as plain Markdown.  You manage it'
        . ' yourself: save new memories and skills, prune old ones, and'
        . ' keep index.md within ' . $INDEX_LIMIT . ' words and'
        . ' skills.md within ' . $SKILLS_LIMIT . ' words.'
        . "\n\n=== ~/.agent_memory/index.md ("
        . count_words($index) . " words) ===\n" . $index
        . "\n\n=== ~/.agent_memory/skills/skills.md ("
        . count_words($skills) . " words) ===\n" . $skills . "\n";
}

## Load the persistent memory into the context.  Called at the very    ##
## start of the program and again after /prune, because a fresh       ##
## conversation starts the same way this program does.  Without $HOME  ##
## there is nowhere to keep the files and the feature stays off.       ##
sub memory_load {
    return unless length $MEMORY_DIR;
    my ($index, $skills) = memory_read_all();
    push @messages,
        { role => 'user', content => memory_context_message($index, $skills) };
    $mem_slot = $#messages;
}

## Re-enforce the word caps after a turn (the agent may have just      ##
## rewritten the files) and refresh the context message in place, so   ##
## the next task sees the memory as it stands now.                     ##
sub memory_sync {
    return unless length $MEMORY_DIR;
    my ($index, $skills) = memory_read_all();
    my $msg = memory_context_message($index, $skills);
    if (defined $mem_slot && $mem_slot <= $#messages
        && index($messages[$mem_slot]{content}, $MEM_MARKER) == 0)
    {
        $messages[$mem_slot]{content} = $msg
            unless $messages[$mem_slot]{content} eq $msg;
    }
    else {    # the context was reset behind our back: load it again
        push @messages, { role => 'user', content => $msg };
        $mem_slot = $#messages;
    }
}
