#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;
use URI::Title qw(title);

STDOUT->autoflush(1);

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
    when (m[//twitter\.com/(?:#!/)?(?<user>[^/]+)/status/(?<id>\d+)]) {
        require LWP::Simple;
        LWP::Simple->import;
        require HTML::Entities;
        HTML::Entities->import;
        my $user = $+{user};
        my $url = $ARGV[0];

        # Get rid of NewTwitter fragment AIDS from URLs
        $url =~ s[/\K#!/][];

        if (my $content = get($url)) {
            my ($when) = $content =~ m[<span class="published timestamp"[^>]+>(.*?)</span>];
            my ($twat) = $content =~ m[<meta content="(?<tweet>.*?)" name="description" />];
            $_ = decode_entities($_) for $when, $twat;
            if ($when and $twat) {
                say "$user $when: $twat";
                exit;
            }
        }
    }
    when (m[(?:enwp\.org|en\.wikipedia\.org/wiki)/(?<article>.+)]) {
        eval {
            require Net::DNS;
            my $res = Net::DNS::Resolver->new(
                #nameservers => [ qw( ns.na.l.dg.cx ns.eu.l.dg.cx ) ],
                tcp_timeout => 5,
                udp_timeout => 5,
            );

            my $wikipedia = sub {
                my ($name) = @_;
                my $q = $res->query("$name.wp.dg.cx", "TXT");
                if ($q) {
                    for my $rr ($q->answer) {
                        next unless $rr->type eq "TXT";
                        return join "", $rr->char_str_list;
                    }
                }
            };

            if (my $title = title($_) and
                my $summary = $wikipedia->($+{article})) {

                # Strip out " - Wikipedia, the free encyclopedia"
                $title =~ s/ - [^-]+$//;

                # Use enwp.org as an URI shortener instead of a.vu:
                $summary =~ s[http://\Ka\.vu/w:][enwp.org/];

                say "Wikipedia: $title - $summary";
                exit;
            }
        };
    }
}

say title($ARGV[0]);
