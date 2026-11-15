# Interactive bash.
[[ $- != *i* ]] && return
[[ -f /etc/bash/bashrc ]] && . /etc/bash/bashrc

export EDITOR=vim VISUAL=vim PAGER=less
HISTSIZE=10000 HISTFILESIZE=20000 HISTCONTROL=ignoreboth
shopt -s histappend checkwinsize autocd

# amber prompt: user@host dir $   (red $ after a failing command)
PS1='\[\e[33m\]\u@\h\[\e[0m\] \w \[\e[$(( $? ? 31 : 90 ))m\]\$\[\e[0m\] '

alias ls='ls --color=auto --group-directories-first'
alias ll='ls -lh'
alias la='ls -lAh'
alias grep='grep --color=auto'
alias e='$EDITOR'
alias t='tmux new -A -s main'
alias up='doas bash ~/system/bootstrap.sh'
