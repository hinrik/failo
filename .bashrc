if [[ $- != *i* ]] ; then
    # Shell is non-interactive.  Be done now!
    return
fi

# away with old aliases
\unalias -a

# disable software flow control
stty -ixon

# programmable completion
if [[ -f /etc/bash_completion ]]; then
    source /etc/bash_completion
fi

# Change the window title of X terminals 
case ${TERM} in
    xterm*|rxvt*|Eterm|aterm|kterm|gnome*|interix)
        PROMPT_COMMAND='echo -ne "\033]0;${USER}@${HOSTNAME%%.*}:${PWD/$HOME/~}\007"'
        ;;
    screen)
        PROMPT_COMMAND='echo -ne "\033_${USER}@${HOSTNAME%%.*}:${PWD/$HOME/~}\033\\"'
        ;;
esac

# print some useful info about the current dir
# if we're inside a git working tree, print the current git branch
# if we're inside an svn working directory, print the current svn revision
# or else print the total size of all files in the directory
function dir_info() {
    if type git >&/dev/null; then
        local git_branch=$(git branch 2>/dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/')
        if [[ -n $git_branch ]]; then
            echo $git_branch
            return 0
        fi
    fi

    if type svn >&/dev/null; then
        local svn_rev=$(svn info 2>/dev/null | grep ^Revision | awk '{ print $2 }')
        if [[ -n $svn_rev ]]; then
            echo "r$svn_rev"
            return 0
        fi
    fi
    
    ls -Ahs|head -n1|awk '{print $2}'
}

if ls --help|grep group-directories-first >&/dev/null; then
    group_dirs=" --group-directories-first"
else
    group_dirs=
fi

# check if we support colors
if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
    if [ -x /usr/bin/dircolors ]; then
        test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
        alias ls="ls$group_dirs --color=auto"
    fi

    if [[ ${EUID} == 0 ]] ; then
        PS1='\[\e[1;35m\]\h\[\e[m\] \[\e[1;34m\]\W\[\e[m\] (\[\e[;33m\]$(dir_info)\[\e[m\]) \[\e[1;31m\]\$\[\e[m\] '
    else
        PS1='\[\e[1;35m\]\h\[\e[m\] \[\e[1;34m\]\W\[\e[m\] (\[\e[;33m\]$(dir_info)\[\e[m\]) \[\e[1;32m\]\$\[\e[m\] '
    fi

    alias grep='grep --color=auto'
    alias egrep='egrep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias rgrep='rgrep --color=auto'
else
    PS1='\h \W ($(dir_info)) \$ '
    alias ls="ls$group_dirs"
fi

# some nice shell options
shopt -s checkwinsize cdspell dotglob histappend nocaseglob no_empty_cmd_completion

alias ll="ls -lh"
alias scp="rsync --rsh=ssh --archive --append --human-readable --progress --times"

# some nice less(1) options
export LESS="iMQRS"

# keep a long history without duplicates
export HISTSIZE=10000
export HISTFILESIZE=10000
export HISTCONTROL="ignoreboth"
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S  "

# ignore some boring stuff. The " *" bit ignores all command lines
# starting with whitespace, useful to selectively avoid the history
export HISTIGNORE="ls:cd:cd ..:..*: *"

# ignore these while tab-completing
export FIGNORE="CVS:.svn:.git"

export EDITOR="vim"
export PERLDOC="-MPod::Text::Ansi"

# do an ls after every successful cd
function cd {
    builtin cd "$@" && ls
}

# recursive mkdir and cd if successful
function mkcd {
    mkdir -p "$@" && builtin cd "$@"
}

# how to use info/emacs
function info { /usr/bin/info "$@" --subnodes -o - 2> /dev/null | less ; }

# good for links that keep dropping your ssh connections
function keepalive {
    [ -z $1 ] && interval=60 || interval=$1
    while true; do
        date
        sleep $interval
    done
}

