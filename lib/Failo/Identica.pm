package Failo::Identica;

use strict;
use warnings;
use POE;
use POE::Component::IRC '6.06';
use POE::Component::IRC::Common qw(parse_user irc_to_utf8);
use POE::Component::IRC::Plugin qw(:ALL);
use Net::Twitter;
use Scalar::Util qw(blessed);
use String::Approx qw(adist);
use YAML::XS qw(LoadFile DumpFile);

our $VERSION = '0.01';
my %nicks = %{ LoadFile('map_names.yml') };

my $identica_pass = qx/cat identica_pass.txt/;
chomp $identica_pass;

my @quotes = @{ LoadFile('quotes.yml') || [] };

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
    $botcmd->add(undent => 'Usage: undent');
    
    POE::Session->create(
        object_states => [
            $self => [ qw(_start _push_queue _shift_queue _pop_queue) ],
        ]
    );

    $self->{irc} = $irc;
    $self->{twit} = Net::Twitter->new(
        username   => 'failo',
        password   => $identica_pass,
        source     => 'failo',
        traits     => ['API::REST'],
        identica   => 1,
        clientname => 'failo IRC bot',
        clienturl  => 'http://github.com/hinrik/failo',
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
    $kernel->delay_add(_shift_queue => 30);
}

sub _shift_queue {
    my $self = $_[OBJECT];
    my $irc = $self->{irc};
    my ($chan, $quote) = @{ shift @{ $self->{queue} } };
    my $pseudo = _pseudonimize($quote);

    # post the quote as a status update
    eval {
        $self->{twit}->update($pseudo);
    };
    if ($@) {
        if (!blessed($@) || !$@->isa('Net::Twitter::Error')) {
            $irc->yield(notice => $chan, "Unknown Net::Twitter error: $@");
            return;
        }

        # remove quote from topic
        my $topic_info = $irc->channel_topic($chan);
        my $topic = irc_to_utf8($topic_info->{Value});
        if ($topic =~ s/\Q$quote\E(?: \| )?//) {
            $irc->yield(topic => $chan, $topic);
        }

        my ($short) = $quote =~ /(.{0,50})/;
        $irc->yield(notice => $chan, "Failed to post quote '$short...': " . $@->error());

        warn "HTTP Response Code: ", $@->code(), "\n",
            "HTTP Message......: ", $@->message(), "\n",
            "Twitter error.....: ", $@->error(), "\n";
        return;
    }

    # save the quote locally
    push @quotes, $quote;
    DumpFile('quotes.yml', \@quotes);
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
    my $chan  = ${ $_[1] };
    my $quote = irc_to_utf8(${ $_[2] });

    return if $quote =~ /^\s*$/;
    my $pseudo = _pseudonimize($quote);

    if (length($pseudo) > 140) {
        my $surplus = length($pseudo) - 140;
        $irc->yield(notice => $chan, "$nick: That quote is $surplus chars too long.");
        return PCI_EAT_NONE;
    }

    if ($self->_in_queue($quote)) {
        $irc->yield(notice => $chan, "$nick: I've already added that quote.");
        return PCI_EAT_NONE;
    }

    my $topic_info = $irc->channel_topic($chan);
    my $topic = irc_to_utf8($topic_info->{Value});
    my $new_topic = length($topic) ? "$quote | $topic" : $quote;

    $irc->yield(topic => $chan, $new_topic);
    $poe_kernel->post($self->{session_id}, _push_queue => [$chan, $quote]);
    return PCI_EAT_NONE;
}

sub S_botcmd_undent {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick  = parse_user( ${ $_[0] } );
    my $chan  = ${ $_[1] };

    if (@{ $self->{queue} }) {
        my $topic_info = $irc->channel_topic($chan);
        my $topic = irc_to_utf8($topic_info->{Value});

        $topic =~ s/^\Q$self->{queue}[-1][1]\E(?: \| )?//;
        $irc->yield(topic => $chan, $topic);
        $poe_kernel->call($self->{session_id}, '_pop_queue');
    }
    else {
        $irc->yield(notice => $chan, "$nick: There are no quotes about to be uploaded.");
    }

    return PCI_EAT_NONE;
}

sub _pseudonimize {
    my ($quote) = @_;
    while (my ($old, $new) = each %nicks) {
        $quote =~ s/\b(?:fail)?\Q$old\E(?:s|_+)?\b/$new/gi;
    }
    return $quote;
}

sub _in_queue {
    my ($self, $quote) = @_;

    for my $queued_info (@{ $self->{queue} }) {
        my $queued = $queued_info->[1];
        my $dist = adist($queued, $quote);
        return 1 if $dist > -5 && $dist < 5;
    }

    return;
}

1;
