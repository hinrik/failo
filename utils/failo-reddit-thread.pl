#!/usr/bin/env perl
use strict;
use warnings;
use 5.010;
use JSON::XS 'decode_json';
use LWP::UserAgent;

STDOUT->autoflush(1);

# TODO: some urls don't return a correct response, even though there are
# reddit threads for them. URI::Escape::uri_unescape doesn't help. Example:
#
# http://www.bestbuy.com/site/AudioQuest+-+Coffee+26.3%27+HDMI+Cable+-+White/1267512.p?skuId=1267512&productCategoryId=abcat0107020&id=1218245467893#tabbed-customerreviews
#
# The above should (but doesn't) return http://www.reddit.com/r/funny/comments/gxqtb/165099_hdmi_cable_reviews/
my $ua = LWP::UserAgent->new();
my $response = $ua->get("http://www.reddit.com/api/info.json?url=$ARGV[0]");

if ($response->is_success()) {
    my $content = decode_json($response->content());
    exit if !defined $content->{data}{children};
    exit if !@{ $content->{data}{children} };

    # return the thread with the most comments
    my ($thread) = sort { $b->{data}{num_comments} <=> $a->{data}{num_comments} }
        @{ $content->{data}{children} };
    my $data = $thread->{data};
    $data->{title} =~ s/\n//g; # some titles have newlines for some reason
    exit if $data->{num_comments} < 250;
    exit if $data->{downs} / $data->{ups} > 0.8;
    say "/r/$data->{subreddit}: $data->{title} - http://redd.it/$data->{id}";
}
