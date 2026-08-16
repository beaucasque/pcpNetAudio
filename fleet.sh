#!/bin/sh
# pcpNetAudio - contrôle et reconnaissance du parc
#
# Distinct de deploy.sh : celui-ci ne réinstalle rien.
#
#   ./fleet.sh inventory         # reconnaissance matérielle de tout le parc
#   ./fleet.sh inventory --conf  # lignes prêtes à coller dans nodes.conf
#   ./fleet.sh status            # état de chaque nœud (snapcast | lms)
#   ./fleet.sh health            # diagnostic complet, reconnaît les pannes connues
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
    snapcast|lms|status|log|inventory|health) ;;
    *) echo "Usage: $0 [inventory|status|health|snapcast|lms|log] [--conf] [nœud...]" >&2
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

# ---------------------------------------------------------------- health
#
# Reconnait la panne qui a coute trois reinstallations : /opt/bootlocal.sh non
# executable. Le noeud repond alors au ping et A RIEN D AUTRE -- pcp_startup.sh
# n'est jamais lance, donc ni sshd, ni serveur web, ni squeezelite. Il parait
# mort alors qu'il a parfaitement demarre.
#
# Signature : ping OK + port 22 ferme. Le remede tient en une commande, mais il
# faut un clavier et un ecran sur le noeud puisque SSH est justement ce qui
# manque. D'ou l'interet de le diagnostiquer d'ici plutot que sur place.

if [ "$ACTION" = "health" ]; then
    ALERTES=0
    nodes | while read -r name ip; do
        printf '%-12s ' "$name"

        if ! ping -c1 -W2 "$ip" >/dev/null 2>&1; then
            echo "HORS LIGNE (pas de ping) - alimentation ou reseau"
            continue
        fi

        # NE PAS tester le port avec /dev/tcp : c'est une extension BASH, et ce
        # script tourne sous sh (dash). Le test echouait toujours, donc les cinq
        # noeuds etaient signales en panne alors qu'ils allaient bien.
        # On interroge ssh lui-meme et on lit son message d'erreur : c'est
        # portable, et ca distingue un refus de connexion d'un probleme de cle.
        SSHERR=$(timeout 12 ssh -n $SSH_OPTS "$SSH_USER@$ip" true 2>&1) || true
        case "$SSHERR" in
          *"Connection refused"*|*"Connection timed out"*|*"No route to host"*)
            echo "PING MAIS PAS DE SSH"
            echo "             -> signature d'un /opt/bootlocal.sh non executable."
            echo "                Le noeud a demarre mais pcp_startup.sh n'a pas tourne."
            echo "                Verifier sur place (ecran + clavier) :"
            echo "                    ls -l /opt/bootlocal.sh        # doit avoir les x"
            echo "                    ls -l /var/log/pcp_boot.log    # absent = confirme"
            echo "                Remede :"
            echo "                    sudo chmod +x /opt/bootlocal.sh && filetool.sh -b && sudo reboot"
            ALERTES=$((ALERTES + 1))
            continue ;;
          *"Permission denied"*)
            echo "SSH repond mais CLE REFUSEE - redeposer la cle publique"
            ALERTES=$((ALERTES + 1))
            continue ;;
        esac

        R=$(timeout 20 ssh -n $SSH_OPTS "$SSH_USER@$ip" '
            p=""
            [ -x /opt/bootlocal.sh ]            || p="$p bootlocal-non-executable"
            [ -f /var/log/pcp_boot.log ]        || p="$p pcp_boot.log-absent"
            [ -x '"$PCPNA"' ]                   || p="$p pcpna-mode-absent"
            [ -x /mnt/mmcblk0p2/pcpNetAudio/bin/snapclient ] || p="$p binaire-absent"
            grep -qF '"'"'$(readlink'"'"' /mnt/mmcblk0p2/pcpNetAudio/bin/startup.sh 2>/dev/null \
                                                || p="$p startup.sh-pre-evalue"
            sudo tar tzvf /mnt/mmcblk0p2/tce/mydata.tgz 2>/dev/null \
                | grep -q "rwx.*opt/bootlocal.sh" || p="$p sauvegarde-sans-bit-x"
            m=$('"$PCPNA"' status 2>/dev/null || echo "?")
            u=$(cut -d. -f1 /proc/uptime)
            if [ -n "$p" ]; then echo "DEFAUTS:$p|$m|$u"; else echo "OK|$m|$u"; fi
        ' 2>/dev/null)

        if [ -z "$R" ]; then
            echo "SSH ouvert mais commande sans reponse"
            ALERTES=$((ALERTES + 1))
            continue
        fi

        etat=$(echo "$R" | cut -d"|" -f1)
        mode=$(echo "$R" | cut -d"|" -f2)
        up=$(echo "$R"   | cut -d"|" -f3)

        if [ "$etat" = "OK" ]; then
            printf 'sain        mode=%-9s uptime=%sh\n' "$mode" "$((up / 3600))"
        else
            printf 'DEFAUTS     mode=%-9s uptime=%sh\n' "$mode" "$((up / 3600))"
            echo "$etat" | sed "s/^DEFAUTS://" | tr " " "\n" | grep -v "^$" | sed "s/^/             -> /"
            ALERTES=$((ALERTES + 1))
        fi
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
