#!/bin/sh
# pcpNetAudio - déploiement sur le parc pCP
#
# S'exécute depuis le Mac ou la FreedomBox, pas sur un Pi.
# Lit nodes.conf, pousse install.sh sur chaque nœud, l'exécute via SSH.
#
# Usage :
#   ./deploy.sh                 # tous les nœuds actifs
#   ./deploy.sh pcpDJ pcpSalon  # nœuds nommés uniquement
#   DRY_RUN=1 ./deploy.sh       # montre sans exécuter

set -e

CONF="${CONF:-nodes.conf}"
INSTALLER="${INSTALLER:-install.sh}"
SSH_USER="${SSH_USER:-tc}"
DRY_RUN="${DRY_RUN:-}"

[ -f "$CONF" ]      || { echo "ERREUR: $CONF introuvable" >&2; exit 1; }
[ -f "$INSTALLER" ] || { echo "ERREUR: $INSTALLER introuvable" >&2; exit 1; }

TARGETS="$*"
OK_COUNT=0
FAIL_COUNT=0
FAILED=""

# nodes.conf : name  ip  role  alsa_mode  atten  card
# lignes vides et # ignorées ; role "skip" pour désactiver un nœud

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac

    # shellcheck disable=SC2086
    set -- $line
    # Le defaut est hw, pas dmix : c'est la decision de conception du projet
    # (bit-perfect preserve, cf. README "hw ou dmix"). Un defaut a dmix ferait
    # perdre silencieusement ~1,7 bit sur toute ligne de nodes.conf incomplete.
    NAME="$1"; IP="$2"; ROLE="$3"; MODE="${4:-hw}"; ATTEN="${5:-0.3}"; CARD="${6:-}"

    [ "$ROLE" = "skip" ] && { echo "-- $NAME : ignoré (skip)"; continue; }

    if [ -n "$TARGETS" ]; then
        echo "$TARGETS" | grep -qw "$NAME" || continue
    fi

    echo ""
    echo "=== $NAME ($IP) — mode=$MODE atten=$ATTEN ==="

    if [ -n "$DRY_RUN" ]; then
        echo "    [dry-run] scp $INSTALLER $SSH_USER@$IP:/tmp/"
        echo "    [dry-run] SNAPSERVER=$SNAPSERVER ALSA_MODE=$MODE ATTEN=$ATTEN CARD=$CARD NODE_NAME=$NAME sh /tmp/install.sh"
        continue
    fi

    # -n indispensable : la boucle lit nodes.conf sur stdin, et ssh sans -n
    # consomme ce flux. Sans lui, seul le PREMIER noeud est deploye et les
    # suivants disparaissent sans aucun message d'erreur.
    if ! ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$IP" true 2>/dev/null; then
        echo "    INJOIGNABLE (ou clé SSH absente)"
        FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED="$FAILED $NAME"
        continue
    fi

    if scp -q "$INSTALLER" "$SSH_USER@$IP:/tmp/install.sh" \
       && ssh -n "$SSH_USER@$IP" \
            "SNAPSERVER='$SNAPSERVER' ALSA_MODE='$MODE' ATTEN='$ATTEN' CARD='$CARD' NODE_NAME='$NAME' sh /tmp/install.sh"
    then
        OK_COUNT=$((OK_COUNT + 1))
    else
        echo "    ÉCHEC"
        FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED="$FAILED $NAME"
    fi
done < "$CONF"

echo ""
echo "======================================"
echo "  réussis : $OK_COUNT"
echo "  échoués : $FAIL_COUNT$FAILED"
echo "======================================"

[ "$FAIL_COUNT" -eq 0 ]
