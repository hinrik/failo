package Failo::URITitle;

use strict;
use warnings;
use Carp qw(croak);
use POE;
use POE::Component::IRC::Plugin qw(PCI_EAT_NONE);
use POE::Quickie;
use File::Spec::Functions qw(catdir catfile);
use Dir::Self;

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
                uri_title
                got_result
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
    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);
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

    $poe_kernel->post($self->{session_id}, 'uri_title', $where, $uri);
    return PCI_EAT_NONE;
}

sub uri_title {
    my ($kernel, $self, $where, $uri) = @_[KERNEL, OBJECT, ARG0, ARG1];

    my $place = 0;

    # the ImageMirror plugin provides image titles
    if ($uri !~ /(?i:jpe?g|gif|png)$/) {
        # find the title
        quickie_run(
            Program     => catfile(catdir(__DIR__, '..', '..', 'utils'), 'failo-uri-title.pl'),
            ProgramArgs => [$uri],
            ResultEvent => 'got_result',
            Context     => {
                uri   => $uri,
                place => $place,
                total => 2,
            },
        );
        $place++;
    }

    # check if there's a reddit thread for this uri
    quickie_run(
        Program     => catfile(catdir(__DIR__, '..', '..', 'utils'), 'failo-reddit-thread.pl'),
        ProgramArgs => [$uri],
        ResultEvent => 'got_result',
        Context     => {
            uri   => $uri,
            place => $place,
            total => $place+1,
            where => $where,
        },
    );

    return;
}

sub got_result {
    my ($self, $stdout, $ctx) = @_[OBJECT, ARG1, ARG5];

    chomp $stdout;
    $self->{uris}{$ctx->{uri}}[$ctx->{place}] = $stdout;

    if (@{ $self->{uris}{$ctx->{uri}} } == $ctx->{total}) {
        for my $output (@{ $self->{uris}{$ctx->{uri}} }) {
            if (length $output) {
                $self->{irc}->yield($self->{Method}, $ctx->{where}, $output);
            }
        }
    }
}

1;
