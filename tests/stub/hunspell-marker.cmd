@echo off
rem A hunspell that records that it was started: it writes a marker file next to
rem itself and exits. The Windows test expects no marker, which proves the
rem checker never started a hunspell there. An sh stub cannot show that, as it
rem cannot start on Windows either way.
echo started> "%~dp0hunspell-marker.started"
