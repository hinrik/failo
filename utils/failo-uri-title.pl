#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;
use URI::Title qw(title);
$| = 1;

given ($ARGV[0]) {
    when (m[youtube\.com/watch\?v=(?<id>[A-Za-z0-9_-]+)]) {
        eval {
            require WWW::YouTube::Download;
            my $client = WWW::YouTube::Download->new;
            my $title  = $client->get_title($+{id});
            my $url    = $client->get_video_url($+{id});
            say "YouBoob: $title - $url";
            exit;
        };
    }
    when (m[//twitter\.com/(?<user>[^/]+)/status/(?<id>\d+)]) {
        require LWP::Simple;
        LWP::Simple->import;
        require HTML::Entities;
        HTML::Entities->import;
        my $user = $+{user};
        if (my $content = get($ARGV[0])) {
            my ($when) = $content =~ m[<span class="published timestamp"[^>]+>(.*?)</span>];
            my ($twat) = $content =~ m[<meta content="(?<tweet>.*?)" name="description" />];
            $_ = decode_entities($_) for $when, $twat;
            if ($when and $twat) {
                say "$user $when: $twat";
                exit;
            }
        }
    }
}

say title($ARGV[0]);
