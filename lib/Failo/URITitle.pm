package Failo::URITitle;

use strict;
use warnings;
use Carp qw(croak);
use POE;
use POE::Component::IRC::Plugin qw(PCI_EAT_NONE);
use POE::Wheel::Run;

my $uri_title_code = <<'END';
use 5.010;
use strict;
use warnings;
use URI::Title qw(title);
$| = 1;

given ($ARGV[0]) {
    when (m[youtube\.com/watch\?v=(?<id>[A-Za-z0-9]+)]) {
        require WWW::YouTube::Download;
        my $client = WWW::YouTube::Download->new;
        my $title  = $client->get_title($+{id});
        my $url    = $client->get_video_url($+{id});
        say "YouBoob: $title - $url";
        exit;
    }
    when (m[//twitter\.com/(?<user>[^/]+)/status/(?<id>\d+)]) {
        require LWP::Simple;
        LWP::Simple->import;
        require HTML::Entities;
        HTML::Entities->import;
        my $user = $+{user};
        if (my $content = get($ARGV[0])) {
            my ($when) = $content =~ m[<span class="published timestamp"[^>]+>(.*?)</span>];
            my ($twat) = $content =~ m[<meta content="(?<tweet>.*?)" name="description" />];
            $_ = decode_entities($_) for $when, $twat;
            if ($when and $twat) {
                say "Twat by $user $when: $twat";
                exit;
            }
        }
    }

    say title($ARGV[0]);
}
END

sub new {
    my ($package, %args) = @_;
    my $self = bless \%args, $package;

    # defaults
    $self->{Method} = 'notice' if !defined $self->{Method};

    return $self;
}

sub PCI_register {
    my ($self, $irc) = @_;

    $self->{irc} = $irc;
    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
                _sig_DIE
                _sig_chld
                _child_stdout
                _child_stderr
                _uri_title
            )],
        ],
    );

    $irc->plugin_register($self, 'SERVER', qw(urifind_uri));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub _start {
    my ($kernel, $self, $session) = @_[KERNEL, OBJECT, SESSION];
    $self->{session_id} = $session->ID();
    $kernel->sig(DIE => '_sig_DIE');
    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);
    return;
}

sub _sig_DIE {
    my ($kernel, $self, $ex) = @_[KERNEL, OBJECT, ARG1];
    chomp $ex->{error_str};
    warn "Error: Event $ex->{event} in $ex->{dest_session} raised exception:\n";
    warn "  $ex->{error_str}\n";
    $kernel->sig_handled();
    return;
}

sub S_urifind_uri {
    my ($self, $irc) = splice @_, 0, 2;
    my $where = ${ $_[1] };
    my $uri   = ${ $_[2] };

    if (ref $self->{Channels} eq 'ARRAY') {
        my $ok;
        for my $chan (@{ $self->{Channels} }) {
            $ok = 1 if $chan eq $where;
        }
        return PCI_EAT_NONE if !$ok;
    }

    for my $match (@{ $self->{URI_nomatch} }) {
        return PCI_EAT_NONE if $uri =~ $match;
    }

    my $sender = POE::Kernel->get_active_session;
    POE::Kernel->post($self->{session_id}, _uri_title => $sender, $where, $uri);
    return PCI_EAT_NONE;
}

sub _uri_title {
    my ($kernel, $self, $sender, $where, $uri) = @_[KERNEL, OBJECT, ARG0..ARG2];

    my @inc = map { +'-I' => $_ } @INC;
    my $wheel = POE::Wheel::Run->new(
        Program     => [$^X, @inc, '-e', $uri_title_code, $uri],
        StdoutEvent => '_child_stdout',
        StderrEvent => '_child_stderr',
    );

    $self->{req}{ $wheel->ID } = [$sender, $where, $uri, $wheel];
    $kernel->sig_child($wheel->PID, '_sig_chld');
    $kernel->refcount_increment($sender, __PACKAGE__);
    return;
}

sub _child_stdout {
    my ($kernel, $self, $title, $id) = @_[KERNEL, OBJECT, ARG0, ARG1];
    my ($sender, $where, $uri, $wheel) = @{ delete $self->{req}{$id} };
    $self->{irc}->yield($self->{Method}, $where, $title);
    $kernel->refcount_decrement($sender, __PACKAGE__);
    return;
}

sub _child_stderr {
    my ($kernel, $self, $input) = @_[KERNEL, OBJECT, ARG0];
    warn "$input\n" if $self->{debug};
    return;
}

sub _sig_chld {
    $_[KERNEL]->sig_handled;
    return;
}

1;
