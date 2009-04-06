package Failo::Identica;

use strict;
use warnings;
use POE;
use POE::Component::IRC '6.06';
use POE::Component::IRC::Common qw(parse_user irc_to_utf8);
use POE::Component::IRC::Plugin qw(:ALL);
use Net::Twitter;
use YAML qw(LoadFile);

our $VERSION = '0.01';
my %names = %{ LoadFile('map_names.yml') };

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
    $botcmd->add(dent => 'Usage: dent <quote>');
    $botcmd->add(dent => 'Usage: undent');
    
    POE::Session->create(
        object_states => [
            $self => [ qw(_start _push_queue _shift_queue _pop_queue) ],
        ]
    );

    $self->{irc} = $irc;
    $self->{twit} = Net::Twitter->new(
        username => 'failo',
        password => '',
        identica => 1,
    );
    $self->{queue} = [ ];
    $irc->plugin_register($self, 'SERVER', qw(botcmd_dent botcmd_undent));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    delete $self->{irc};
    $poe_kernel->alarm('_shift_queue');
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub _start {
    my ($kernel, $session, $self) = @_[KERNEL, SESSION, OBJECT];
    $self->{session_id} = $session->ID();
    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);
    return;
}

sub _push_queue {
    my ($kernel, $self, $quote) = @_[KERNEL, OBJECT, ARG0];
    push @{ $self->{queue} }, $quote;
    $kernel->delay_add(_shift_queue => 10);
}

sub _shift_queue {
    my $self = $_[OBJECT];
    while (my $quote = shift @{ $self->{queue} }) {
        while (my ($old, $new) = each %nicks) {
            $quote =~ s/\b\Q$old\E\b/$new/gi;
        }
        $self->{twit}->update(irc_to_utf8($quote));
    }
}

sub _pop_queue {
    my ($kernel, $self) = @_[KERNEL, OBJECT];
    pop @{ $self->{queue} };
    $kernel->alarm('_shift_queue');
    $kernel->yield('_shift_queue') if @{ $self->{queue} };
}

sub S_botcmd_dent {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick  = parse_user( ${ $_[0] } );
    my $chan  = ${ $_[1] }->[0];
    my $quote = ${ $_[2] };

    if (length $quote <= 140) {
        my $topic_info = $irc->channel_topic($chan);
        my $topic = $topic_info->{Value};
        $irc->yield(topic => $chan, "$quote | $topic");
        $poe_kernel->post($self->{session_id}, _push_queue => $quote);
    }
    else {
        $irc->yield(notice => $chan, "$nick: That quote is over 140 chars long. Please shorten it.");
    }
    return PCI_EAT_NONE;
}

sub S_botcmd_undent {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick  = parse_user( ${ $_[0] } );
    my $chan  = ${ $_[1] };

    if (@{ $self->{queue} }) {
        my $topic_info = $irc->channel_topic($chan);
        my $topic = $topic_info->{Value};
        $topic =~ s/^.*? | //;
        $irc->yield(topic => $chan, $topic);
        $poe_kernel->call($self->{session_id}, '_pop_queue');
    }
    else {
        $irc->yield(notice => $chan, "$nick: There are no quotes in the queue.");
    }

    return PCI_EAT_NONE;
}

