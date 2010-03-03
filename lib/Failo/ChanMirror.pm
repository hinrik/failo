package Failo::ChanMirror;

use strict;
use warnings;
use Carp 'croak';
use File::Spec::Functions 'catfile';
use POE;
use POE::Wheel::Run;
use POE::Component::IRC::Plugin qw(:ALL);
use YAML::XS qw(LoadFile DumpFile);

our $VERSION = '0.01';

sub new {
    my ($package, %args) = @_;
    my $self = bless \%args, $package;

    croak 'No mirror dir defined' if !defined $self->{Mirror_dir};
    croak 'No mirror url defined' if !defined $self->{Mirror_url};
    croak 'No state file defined' if !defined $self->{State_file};

    if (!-d $self->{Mirror_dir}) {
        mkdir $self->{Mirror_dir} or croak "Can't mkdir $self->{Mirror_dir}";
    }

    $self->{urls} = { };
    $self->{Method} = 'notice' if !defined $self->{Method};
    $self->{Keepalive} = 60*60*24 if !defined $self->{Keepalive};
    $self->{useragent} = 'Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9b3pre) Gecko/2008020108';
    $self->{wget_cmd} = [
        qw(wget -nv -H -K -r -l 1 -p -E -k -e robots=off -N),
        '-I', '/*/src,/*/thumb,/image/*',
        '-U', $self->{useragent},
        '-P', $self->{Mirror_dir},
    ],

    return $self;
}

sub PCI_register {
    my ($self, $irc) = @_;
    
    my $botcmd;
    if (!(($botcmd) = grep { $_->isa('POE::Component::IRC::Plugin::BotCommand') } values %{ $irc->plugin_list() })) {
        die __PACKAGE__ . "requires an active BotCommand plugin\n";
    }
    $botcmd->add(chanmirror => 'Usage: chanmirror <url>');
    
    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
                _mirror_thread
                _sig_DIE
                _sig_chld
                _wget_stderr
                _wget_close
                _stop_mirroring
            )],
        ],
    );

    $self->{irc} = $irc;
    $irc->plugin_register($self, 'SERVER', qw(botcmd_chanmirror));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    $poe_kernel->call($self->{session_id}, '_stop_mirroring');
    delete $self->{urls};
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub _start {
    my ($kernel, $session, $self) = @_[KERNEL, SESSION, OBJECT];
    $self->{session_id} = $session->ID();
    $kernel->sig(DIE => '_sig_DIE');
    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);

    my $urls;
    eval { $urls = LoadFile($self->{State_file}) };
    $self->{urls} = $urls if !$@;

    for my $url (keys %{ $self->{urls} }) {
        my $info = $self->{urls}{$url};
        $kernel->yield(_mirror_thread => $info->{where}, $info->{who}, $url);
    }
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

sub S_botcmd_chanmirror {
    my ($self, $irc) = splice @_, 0, 2;
    my $who   = (split /!/, ${ $_[0] })[0];
    my $where = ${ $_[1] };
    my $url   = ${ $_[2] };

    if (!defined $url || $url !~ m{^http://\S+chan\.org/}) {
        $irc->yield($self->{Method}, $where, "$who: I can't mirror that.");
        return PCI_EAT_NONE;
    }

    # remove anchor
    $url =~ s{#[^/]+$}{};

    if (exists $self->{urls}{$url}) {
        $irc->yield($self->{Method}, $where, "$who: I'm already mirroring that.");
        return PCI_EAT_NONE;
    }

    $irc->yield($self->{Method}, $where, "$who: Downloading, this might take a while...");

    $poe_kernel->post($self->{session_id}, _mirror_thread => $where, $who, $url, 1);
    return PCI_EAT_NONE;
}

sub _mirror_thread {
    my ($kernel, $self, $where, $who, $url, $new)
        = @_[KERNEL, OBJECT, ARG0..ARG3];

    my $wheel = POE::Wheel::Run->new(
        Program     => [@{ $self->{wget_cmd} }, $url],
        StderrEvent => '_wget_stderr',
        CloseEvent  => '_wget_close',
    );

    $self->{urls}{$url} = {
        wheel => $wheel,
        time  => time,
        where => $where,
        who   => $who,
        new   => $new,
    };

    $kernel->sig_child($wheel->PID, '_sig_chld');
    return;
}

sub _save_urls {
    my ($self) = @_;

    my %urls = %{ $self->{urls} };
    delete $_->{wheel} for values %urls;
    delete $_->{new}   for values %urls;
    delete $_->{timer} for values %urls;
    DumpFile($self->{State_file}, \%urls);
}

sub _wget_stderr {
    my ($kernel, $self, $output, $id) = @_[KERNEL, OBJECT, ARG0, ARG1];

    return if $output !~ /ERROR/;

    for my $url (keys %{ $self->{urls} }) {
        if (my $wheel = $self->{urls}{$url}{wheel}) {
            if ($wheel->ID == $id) {
                my $timer = $self->{urls}{$url}{timer};
                $kernel->alarm_remove($timer) if defined $timer;
                delete $self->{urls}{$url};
                $self->_delete_backup($url);
            }
        }
    }

    return;
}

sub _delete_backup {
    my ($self, $html_orig) = @_;
    $html_orig =~ s{^https?://}{}g;
    $html_orig .= '.orig';
    $html_orig = catfile($self->{Mirror_dir}, $html_orig);
    unlink $html_orig if -e $html_orig;
    return;
}

sub _wget_close {
    my ($kernel, $self, $id) = @_[KERNEL, OBJECT, ARG0];

    my $url;
    for my $u (keys %{ $self->{urls} }) {
        if (my $wheel = $self->{urls}{$u}{wheel}) {
             if ($wheel->ID == $id) {
                 $url = $u;
                 last;
             }
        }
    }
    return if !defined $url;

    my $info = $self->{urls}{$url};
    if ($info->{new}) {
        my $mirror = $url;
        $mirror =~ s[^https?://(.*)][$self->{Mirror_url}$1];
        $mirror .= '.html' if $url !~ /\.html$/;
        $self->{irc}->yield($self->{Method}, $info->{where}, "$info->{who}: $mirror");
    }

    my $max = $info->{time} + $self->{Keepalive};
    if (time() > $max) {
        delete $self->{urls}{$url};
        $self->_delete_backup($url);
    }
    else {
        delete $info->{wheel};
        $info->{timer} = $kernel->delay_set(_mirror_thread => 5*60, $info->{where}, $info->{who}, $url);
    }

    return;
}

sub _sig_chld {
    $_[KERNEL]->sig_handled;
}

sub _stop_mirroring {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    $kernel->delay('_mirror_thread');
    $self->_save_urls;
    
    for my $url (values %{ $self->{urls} }) {
        next if !defined $url->{wheel};
        $url->{wheel}->kill;
    }
    return;
}

1;
