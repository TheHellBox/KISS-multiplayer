#!/bin/sh
set -e


MODSDIR="${HOME}/.steam/steam/steamapps/compatdata/284160/pfx/drive_c/users/steamuser/My Documents/BeamNG.drive/mods/"
MODFILE="KISSMultiplayer.zip"

cd KISSMultiplayer

rm $MODFILE
zip $MODFILE -r *


if [ -d "$MODSDIR" ]; then
  echo "Copying mod in ${MODSDIR}"
  cp $MODFILE "${MODSDIR}"
  echo "SUCCESS"
else
  echo "ERROR: Can't find mod folder!"
  exit 1
fi
