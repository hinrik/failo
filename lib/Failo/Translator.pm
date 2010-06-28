package Failo::Translator;

use strict;
use warnings;
use POE;
use POE::Component::IRC::Common qw(parse_user irc_to_utf8);
use POE::Component::IRC::Plugin qw(:ALL);
use POE::Component::Lingua::Translate;

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
    $botcmd->add(tr => 'Usage: tr <from>,<to> <text>');

    POE::Session->create(
        object_states => [
            $self => [ qw(_start translated) ],
        ],
    );

    $self->{irc} = $irc;
    $irc->plugin_register($self, 'SERVER', qw(botcmd_tr));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    delete $self->{irc};
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub S_botcmd_tr {
    my ($self, $irc)   = splice @_, 0, 2;
    my $nick           = parse_user( ${ $_[0] } );
    my $chan           = ${ $_[1] };
    my ($langs, $text) = split /\s+/, ${ $_[2] }, 2;
    my @langs          = split /,/, $langs;

    $poe_kernel->call($self->{session_id} => translated =>
        irc_to_utf8($text),
        {
            nick    => $nick,
            channel => $chan,
            langs   => \@langs,
        }
    );
    return PCI_EAT_NONE;
}

sub _start {
    my ($kernel, $session, $self) = @_[KERNEL, SESSION, OBJECT];
    $self->{session_id} = $session->ID();
    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);
    return;
}

sub translated {
    my ($kernel, $self, $text, $context) = @_[KERNEL, OBJECT, ARG0, ARG1];
    my $irc = $self->{irc};
    return if !defined $text;
    
    if (!@{ $context->{langs} }) {
        $irc->yield(notice => $context->{channel}, $context->{nick} . ": $text");
        return;
    }
    
    my ($from, $to) = splice @{ $context->{langs} }, 0, 2;
    unshift(@{ $context->{langs} }, $to) if @{ $context->{langs} };

    if (!exists $self->{translators}->{$from . $to}) {
        eval {
            $self->{translators}->{$from . $to} = POE::Component::Lingua::Translate->new(
                alias     => $from . $to,
                back_end  => 'InterTran',
                src       => $from,
                dest      => $to,
            );
        };
        
        if ($@) {
            $irc->yield(privmsg => $context->{chan}, $context->{nick} . ": There was an error: $@");
            return;
        }
    }

    $kernel->post($from . $to => translate =>
        $text,
        $context,
    );
    
    return;
}

