#!/bin/zsh
# FNAF: The Flipside - Mac fix (CrossOver / Whisky / Wine on Apple Silicon)
# Fixes the "slideshow" intro (4 FPS, minutes-long loading) by patching the game's own files.
# https://github.com/tholtman1-del/flipside-mac-fix
HERE=${0:A:h}
PATCHER=$HERE/patcher.pl
CX_BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
WHISKY_BOTTLES="$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles"

echo "=============================================="
echo "  FNAF: The Flipside - Mac fix (installer)"
echo "=============================================="
echo

if pgrep -fi 'FLIPSIDE\.exe' >/dev/null; then
  echo "The game is running. Please quit it first, then press Enter."
  read -r
fi

echo "Looking for the game (FLIPSIDE.exe)..."
typeset -a games
while IFS= read -r exe; do
  games+=("${exe:h}")
done < <(find "$CX_BOTTLES" "$WHISKY_BOTTLES" "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" \
              "$HOME/Applications" "$HOME/Games" -maxdepth 7 -iname 'FLIPSIDE.exe' -type f 2>/dev/null | sort -u)

if (( ${#games} == 0 )); then
  echo "Couldn't find it automatically."
  echo "Drag the game folder (the one with FLIPSIDE.exe in it) into this window and press Enter:"
  read -r dir
  dir=${dir%% }; dir=${dir#\'}; dir=${dir%\'}; dir=${dir//\\ / }
  if [[ ! -f "$dir/FLIPSIDE.exe" && ! -f "$dir/flipside.exe" ]]; then
    echo "No FLIPSIDE.exe in: $dir"; echo "Press Enter to close."; read -r; exit 1
  fi
  games=("$dir")
fi

fail=0
for g in "${games[@]}"; do
  echo
  echo "Game folder: $g"
  /usr/bin/perl "$PATCHER" patch "$g" || fail=1
done

# CrossOver's own DXVK DLLs lack the NX flag, which brings the slowdown back. DXMT works best.
if [[ -d "$CX_BOTTLES" ]]; then
  for conf in "$CX_BOTTLES"/*/cxbottle.conf(N); do
    bottle=${conf:h:t}
    if grep -q '^"CX_GRAPHICS_BACKEND" = "dxvk"' "$conf"; then
      echo
      echo "CrossOver bottle \"$bottle\" uses the DXVK graphics backend, which makes this game freeze."
      echo -n "Switch \"$bottle\" to DXMT (recommended)? Other games in that bottle use it too. [Y/n] "
      read -r ans
      if [[ $ans != [nN]* ]]; then
        cp -n "$conf" "$conf.before-flipsidefix"
        sed -i '' 's/^"CX_GRAPHICS_BACKEND" = "dxvk"/"CX_GRAPHICS_BACKEND" = "dxmt"/' "$conf"
        echo "  \"$bottle\" now uses DXMT. (Change it any time in CrossOver: bottle settings > Graphics.)"
      fi
    fi
  done
fi
if [[ -d "$WHISKY_BOTTLES" ]] && grep -lq '<key>dxvk</key>[[:space:]]*<true/>' "$WHISKY_BOTTLES"/*/Metadata.plist(N) 2>/dev/null; then
  echo
  echo "Whisky: if the game still freezes, turn OFF \"DXVK\" in the bottle's configuration."
fi

echo
if (( fail )); then
  echo "Something went wrong (see above). Nothing was half-patched: originals are in _mac-fix-backup."
else
  echo "Done! Start the game as usual."
  echo "To undo, run \"Uninstall Flipside Fix.command\"."
fi
echo
echo "If this helped, you can support me: https://ko-fi.com/F2J527ZLUN"
echo "Press Enter to close."
read -r
