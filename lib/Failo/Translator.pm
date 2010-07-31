package Failo::Translator;

use strict;
use warnings;
use Lingua::Translate;
use POE;
use POE::Component::IRC::Common qw(parse_user irc_to_utf8);
use POE::Component::IRC::Plugin qw(:ALL);
use POE::Quickie;

our $VERSION = '0.01';

sub new {
    my ($package, %args) = @_;
    return bless \%args, $package;
}

sub PCI_register {
    my ($self, $irc) = @_;

    my $botcmd;
    if (!(($botcmd) = grep { $_->isa('POE::Component::IRC::Plugin::BotCommand') } values %{ $irc->plugin_list() })) {
        die __PACKAGE__ . " requires an active BotCommand plugin\n";
    }
    $botcmd->add(tr => 'Usage: tr [engine:]<lang1>,<lang2>[,<lang3>...] <text>');

    POE::Session->create(
        object_states => [
            $self => [ qw(_start translate) ],
        ],
    );

    $self->{irc} = $irc;
    $irc->plugin_register($self, 'SERVER', qw(botcmd_tr));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub S_botcmd_tr {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick         = parse_user( ${ $_[0] } );
    my $chan         = ${ $_[1] };
    my ($trans, $langs, $text) = ${ $_[2] } =~ /^(\S+:)?(\S+) (.*)/;

    my @langs = split /,/, $langs;
    $trans =~ s/:$// if defined $trans;

    if (!defined $text) {
        $irc->yield(notice => $chan, "$nick: No text!");
        return PCI_EAT_NONE;
    }

    if (@langs < 2) {
        $irc->yield(notice => $chan, "$nick: Not enough languages!");
        return PCI_EAT_NONE;
    }

    $poe_kernel->post(
        $self->{session_id},
        'translate',
        irc_to_utf8($text), $nick, $chan, $trans, \@langs
    );
    return PCI_EAT_NONE;
}

sub _start {
    my ($kernel, $session, $self) = @_[KERNEL, SESSION, OBJECT];
    $self->{session_id} = $session->ID();
    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);
    return;
}

sub translate {
    my ($kernel, $self, $text, $nick, $chan, $trans, $langs)
        = @_[KERNEL, OBJECT, ARG0..ARG4];
    my $irc = $self->{irc};
    
    $trans = 'Google' if !defined $trans;
    my $translated;
    while (@$langs > 1) {
        my $from = shift @$langs;
        my $to = $langs->[0];

        eval {
            if (!exists $self->{trans}{"$trans+$from+$to"}) {
                $self->{trans}{"$trans+$from+$to"} = Lingua::Translate->new(
                    back_end => $trans,
                    src      => $from,
                    dest     => $to,
                );
            }
        };

        if ($@) {
            chomp $@;
            $irc->yield(
                'notice',
                $chan,
                "$nick: Error constructing Lingua::Translate: $@",
            );
            return;
        }

        my ($stdout, $stderr, $exit) = quickie(
            sub {
                print $self->{trans}{"$trans+$from+$to"}->translate($text), "\n";
            }
        );

        if (($exit >> 8) != 0 && defined $stderr) {
            $irc->yield(
                'notice',
                $chan,
                "$nick: Error during translation: $stderr",
            );
            return;
        }
        $translated = $stdout;
    }

    $irc->yield(notice => $chan, "$nick: $translated");
    return;
}

1;
