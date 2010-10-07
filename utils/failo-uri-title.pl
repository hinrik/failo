#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;
use URI::Title qw(title);
use URI;
use Web::Scraper;

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
        my $user = $+{user};

        my $url = $ARGV[0];
        # Get rid of NewTwitter fragment AIDS from URLs
        $url =~ s[/\K#!/][];

        my $twat = (scraper {
            process q[span[class="published timestamp"]], when => 'TEXT';
            process q[//meta[@name="description"]],       content => '@content';
        })->scrape(URI->new($url));

        if (ref $twat eq 'HASH') {
            say "$user $twat->{when}: $twat->{content}";
            exit;
        }
    }
    when (m[//twitter\.com/(?<user>[^?/]+)]) {
        my $twat = (scraper {
            process q[//meta[@name="description"]], content => '@content';
        })->scrape(URI->new($ARGV[0]));

        if ($+{user} and ref $twat eq 'HASH') {
            say "$+{user} - $twat->{content}";
            exit;
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
