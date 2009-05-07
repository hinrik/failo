package Failo::TorrentStatus;

use strict;
use warnings;
use POE;
use POE::Component::IRC::Common qw(parse_user NORMAL DARK_GREEN DARK_BLUE ORANGE);
use POE::Component::IRC::Plugin qw(:ALL);
use POE::Component::IRC::Plugin::FollowTail;
use File::Basename qw(fileparse);
use Linux::Inotify2;

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

    $irc->plugin_add('FollowTail', POE::Component::IRC::Plugin::FollowTail->new(
        filename => 'torrentlog',
    ));

    POE::Session->create(
        object_states => [
            $self => [ qw(_start inotify_poll watch_handler) ],
        ],
    );
    $self->{irc} = $irc;
    $irc->plugin_register($self, 'SERVER', qw(tail_input));
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
    $self->{inotify} = Linux::Inotify2->new()
        or die "Can't create inotify object: $!";

    $self->{inotify}->watch(
        "/home/leech/torrent/queue",
        IN_CREATE|IN_MOVED_TO,
        $session->postback("watch_handler"),
    ) or die "Unable to watch dir: $!";

#    $self->{inotify}->watch(
#        "/home/leech/torrent/files",
#        IN_CREATE,
#        $session->postback("watch_handler"),
#    ) or die "Unable to watch dir: $!";

    my $inotify_FH;
    open $inotify_FH, '<&=', $self->{inotify}->fileno or die "Can't fdopen: $!\n";
    $kernel->select_read($inotify_FH, 'inotify_poll');

    return;
}

sub inotify_poll {
    $_[OBJECT]->{inotify}->poll();
}

sub watch_handler {
    my ($self, $event) = ($_[OBJECT], $_[ARG1][0]);
    my $irc = $self->{irc};
    my $name = fileparse($event->fullname());

    return if $name !~ s/\.torrent$//;
    
    my $msg = DARK_BLUE.'Enqueued'.NORMAL.' torrent '.ORANGE.$name.NORMAL;
    my $channels = $irc->channels();
    $irc->yield(notice => $_, $msg) for grep { $_ ne '#failo' } keys %$channels;
}

sub S_tail_input {
    my ($self, $irc) = splice @_, 0, 2;
    my $name = fileparse(${ $_[1] });
    my $msg = DARK_GREEN.'Finished'.NORMAL.' torrent '.ORANGE.$name.NORMAL;
    my $channels = $irc->channels();
    $irc->yield(notice => $_, $msg) for grep { $_ ne '#failo' } keys %$channels;
    return PCI_EAT_NONE;
}
