#!/bin/sh
# pcpNetAudio - contrôle et reconnaissance du parc
#
# Distinct de deploy.sh : celui-ci ne réinstalle rien.
#
#   ./fleet.sh inventory         # reconnaissance matérielle de tout le parc
#   ./fleet.sh inventory --conf  # lignes prêtes à coller dans nodes.conf
#   ./fleet.sh status            # état de chaque nœud
#   ./fleet.sh snapcast          # bascule le parc vers snapclient
#   ./fleet.sh lms               # rend la carte à squeezelite
#   ./fleet.sh snapcast pcpDJ    # un nœud nommé
#   ./fleet.sh log pcpDJ
#
# `inventory` est à lancer EN PREMIER : le parc est hétérogène (modèles de Pi
# et HAT audio différents), et nodes.conf doit refléter le matériel réel.
#
# Les bascules sont parallélisées. Pour accélérer encore, activer le
# multiplexage SSH dans ~/.ssh/config (voir README).

CONF="${CONF:-nodes.conf}"
SSH_USER="${SSH_USER:-tc}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5"
PROBE="${PROBE:-probe.sh}"

# pcpna-mode est appele par son CHEMIN ABSOLU sur ext4, jamais via le PATH.
# Le symlink /usr/local/bin/pcpna-mode depend de bootlocal.sh, donc de
# l'ordonnancement du boot -- il a deja manque a l'appel sur un noeud. Le binaire
# et le script, eux, vivent sur ext4 et sont la des que p2 est monte.
PCPNA="${PCPNA:-/mnt/mmcblk0p2/pcpNetAudio/bin/pcpna-mode}"

ACTION="$1"; shift 2>/dev/null || true

CONF_FLAG=""
if [ "$1" = "--conf" ]; then CONF_FLAG="--conf"; shift; fi
TARGETS="$*"

[ -f "$CONF" ] || { echo "ERREUR: $CONF introuvable" >&2; exit 1; }

case "$ACTION" in
    snapcast|lms|status|log|inventory) ;;
    *) echo "Usage: $0 [inventory|status|snapcast|lms|log] [--conf] [nœud...]" >&2
       exit 1 ;;
esac

nodes() {
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        # shellcheck disable=SC2086
        set -- $line
        [ "$3" = "skip" ] && continue
        if [ -n "$TARGETS" ]; then
            echo "$TARGETS" | grep -qw "$1" || continue
        fi
        printf '%s %s\n' "$1" "$2"
    done < "$CONF"
}

# ---------------------------------------------------------------- inventory

if [ "$ACTION" = "inventory" ]; then
    [ -f "$PROBE" ] || { echo "ERREUR: $PROBE introuvable" >&2; exit 1; }

    if [ -n "$CONF_FLAG" ]; then
        echo "# name       ip             role     mode   atten  card"
    fi

    nodes | while read -r name ip; do
        if ! scp -q $SSH_OPTS "$PROBE" "$SSH_USER@$ip:/tmp/probe.sh" 2>/dev/null; then
            [ -n "$CONF_FLAG" ] && echo "# $name $ip — INJOIGNABLE" \
                                || echo "=== $name ($ip) : INJOIGNABLE ==="
            continue
        fi
        # ConnectTimeout ne couvre que l'etablissement de la connexion, pas la
        # duree d'execution : un script distant qui se bloque fige toute la
        # boucle d'inventaire. Cas rencontre en vrai avec l'aplay de probe.sh.
        # -n est INDISPENSABLE : sans lui ssh lit sur stdin et avale les lignes
        # restantes de nodes.conf, la boucle ne traite que le premier noeud.
        # Ne pas mettre -n dans SSH_OPTS, scp ne connait pas cette option.
        timeout 30 ssh -n $SSH_OPTS "$SSH_USER@$ip" "sh /tmp/probe.sh $CONF_FLAG" 2>/dev/null \
            || echo "  ($name : pas de reponse en 30 s)"
        [ -z "$CONF_FLAG" ] && echo ""
    done
    exit 0
fi

# ---------------------------------------------------------------- log

if [ "$ACTION" = "log" ]; then
    nodes | while read -r name ip; do
        echo "=== $name ($ip) ==="
        ssh -n $SSH_OPTS "$SSH_USER@$ip" "tail -15 /mnt/mmcblk0p2/pcpNetAudio/snapclient.log" 2>/dev/null \
            || echo "  injoignable"
    done
    exit 0
fi

# ---------------------------------------------------------------- bascule

TMP="/tmp/pcpna-fleet.$$"
mkdir -p "$TMP"

# NE PAS ecrire "nodes | while read ... done" : le tube place la boucle dans un
# SOUS-SHELL, les jobs "&" deviennent ses enfants, et le "wait" du shell
# principal n'a alors rien a attendre -- il rend la main aussitot, le cat lit un
# repertoire vide et le rm -rf supprime la cible pendant que les ssh tournent
# encore ("Directory nonexistent"). En lisant depuis un FICHIER, la boucle reste
# dans le shell courant et wait fonctionne.
# Le fichier est prefixe d'un point : "$TMP"/* ne le ramassera pas.
nodes > "$TMP/.list"

while read -r name ip; do
    (
        r=$(ssh -n $SSH_OPTS "$SSH_USER@$ip" "$PCPNA $ACTION" 2>&1) \
            && printf '%-12s %s\n' "$name" "$r" > "$TMP/$name" \
            || printf '%-12s ÉCHEC (%s)\n' "$name" "$(echo "$r" | head -1)" > "$TMP/$name"
    ) &
done < "$TMP/.list"
wait

cat "$TMP"/* 2>/dev/null | sort
rm -rf "$TMP"
