#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Mode de développement local.
#
# shard.yml et shard.lock référencent les shards maison sur GitHub
# (aloli-crystal/* et aloli-partiduo/*) ; le verrou versionné ne contient
# aucun `path:`. Sur le poste du développeur, ce script génère un
# shard.override.yml local (non versionné, voir .gitignore) qui remplace
# chacune de ces dépendances, directes ou indirectes, par la copie de travail
# voisine quand elle existe :
#
#   github.com/aloli-crystal/<nom>   -> ../../prod-crystal/<nom>
#   github.com/aloli-partiduo/<nom>  -> ../<nom>
#
# Il installe ensuite les shards, puis remet shard.lock à son état versionné :
# le verrou réécrit par l'override (en `path:`) ne doit jamais être commité.
set -eu

cd "$(dirname "$0")/.."

# Couples « nom du shard / dépôt GitHub » lus dans le verrou versionné.
couples="$(awk '
  /^  [^ ].*:$/ { nom = $1; sub(/:$/, "", nom) }
  /^    git: / {
    if (match($2, /github\.com\/aloli-(crystal|partiduo)\/[^\/]+$/)) {
      chemin = substr($2, RSTART + length("github.com/"))
      sub(/\.git$/, "", chemin)
      print nom, chemin
    }
  }
' shard.lock)"

{
  echo "# Généré par scripts/override-local.sh : local, non versionné."
  echo "dependencies:"
  echo "$couples" | while read -r nom chemin; do
    [ -n "$nom" ] || continue
    depot="${chemin#*/}"
    case "$chemin" in
      aloli-crystal/*) local_path="../../prod-crystal/$depot" ;;
      aloli-partiduo/*) local_path="../$depot" ;;
      *) continue ;;
    esac
    if [ -d "$local_path" ]; then
      printf '  %s:\n    path: %s\n' "$nom" "$local_path"
    else
      echo "override-local : $local_path absent, $nom reste sur GitHub" >&2
    fi
  done
} > shard.override.yml

SKIP_MARTEN_CLI_PRECOMPILATION=1 shards install
git checkout -- shard.lock
