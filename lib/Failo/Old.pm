package Failo::Old;

use strict;
use warnings;
use POE;
use POE::Component::IRC::Common qw(parse_user);
use POE::Component::IRC::Plugin qw(:ALL);
use YAML::XS qw(DumpFile LoadFile);

our $VERSION = '0.01';

sub new {
    my ($package, %args) = @_;
    return bless \%args, $package;
}

sub PCI_register {
    my ($self, $irc) = @_;
    $self->{uri} = LoadFile('old_uri.yml');
    $irc->plugin_register($self, 'SERVER', qw(urifind_uri));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    return 1;
}

sub S_urifind_uri {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick = parse_user( ${ $_[0] } );
    my $chan = ${ $_[1] };
    my $uri  = ${ $_[2] };

    return PCI_EAT_NONE if $chan ne '#avar';
    return PCI_EAT_NONE if $uri =~ m{^https?://(?:[^/]+\.)?(?:\w+chan|2ch|anonib|handahof|ringulreid)\.(?:com|org|net|ru)};

    if (my ($date, $previous) = $self->uri_is_old($uri)) {
        $irc->yield(notice => $chan, "$nick: OOOOOOOOOOOLLLLLLLLLLDDDDDDD!!! This url was posted at $date by $previous!");
    }
    else {
        $self->{uri}{$uri} = [time, $nick];
    }
    return PCI_EAT_NONE;
};

sub uri_is_old {
    my ($self, $uri) = @_;

    my $old = $self->{uri}; 

    # try a few different version of the uri
    my $slash    = $uri; $slash    =~ s{$}{/};
    my $no_slash = $uri; $no_slash =~ s{/$}{};
    my $www      = $uri; $www      =~ s{://}{://www.};
    my $no_www   = $uri; $no_www   =~ s{://www\.}{://};

    for my $try ($slash, $no_slash, $www, $no_www) {
        if ($old->{$try}) {
            my ($time, $nick) = @{ $old->{$try} };
            $time = localtime $time;
            return $time, $nick;
        }
    }
 
    return;   
}
