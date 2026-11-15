# Login shell.  On tty1 (autologin) go straight into X.
[[ -f ~/.bashrc ]] && . ~/.bashrc

# own scripts (web, …) — also for i3 and rofi, which inherit this
[[ :$PATH: == *:$HOME/.local/bin:* ]] || export PATH=$HOME/.local/bin:$PATH

# touch ~/.nox to stay on the console
if [[ -z $DISPLAY && $(tty) == /dev/tty1 && ! -e ~/.nox ]]; then
    # no 'exec': if X fails you keep a shell instead of an autologin loop
    startx -- -nolisten tcp -keeptty > ~/.local/share/xorg/startx.log 2>&1
fi
