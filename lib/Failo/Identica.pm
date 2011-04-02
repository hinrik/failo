package Failo::Identica;

use strict;
use warnings;
use utf8;
use Encode 'is_utf8';
use List::Util 'first';
use POE;
use POE::Component::IRC '6.06';
use POE::Component::IRC::Common qw(parse_user irc_to_utf8);
use POE::Component::IRC::Plugin qw(:ALL);
use POE::Quickie;
use Net::Twitter::Lite;
use Scalar::Util qw(blessed);
use String::Approx qw(adist);
use YAML::XS qw(LoadFile DumpFile);

our $VERSION = '0.01';

sub new {
    my ($package, %args) = @_;
    my $self = bless \%args, $package;

    for my $arg (qw(Channels Username Password Quotes_file)) {
        die __PACKAGE__ . " requires a $arg parameter\n" if !defined $args{$arg};
    }
    $self->{quotes} = LoadFile($self->{Quotes_file}) || [];

    return $self;
}

sub PCI_register {
    my ($self, $irc) = @_;
    
    if (!$irc->isa('POE::Component::IRC::State')) {
        die __PACKAGE__ . " requires PoCo::IRC::State or a subclass thereof\n";
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
    $self->{twit} = Net::Twitter::Lite->new(
        username   => $self->{Username},
        password   => $self->{Password},
        traits     => ['API::REST'],
        identica   => 1,
        (defined $self->{Source} ? (source => $self->{Source}) : ()),
        (defined $self->{ClientName} ? (clientname => $self->{ClientName}) : ()),
        (defined $self->{ClientUrl} ? (clienturl => $self->{ClientUrl}) : ()),
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
    my $pseudo = $self->_pseudonimize($quote);

    # post the quote as a status update
    my (undef, $stderr, $exit_status) = quickie(sub { $self->_post_update($quote) });

    if ($exit_status) {
        # remove quote from topic
        my $topic_info = $irc->channel_topic($chan);
        my $topic = irc_to_utf8($topic_info->{Value});
        if ($topic =~ s/\Q$quote\E(?: \| )?//) {
            $irc->yield(topic => $chan, $topic);
        }

        # print the error
        my ($short) = $quote =~ /(.{0,50})/;
        $irc->yield(notice => $chan, "Couldn't post quote '$short…': $stderr");
        return;
    }

    # save the quote locally
    push @{ $self->{quotes} }, $quote;
    DumpFile($self->{Quotes_file}, $self->{quotes});
}

sub _post_update {
    my ($self, $quote) = @_;

    eval { $self->{twit}->update($quote) };

    if (blessed($@) && $@->isa('Net::Twitter::Lite::Error')) {
        die $@->error()."\n";
    }
    elsif ($@) {
        chomp $@;
        die "$@\n";
    }

    return;
}

sub _pop_queue {
    my ($kernel, $self) = @_[KERNEL, OBJECT];
    pop @{ $self->{queue} };
    $kernel->alarm('_shift_queue');
    $kernel->yield('_shift_queue') if @{ $self->{queue} };
}

sub _ignoring_channel {
    my ($self, $chan) = @_; 

    if ($self->{Channels}) {
        unless ($self->{Own_channel} && $self->_is_own_channel($chan)) {
            return if !first {
                $chan = irc_to_utf8($chan) if is_utf8($_);
                $_ eq $chan
            } @{ $self->{Channels} };
        }   
    }   
    return;
}

sub S_botcmd_dent {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick  = parse_user( ${ $_[0] } );
    my $chan  = ${ $_[1] };
    my $quote = irc_to_utf8(${ $_[2] });

    return PCI_EAT_NONE if $self->_ignoring_channel($chan);
    return PCI_EAT_NONE if $quote =~ /^\s*$/;
    my $pseudo = $self->_pseudonimize($quote);

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

    # remove incomplete quote from the end
    if (my $max_length = $irc->isupport('TOPICLEN')) {
        while (length ($new_topic) >= $max_length) {
            last unless $new_topic =~ s/ \|[^|]+$//;
        }
    }

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
    my ($self, $quote) = @_;
    return $quote if !$self->{Map_names};

    while (my ($old, $new) = each %{ $self->{Map_names} }) {
        my $old_up = uc $old;
	no warnings 'uninitialized';
        $quote =~ s/\b(fail)?\Q$old_up\E(s)?_*\b/uc "$1$new$2"/eg;
        $quote =~ s/\b(fail)?\Q$old\E(s)?_*\b/$1$new$2/gi;
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
