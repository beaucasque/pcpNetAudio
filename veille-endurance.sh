#!/bin/bash
# pcpNetAudio - épreuve d'endurance, phase 2.
#
# Ajout par rapport à la phase 1 : le compteur de « fast forwarding » du serveur.
# Un fast forwarding JETTE ~30 ms d'audio à la source pour rattraper un retard de
# lecture. Les clients reçoivent un flux continu, donc ne signalent RIEN -- mais
# le trou s'entend. La métrique précédente, qui ne comptait que les anomalies
# clients, était aveugle au défaut le plus audible : c'est l'oreille de
# l'utilisateur qui l'a signalé, pas la mesure.
#
# Ne fait que LIRE des journaux : aucune interférence avec la lecture audio.

CSV=/home/patrice/pcpNetAudio/endurance.csv
NODES="22:pcpBunker 23:pcpDJ 24:pcpKitchen 25:pcpSystem 26:pcpLobby"

ENTETE="horodatage,noeud,anomalies,connecte,flux_etat,resync_srv,fastfwd_srv"

# L'entête est vérifiée à CHAQUE tour, pas seulement au démarrage.
#
# Vécu : le CSV a été archivé pendant que la veille tournait. Le test d'entête
# ayant déjà eu lieu, elle a continué d'écrire des lignes brutes dans un fichier
# neuf et sans entête -- illisible par csv.DictReader, donc « aucun échantillon »
# alors que 495 lignes de données étaient là. Un contrôle par tour coûte un
# test de fichier toutes les 5 minutes et supprime le problème.
verifie_entete() {
    [ -s "$CSV" ] && head -1 "$CSV" | grep -q '^horodatage,' && return
    if [ -s "$CSV" ]; then
        printf '%s\n' "$ENTETE" | cat - "$CSV" > "$CSV.tmp" && mv "$CSV.tmp" "$CSV"
    else
        printf '%s\n' "$ENTETE" > "$CSV"
    fi
}

FIN=$(( $(date +%s) + 10*3600 ))
while [ "$(date +%s)" -lt "$FIN" ]; do
    verifie_entete
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    FLUX=$(curl -s -m 8 http://127.0.0.1:8080/api/etat 2>/dev/null \
           | python3 -c 'import sys,json;print(json.load(sys.stdin)["flux_etat"])' 2>/dev/null || echo "?")
    J=$(sudo journalctl -u snapserver --no-pager -o cat 2>/dev/null)
    RS=$(printf '%s' "$J" | grep -c onResync)
    FF=$(printf '%s' "$J" | grep -ci 'fast forwarding')
    for n in $NODES; do
        ip=${n%%:*}; nom=${n##*:}
        A=$(timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=6 tc@192.168.1."$ip" \
              'grep -icE "underrun|xrun|dropout|resync|error" /mnt/mmcblk0p2/pcpNetAudio/snapclient.log' 2>/dev/null)
        if [ -z "$A" ]; then
            A="-1"; C="non"
        else
            C=$(timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=6 tc@192.168.1."$ip" \
                  'pgrep snapclient >/dev/null && echo oui || echo non' 2>/dev/null || echo "?")
        fi
        echo "$TS,$nom,$A,$C,$FLUX,$RS,$FF" >> "$CSV"
    done
    sleep 300
done
