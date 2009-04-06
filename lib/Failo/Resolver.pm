package Failo::Resolver;

use strict;
use warnings;
use POE;
use POE::Component::IRC::Common qw(parse_user);
use POE::Component::IRC::Plugin qw(:ALL);
use POE::Component::Client::DNS;

our $VERSION = '0.01';

sub new {
    my ($package, %args) = @_;
    return bless \%args, $package;
}

sub PCI_register {
    my ($self, $irc) = @_;

    if (!$irc->isa('POE::Component::IRC::State')) {
        die __PACKAGE__ . "requires PoCo::IRC::State or a subclass thereof\n";
    }

    my $botcmd;
    if (!(($botcmd) = grep { $_->isa('POE::Component::IRC::Plugin::BotCommand') } values %{ $irc->plugin_list() })) {
        die __PACKAGE__ . "requires an active BotCommand plugin\n";
    }
    $botcmd->add(dns => 'Takes two arguments: a record type (optional), and a host.');

    POE::Session->create(
        object_states => [
            $self => [ qw(_start _resolve dns_response) ],
        ]
    );
    $self->{dns} = POE::Component::Client::DNS->spawn();
    $self->{irc} = $irc;
    $irc->plugin_register($self, 'SERVER', qw(botcmd_dns));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    delete $self->{irc};
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub _start {
    my ($kernel, $session, $self) = @_[KERNEL, SESSION, OBJECT];
    $self->{session_id} = $session->ID();
    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);
    return;
}

sub S_botcmd_dns {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick = parse_user( ${ $_[0] } );
    my $chan = ${ $_[1] };
    my ($type, $host) = ${ $_[2] } =~/(?:(\w*)\s+)?(\S+)/;

    $poe_kernel->call($self->{session_id} => _resolve => $type, $host, $chan, $nick);
    return PCI_EAT_NONE;
};

sub _resolve {
    my ($kernel, $self, $type, $host, $chan, $nick) = @_[KERNEL, OBJECT, ARG0..$#_];

    my $res = $self->{dns}->resolve(
        event => 'dns_response',
        type  => $type,
        host  => $host,
        context => {
            channel => $chan,
            nick    => $nick,
        },
    );
    
    $kernel->yield(dns_response => $res) if $res;
    return;
}

sub dns_response {
    my ($self, $res) = @_[OBJECT, ARG0];
    my $irc = $self->{irc};
    
    my @answers = $res->{response}
        ? map { $_->rdatastr } $res->{response}->answer()
        : ()
    ;
    
    $irc->yield(
        'notice',
        $res->{context}->{channel},
        $res->{context}->{nick} . (@answers
            ? ": @answers"
            : ': no answers for "' . $res->{host} . '"')
    );

    return;
}

