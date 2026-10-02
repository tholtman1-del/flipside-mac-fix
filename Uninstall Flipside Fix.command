#!/bin/zsh
# FNAF: The Flipside - Mac fix: puts the original game files back.
HERE=${0:A:h}
CX_BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
WHISKY_BOTTLES="$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles"

echo "FNAF: The Flipside - Mac fix (uninstaller)"
echo
if pgrep -fi 'FLIPSIDE\.exe' >/dev/null; then
  echo "The game is running. Please quit it first, then press Enter."
  read -r
fi

found=0
while IFS= read -r b; do
  found=1
  echo "Game folder: ${b:h}"
  /usr/bin/perl "$HERE/patcher.pl" restore "${b:h}"
done < <(find "$CX_BOTTLES" "$WHISKY_BOTTLES" "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" \
              "$HOME/Applications" "$HOME/Games" -maxdepth 7 -type d -name '_mac-fix-backup' 2>/dev/null)

if (( ! found )); then
  echo "Couldn't find a patched game automatically."
  echo "Drag the game folder into this window and press Enter:"
  read -r dir
  dir=${dir%% }; dir=${dir#\'}; dir=${dir%\'}; dir=${dir//\\ / }
  /usr/bin/perl "$HERE/patcher.pl" restore "$dir"
fi

for conf in "$CX_BOTTLES"/*/cxbottle.conf.before-flipsidefix(N); do
  bottle=${conf:h:t}
  echo -n "Put CrossOver bottle \"$bottle\" back on its old graphics backend (DXVK)? [y/N] "
  read -r ans
  if [[ $ans == [yY]* ]]; then
    sed -i '' 's/^"CX_GRAPHICS_BACKEND" = "dxmt"/"CX_GRAPHICS_BACKEND" = "dxvk"/' "${conf%.before-flipsidefix}"
    rm -f "$conf"
    echo "  done"
  fi
done
echo
echo "Done. Press Enter to close."
read -r
