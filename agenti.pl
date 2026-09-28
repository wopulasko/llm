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
proposes and it will execute them for you.

By default the agent holds the context of the conversation: every new
task can build on everything that was asked, executed and answered
before.

Options:
      --no-context   Hold no previous context: every task is handled
                     independently, as if it were the first one.
  -h, --help         Display this help and exit.

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
DONE: <short explanation>

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
