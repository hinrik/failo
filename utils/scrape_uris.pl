use strict;
use warnings;
use DateTime;
use DateTime::Format::Strptime;
use URI::Find;
use YAML::Any 'DumpFile';

# TODO: decode() and change regex to account for @nick, +nick, etc

my $old = { };
my $strp = DateTime::Format::Strptime->new(
    pattern  => '%a %b %d %T %Y',
    locale   => 'en_US',
    time_zone => 'UTC',
);
my ($dt, $current_nick);
my $uri_finder = URI::Find->new(\&uri_found);

@ARGV = 'newavar.log';
while (my $line = <>) {
    chomp $line;

    if (my ($date) = $line =~ /^--- Log opened (.*)/) {
        $dt = $strp->parse_datetime($date);
    }
    elsif ($line =~ /^--- Day changed/) {
        $dt = $dt->add(days => 1);
    }
    elsif (my ($hour, $min, $nick, $msg) = $line =~ /^(\d\d):(\d\d) < (\S+)> (.*)/) {
        $dt = $dt->set_hour($hour)->set_minute($min);
        $current_nick = $nick;
        $uri_finder->find(\$msg);
    }
}

DumpFile('old_uri.yml', $old);

sub uri_found {
    my (undef, $uri) = @_;
    return if $uri =~ m{^https?://(?:[^/]+\.)?(?:\w+chan|2ch|anonib|handahof|ringulreid)\.(?:com|org|net|ru)};
    unless (my ($date, $nick) = uri_is_old($uri)) {
        $old->{$uri} = [$dt->epoch(), $current_nick];
    }
}

sub uri_is_old {
    my ($uri) = @_;

    # try a few different version of the uri
    (my $slash    = $uri) =~ s{$}{/};
    (my $no_slash = $uri) =~ s{/$}{};
    (my $www      = $uri) =~ s{://}{://www.};
    (my $no_www   = $uri) =~ s{://www\.}{://};

    for my $try ($slash, $no_slash, $www, $no_www) {
        if ($old->{$try}) {
            my ($time, $nick) = @{ $old->{$try} };
            $time = localtime $time;
            return $time, $nick;
        }
    }
 
    return;   
}
