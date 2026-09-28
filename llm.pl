#!/usr/bin/env perl
#
# llm.pl -- Perl rewrite of llm.sh
#
# Sends a prompt to the chat completions API and prints the reply.
#
# Usage:
#   perl llm.pl "single line prompt"
#   cat multiline_text_file.txt | perl llm.pl    # multi-line / piped input
#   perl llm.pl                                 # type a prompt, finish with EOF (Ctrl-D)
#
# Honours the same environment variables as llm.sh: API_BASE, VIBE_KEY

use strict;
use warnings;
use Encode qw(decode FB_DEFAULT);
use JSON::PP;

my $MODEL = 'xiaomi/mimo-v2.6-flash';

# --------------------------------------------------------------- prompt -----
# Command-line arguments win when given (equivalent to "$*" in llm.sh);
# otherwise slurp stdin in one go so multi-line prompts -- including a whole
# piped file, e.g.  cat dummy_text_file.txt | perl llm.pl  -- are processed
# intact.
my $prompt;
if (@ARGV) {
    $prompt = join ' ', @ARGV;
}
else {
    local $/;
    my $bytes = <STDIN>;
    $prompt = defined $bytes ? $bytes : '';
}
$prompt = decode('UTF-8', $prompt, FB_DEFAULT);

# --------------------------------------------------------------- request ----
my $json = JSON::PP->new->utf8->canonical;

my $payload = $json->encode({
    model    => $MODEL,
    messages => [{ role => 'user', content => $prompt }],
});

# ---------------------------------------------------------------- curl ------
my $url = ($ENV{API_BASE} // '') . '/chat/completions';

open my $curl, '-|',
    'curl', '-s', $url,
    '-H', 'Authorization: Bearer ' . ($ENV{VIBE_KEY} // ''),
    '-H', 'Content-Type: application/json',
    '-d', $payload
    or die "llm.pl: failed to run curl: $!\n";

my $response = '';
{
    local $/;
    my $raw = <$curl>;
    $response = $raw if defined $raw;
}
close $curl;
my $curl_status = $?;

if ($curl_status != 0 && $response eq '') {
    my $code = $curl_status >> 8;
    warn "llm.pl: curl failed (exit " . ($code || $curl_status) . ")\n";
    exit($code || 1);
}

# -------------------------------------------------------------- response ----
binmode(STDOUT, ':encoding(UTF-8)');

my $decoded;
eval { $decoded = $json->decode($response); 1 } or $decoded = undef;

if (ref $decoded eq 'HASH'
    && ref $decoded->{choices} eq 'ARRAY'
    && @{$decoded->{choices}}
    && ref $decoded->{choices}[0] eq 'HASH'
    && ref $decoded->{choices}[0]{message} eq 'HASH'
    && exists $decoded->{choices}[0]{message}{content})
{
    my $content = $decoded->{choices}[0]{message}{content};
    $content = '' unless defined $content;
    print $content;
    print "\n" unless $content =~ /\n\z/;
    exit 0;
}

if (defined $decoded) {
    # Valid JSON but no message content (e.g. an API error object).
    warn "llm.pl: no message content in API response:\n$response\n";
    exit 1;
}

# Not JSON at all -- surface it verbatim so the user can see what came back.
warn "llm.pl: response is not valid JSON:\n$response\n";
exit 1;
