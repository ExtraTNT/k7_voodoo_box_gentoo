#!/bin/sh
# startx -> i3.  Kept short: every line here is boot time.
xrdb -merge "$HOME/.Xresources"

# Terminus as a core X font (i3 + urxvt use core fonts, no pango/Xft)
for d in /usr/share/fonts/terminus*; do
    [ -f "$d/fonts.dir" ] && xset +fp "$d"
done
xset fp rehash
xset b off
xset r rate 250 40

# urxvt daemon: every new terminal is a cheap client
urxvtd -q -o -f

exec i3
