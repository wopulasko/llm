#!/usr/bin/env perl

## Interactive shell agent: it holds the context of the conversation. ##
## Pass --no-context to work without any previous context (amnesiac). ##

use strict;
use warnings;

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
                     independently, as if it were the first one.
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
# and every answer it gave.  With --no-context this list stays empty, so
# each request carries nothing but the current task (the old behaviour).
my @messages;

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
