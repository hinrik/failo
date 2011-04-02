package Failo::ChanMirror;

use strict;
use warnings;
use Encode 'is_utf8';
use Carp 'croak';
use Cwd 'abs_path';
use File::Glob ':glob';
use File::Spec::Functions 'catfile';
use List::Util 'first';
use POE;
use POE::Component::IRC::Plugin qw(:ALL);
use POE::Component::IRC::Common qw(irc_to_utf8);
use POE::Quickie;
use YAML::XS qw(LoadFile DumpFile);

our $VERSION = '0.01';

sub new {
    my ($package, %args) = @_;
    my $self = bless \%args, $package;

    croak 'No mirror dir defined' if !defined $self->{Mirror_dir};
    croak 'No mirror url defined' if !defined $self->{Mirror_url};
    croak 'No state file defined' if !defined $self->{State_file};

    $self->{State_file} = abs_path(bsd_glob($self->{State_file}));
    $self->{Mirror_dir} = bsd_glob($self->{Mirror_dir});
    if (!-d $self->{Mirror_dir}) {
        mkdir $self->{Mirror_dir} or croak "Can't mkdir $self->{Mirror_dir}";
        $self->{Mirror_dir} = abs_path($self->{Mirror_dir});
    }

    $self->{urls}      = { };
    $self->{Method}    = 'notice' if !defined $self->{Method};
    $self->{Keepalive} = 60*60*24 if !defined $self->{Keepalive};
    $self->{useragent} = 'Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9b3pre) Gecko/2008020108';
    $self->{wget_cmd}  = [
        qw(wget -nv -H -K -r -l 1 -p -E -k -e robots=off -N --retry-connrefused),
        '-I', '/*/src,/*/thumb,/image/*',
        '-U', $self->{useragent},
        '-P', $self->{Mirror_dir},
        '--wait', 0.5,
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

sub S_botcmd_chanmirror {
    my ($self, $irc) = splice @_, 0, 2;
    my $who   = (split /!/, ${ $_[0] })[0];
    my $where = ${ $_[1] };
    my $url   = ${ $_[2] };

    return PCI_EAT_NONE if $self->_ignoring_channel($where);

    ($url) = $url =~ /(\S+)/; # we only want the first word
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
    my $irc = $self->{irc};

    my $info = {
        time  => time,
        where => $where,
        who   => $who,
        new   => $new,
    };
    $self->{urls}{$url} = $info;

    my ($stdout, $stderr, $exit) = quickie([@{ $self->{wget_cmd} }, $url]);

    my $exit_code = ($exit >> 8);
    my $max = $info->{time} + $self->{Keepalive};

    if (time > $max || $stderr =~ /ERROR/ || $exit_code != 0) {
        # stop mirroring and delete the backup file left by wget(1)
        my $timer = $info->{timer};
        $kernel->alarm_remove($timer) if defined $timer;
        delete $self->{urls}{$url};
        $self->_delete_backup($url);

        if ($new) {
            my @msg = "Error mirroring $url. Wget exited with status $exit_code";
            if ($stderr) {
                $msg[0] .= '. Stderr was:';

                # try to find the relevant error
                my @errors = $stderr =~ /^(ERROR.*)/m;

                # fall back on just printing the last line of stderr
                @errors = $stderr =~ /^??(.+)$/m if !@errors;

                push @msg, @errors;
            }

            $irc->yield($self->{Method}, $where, "$who: $_") for @msg;
        }

        return;
    }
    elsif (time <= $max) {
        # schedule the mirror to be updated
        $info->{timer} = $kernel->delay_set(_mirror_thread => 5*60, $where, $who, $url);
    }

    # if this is a new mirror, post it to the channel
    if ($new) {
        my $mirror = $url;
        $mirror =~ s[^https?://(.*)][$self->{Mirror_url}$1];
        $mirror .= '.html' if $url !~ /\.html$/;
        $irc->yield($self->{Method}, $where, "$who: $mirror");
    }

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

sub _delete_backup {
    my ($self, $html_orig) = @_;
    $html_orig =~ s{^https?://}{}g;
    $html_orig .= '.orig';
    $html_orig = catfile($self->{Mirror_dir}, $html_orig);
    unlink $html_orig if -e $html_orig;
    return;
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
