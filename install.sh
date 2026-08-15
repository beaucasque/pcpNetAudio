#!/bin/sh
# pcpNetAudio - installeur snapclient pour piCorePlayer
#
# Validé sur pCP 11.1.0 / piCore 16.x / armhf (RPi 3B+)
#
# Usage :
#   SNAPSERVER=192.168.1.27 ./install.sh              # mode hw (défaut)
#   SNAPSERVER=192.168.1.27 ALSA_MODE=dmix ./install.sh
#
# Variables :
#   SNAPSERVER   IP du snapserver                       (obligatoire)
#   ALSA_MODE    hw | dmix                              (défaut: hw)
#   ATTEN        atténuation, mode dmix uniquement      (défaut: 0.3)
#   RATE         fréquence dmix                         (défaut: 48000)
#   CARD         nom carte ALSA, auto-détecté si vide
#   NODE_NAME    nom du client snapcast                 (défaut: hostname)
#   CLOSEOUT     secondes avant libération ALSA         (défaut: 5)
#   ALSA_BUFFER  tampon ALSA du lecteur, en ms          (défaut: 40, min 10)
#   ALSA_FRAGS   nombre de fragments ALSA               (défaut: 4, min 2)
#   PCPNA_DIR    répertoire d'installation              (défaut: /mnt/mmcblk0p2/pcpNetAudio)
#
# Mode hw   : bit-perfect. squeezelite et snapclient s'excluent mutuellement.
#             Bascule par `pcpna-mode snapcast|lms`. Au boot : LMS.
# Mode dmix : cohabitation simultanée, au prix du bit-perfect et d'une
#             atténuation numérique. Au boot : snapclient démarre.

set -e

PCPNA_DIR="${PCPNA_DIR:-/mnt/mmcblk0p2/pcpNetAudio}"
SNAPSERVER="${SNAPSERVER:-}"
ALSA_MODE="${ALSA_MODE:-hw}"
ATTEN="${ATTEN:-0.3}"
RATE="${RATE:-48000}"
CARD="${CARD:-}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
CLOSEOUT="${CLOSEOUT:-5}"
# Tampon ALSA du lecteur. Avec chunk_ms cote serveur, il forme le plancher
# INCOMPRESSIBLE sous lequel "buffer" ne peut pas descendre.
#
# Mesure sur ce parc :
#   ALSA 80 / chunk 20  ->  plancher ~150 ms  (defaut amont)
#   ALSA 40 / chunk 10  ->  plancher ~100 ms  <- retenu
#   ALSA 20 / 2 frags   ->  PIRE : plus assez de profondeur pour absorber la
#                           gigue d'ordonnancement, ca decroche des 80 ms
#
# Descendre n'est donc pas monotone : sous 40 ms le tampon cesse d'amortir.
ALSA_BUFFER="${ALSA_BUFFER:-40}"
ALSA_FRAGS="${ALSA_FRAGS:-4}"

BIN_DIR="$PCPNA_DIR/bin"
# Le journal vit sur ext4, PAS dans /tmp.
# /tmp est un tmpfs qui EST la racine du systeme sur pCP : 385 Mo partages avec
# la RAM. Or snapclient ecrit en ajout, sans borne -- lors d'un essai a 60 ms de
# buffer, un noeud a produit 1746 lignes en 30 s. Un incident prolonge remplirait
# le tmpfs d'un noeud a 427 Mo, et un / plein sur piCorePlayer est une panne
# franche. Sur p2 il y a 28 Go, et le journal survit au reboot -- ce qui est
# justement ce qu'on veut pour analyser un incident survenu pendant une soiree.
LOG="$PCPNA_DIR/snapclient.log"
WORK="/tmp/pcpna-build.$$"
SL_INIT="/usr/local/etc/init.d/squeezelite"
PCP_CFG="/usr/local/etc/pcp/pcp.cfg"

DEPS="avahi flac libvorbis libopus gcc_libs pcp-libsoxr openssl"

log() { printf '[pcpNetAudio] %s\n' "$*"; }
die() { printf '[pcpNetAudio] ERREUR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- pré-vol

[ -n "$SNAPSERVER" ] || die "SNAPSERVER non défini"

case "$ALSA_MODE" in
    hw|dmix) ;;
    *) die "ALSA_MODE doit être 'hw' ou 'dmix' (reçu: $ALSA_MODE)" ;;
esac

case "$(uname -m)" in
    armv7l|armv6l) DEB_ARCH="armhf" ;;
    aarch64)       DEB_ARCH="arm64" ;;
    *)             die "architecture non supportée: $(uname -m)" ;;
esac

[ -d /mnt/mmcblk0p2 ] || die "/mnt/mmcblk0p2 absent - partition tce non montée ?"

log "$NODE_NAME | $(uname -m) -> $DEB_ARCH | mode $ALSA_MODE"

# ---------------------------------------------------------------- dépendances
# tce-load dérive dépôt, version et architecture de /opt/tcemirror.
# Ne JAMAIS coder d'URL en dur : le dépôt pCP nomme l'arch "armhf" là où
# TinyCore amont utilise "armv7", et la version suit celle de pCP.

log "dépendances"
FAILED_DEPS=""
for ext in $DEPS; do
    printf '  %-16s ' "$ext"
    if tce-load -wi "$ext" >/dev/null 2>&1; then echo "ok"
    else echo "ÉCHEC"; FAILED_DEPS="$FAILED_DEPS $ext"; fi
done
[ -z "$FAILED_DEPS" ] || log "AVERTISSEMENT: échecs:$FAILED_DEPS"

# ---------------------------------------------------------------- variante Debian
# Le .deb snapclient est lié à des SONAME variables selon la distribution :
#   bullseye          -> libcrypto.so.1.1 / libFLAC.so.8
#   bookworm, trixie  -> libcrypto.so.3   / libFLAC.so.12
# piCore 16.x fournit OpenSSL 3.x + FLAC 1.4 -> bookworm.

if [ -e /usr/local/lib/libcrypto.so.3 ]; then
    VARIANTS="bookworm trixie bullseye"
else
    VARIANTS="bullseye bookworm trixie"
fi

# Binaire deja en place et fonctionnel : on ne retelecharge pas.
#
# install.sh est idempotent et relance a chaque deploiement, or l'essentiel de
# son travail est de la configuration. Interroger l'API GitHub a chaque fois rend
# un redeploiement dependant d'Internet et le fait AVORTER sur un simple timeout
# -- constate en vrai sur pcpLobby : "wget: download timed out", et rien n'a ete
# configure alors que le binaire etait deja installe et valide.
#
# FORCE_BIN=1 pour forcer la mise a jour du binaire.
if [ -z "$FORCE_BIN" ] && [ -x "$BIN_DIR/snapclient" ] \
   && VER=$("$BIN_DIR/snapclient" --version 2>/dev/null | head -1); then
    INSTALLED=$(cat "$PCPNA_DIR/.variant" 2>/dev/null || echo "inconnu")
    log "binaire déjà présent : $VER ($INSTALLED) — téléchargement ignoré"
    log "  (FORCE_BIN=1 pour le mettre à jour)"
    SKIP_DL=1
fi

if [ -z "$SKIP_DL" ]; then
mkdir -p "$WORK" && cd "$WORK"

log "recherche de la dernière release snapcast"
RELEASES=$(wget -q -O - https://api.github.com/repos/badaix/snapcast/releases/latest) \
    || die "API GitHub injoignable"

INSTALLED=""
for variant in $VARIANTS; do
    URL=$(printf '%s' "$RELEASES" | grep -o 'https://[^"]*\.deb' \
          | grep -i "client" | grep "_${DEB_ARCH}_${variant}\.deb$" | head -1)
    [ -n "$URL" ] || continue

    log "essai $variant"
    rm -rf usr data.tar.* control.tar.* debian-binary snapclient.deb
    wget -q -O snapclient.deb "$URL" || continue
    ar x snapclient.deb 2>/dev/null || continue
    tar xf data.tar.xz 2>/dev/null || tar xf data.tar.gz 2>/dev/null || continue
    [ -x usr/bin/snapclient ] || continue

    MISSING=$(ldd usr/bin/snapclient 2>/dev/null | grep 'not found' || true)
    if [ -n "$MISSING" ]; then
        printf '%s\n' "$MISSING" | sed 's/^/      /'
        continue
    fi

    # ldd ne voit pas les symboles manquants : seule l'exécution tranche
    if VER=$(./usr/bin/snapclient --version 2>&1 | head -1); then
        log "  $VER"
        INSTALLED="$variant"
        break
    fi
done

[ -n "$INSTALLED" ] || die "aucune variante Debian fonctionnelle"

# /mnt/mmcblk0p2 appartient a root:root en 0755 : l'utilisateur tc ne peut PAS
# y creer de repertoire. Il faut sudo pour la creation, puis rendre l'arbre a
# tc pour que le reste du script (binaire, scripts, .variant) ecrive sans sudo.
# Ne se voyait pas sur un noeud ou le repertoire existait deja : mkdir -p y est
# un no-op silencieux.
sudo mkdir -p "$BIN_DIR"
sudo chown -R "$(id -un):$(id -gn)" "$PCPNA_DIR"
cp usr/bin/snapclient "$BIN_DIR/snapclient"
chmod +x "$BIN_DIR/snapclient"
printf '%s\n' "$INSTALLED" > "$PCPNA_DIR/.variant"
cd / && rm -rf "$WORK"
log "binaire installé ($INSTALLED)"
fi   # fin du bloc de telechargement

# ---------------------------------------------------------------- carte ALSA

# Le parc est hétérogène : modèles de Pi et HAT audio différents selon les
# nœuds. NE PAS prendre la première carte de `aplay -l` — l'audio interne
# bcm2835 (HDMI / jack) apparaît souvent en card 0 et n'est pas le HAT.
# `probe.sh` donne l'inventaire réel ; CARD= dans nodes.conf force au besoin.

if [ -z "$CARD" ]; then
    # On capture nom_court|description. L'audio interne se nomme "Headphones"
    # en nom court et ne porte "bcm2835" que dans sa DESCRIPTION :
    #     card 0: Headphones [bcm2835 Headphones]
    # Filtrer sur le seul nom court ne matche donc jamais, et l'installeur
    # retenait l'audio interne au lieu du HAT. Constate en vrai sur pcpDJ.
    ALL_CARDS=$(aplay -l 2>/dev/null | sed -n 's/^card [0-9]*: \([^ ]*\) \[\([^]]*\)\].*/\1|\2/p')
    [ -n "$ALL_CARDS" ] || die "aucune carte ALSA détectée - préciser CARD="

    CANDIDATES=$(printf '%s\n' "$ALL_CARDS" | grep -viE '(^|\|)bcm2835|(^|\|)Headphones|vc4hdmi' || true)

    if [ -n "$CANDIDATES" ]; then
        CARD=$(printf '%s\n' "$CANDIDATES" | head -1 | cut -d'|' -f1)
    else
        CARD=$(printf '%s\n' "$ALL_CARDS" | head -1 | cut -d'|' -f1)
        log "AVERTISSEMENT: seul l'audio interne est disponible ($CARD)"
    fi

    # "|| true" INDISPENSABLE : grep -c sort en 1 quand le compte est 0, et
    # sous set -e l'echec d'une substitution de commande tue le script.
    NB=$(printf '%s\n' "$CANDIDATES" | grep -c . || true)
    [ "${NB:-0}" -gt 1 ] && log "AVERTISSEMENT: $NB cartes candidates, '$CARD' retenue — forcer CARD= si incorrect"
fi

# NE PAS utiliser "-d 0 /dev/zero" : duree illimitee sur une source infinie,
# aplay ne rend jamais la main et reste accroche au DAC. /dev/null suffit,
# aplay dumpe les parametres puis sort sur EOF immediat. Le timeout est une
# securite si le peripherique est deja tenu par squeezelite.
timeout 5 aplay -D "hw:CARD=$CARD" --dump-hw-params /dev/null >/dev/null 2>&1 \
    || log "AVERTISSEMENT: hw:CARD=$CARD n'a pas répondu au sondage (occupé par squeezelite ?)"

MIXERS=$(amixer -c "$CARD" scontrols 2>/dev/null | wc -l)
log "carte: $CARD ($MIXERS mixer(s) ALSA)"
[ "$MIXERS" -eq 0 ] && [ "$ALSA_MODE" = "dmix" ] \
    && log "  pas de volume matériel : l'atténuation logicielle est indispensable"

# ---------------------------------------------------------------- volume
# DECISION DE CONCEPTION : aucun controle de volume cote snapclient.
#
# snapclient sait attenuer de deux facons, et AUCUNE n'est bit-perfect sous
# 100 % :
#   software              multiplication d'echantillons 16 bits, requantifiee
#                         en 16 bits. -10 dB coutent ~1,7 bit de resolution.
#   hardware:<controle>   attenuation par le DAC dans son chemin interne
#                         32 bits. Perte bien moindre, mais non nulle.
#
# Le projet vise le bit-perfect, donc "--mixer none" : le flux traverse
# snapclient sans qu'un seul echantillon soit touche. Le niveau se regle en
# ANALOGIQUE, sur les amplis de zone.
#
# Consequence a connaitre : les curseurs de volume de l'interface web de
# snapserver (port 1780) restent affiches mais n'ont plus AUCUN effet.
log "volume: none (bit-perfect, réglage en analogique sur les amplis)"

# ---------------------------------------------------------------- config ALSA

if [ "$ALSA_MODE" = "dmix" ]; then
    log "ALSA dmix @ ${RATE}Hz, atténuation $ATTEN (bit-perfect sacrifié)"
    cat > /home/tc/.asoundrc <<EOF
# généré par pcpNetAudio - ne pas éditer
pcm.pcpna_dmix {
    type dmix
    ipc_key 2048
    ipc_perm 0666
    slave {
        pcm "hw:CARD=$CARD,DEV=0"
        rate $RATE
        channels 2
        format S16_LE
        period_size 1024
        buffer_size 8192
    }
}
pcm.pcpna_out {
    type route
    slave.pcm "pcpna_dmix"
    ttable.0.0 $ATTEN
    ttable.1.1 $ATTEN
}
EOF
    SND_DEVICE="pcpna_out"
else
    log "ALSA hw exclusif (bit-perfect préservé)"
    [ -f /home/tc/.asoundrc ] && grep -q pcpna /home/tc/.asoundrc 2>/dev/null \
        && rm -f /home/tc/.asoundrc
    SND_DEVICE="hw:CARD=$CARD"

    # -C <n> : squeezelite libère le périphérique ALSA après n secondes de
    # silence. Lisse les transitions, mais ne remplace PAS l'arrêt explicite :
    # LMS peut relancer une lecture à tout moment et entrer en collision.
    CUR=$(grep '^CLOSEOUT=' "$PCP_CFG" 2>/dev/null | cut -d'"' -f2)
    if [ -z "$CUR" ]; then
        sudo sed -i "s/^CLOSEOUT=.*/CLOSEOUT=\"$CLOSEOUT\"/" "$PCP_CFG"
        log "CLOSEOUT défini à $CLOSEOUT, redémarrage squeezelite"
        sudo "$SL_INIT" restart >/dev/null 2>&1 || true
    else
        log "CLOSEOUT déjà défini ($CUR)"
    fi
fi

# ---------------------------------------------------------------- scripts

cat > "$BIN_DIR/startup.sh" <<EOF
#!/bin/sh
# généré par pcpNetAudio
[ -x "$BIN_DIR/snapclient" ] || exit 1
# Identification EXACTE par /proc/<pid>/exe, jamais par la ligne de commande.
# "pkill -f <chemin>" tuerait tout processus dont la cmdline mentionne ce
# chemin -- y compris un shell de diagnostic. Constate en vrai.
for p in /proc/[0-9]*; do
    [ "$(readlink "$p/exe" 2>/dev/null)" = "$BIN_DIR/snapclient" ] \\
        && kill "${p#/proc/}" 2>/dev/null
done
sleep 1
# Borne le journal : au-dela de 4 Mo on repart d'une base propre plutot que de
# laisser croitre indefiniment. On garde la fin, qui porte l'incident le plus
# recent, pas le debut.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 4194304 ]; then
    tail -c 1048576 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
# Forme URL introduite en snapcast 0.32.0. "--host" et "--port" restent
# acceptes en 0.35 mais sont DEPRECIES ; 1704 est le port du flux audio.
exec "$BIN_DIR/snapclient" \\
    "tcp://$SNAPSERVER:1704" \\
    --hostID "$NODE_NAME" \\
    --soundcard "$SND_DEVICE" \\
    --player "alsa:buffer_time=$ALSA_BUFFER,fragments=$ALSA_FRAGS" \\
    --mixer none \\
    >> "$LOG" 2>&1
EOF
chmod +x "$BIN_DIR/startup.sh"

cat > "$BIN_DIR/pcpna-mode" <<EOF
#!/bin/sh
# pcpna-mode snapcast|lms|status - bascule de la carte son
BIN="$BIN_DIR"
INIT="$SL_INIT"

# Liste les PID executant REELLEMENT notre binaire, via /proc/<pid>/exe.
#
# Ne PAS utiliser "pgrep -f <chemin>" : -f compare la ligne de commande
# complete, donc n'importe quel processus qui se contente de MENTIONNER le
# chemin est compte -- un shell de diagnostic, un script, une commande ssh.
# Constate en vrai : "pcpna-mode status" annoncait snapcast alors qu'aucun
# client ne tournait, et le pkill correspondant aurait tue l'intrus.
snap_pids() {
    for p in /proc/[0-9]*; do
        [ "\$(readlink "\$p/exe" 2>/dev/null)" = "\$BIN/snapclient" ] \\
            && echo "\${p#/proc/}"
    done
}

case "\$1" in
    snapcast)
        sudo \$INIT stop >/dev/null 2>&1
        sleep 2
        "\$BIN/startup.sh" &
        sleep 2
        [ -n "\$(snap_pids)" ] \\
            && echo "snapcast" || { echo "ÉCHEC - voir $LOG" >&2; exit 1; }
        ;;
    lms)
        for pid in \$(snap_pids); do kill "\$pid" 2>/dev/null; done
        sleep 2
        sudo \$INIT start >/dev/null 2>&1
        sleep 1
        # pgrep SANS -f : compare le nom du processus, pas la ligne de
        # commande. C'est sûr, contrairement a la variante -f.
        pgrep squeezelite >/dev/null \\
            && echo "lms" || { echo "ÉCHEC squeezelite" >&2; exit 1; }
        ;;
    status)
        [ -n "\$(snap_pids)" ] && echo "snapcast" || echo "lms"
        ;;
    *)
        echo "Usage: pcpna-mode [snapcast|lms|status]" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$BIN_DIR/pcpna-mode"

# ---------------------------------------------------------------- persistance
# Payload sur ext4 : persiste nativement, aucun coût RAM au boot.
# /opt et /home sont déjà dans .filetool.lst par défaut.

# Le symlink /usr/local/bin/pcpna-mode est un CONFORT, PAS une dependance.
#
# fleet.sh appelle pcpna-mode par son chemin absolu sur ext4. Le symlink ne sert
# qu'a la frappe manuelle sur un noeud. Rien ne casse s'il est absent.
#
# HISTOIRE, a ne pas repeter : une version anterieure ajoutait la pose du lien a
# la FIN de bootlocal.sh. Sur pcpBunker (Zero W, armv6) la ligne n'etait jamais
# atteinte -- bootlocal.sh appelle "pcp_startup.sh | tee", et ce pipeline ne
# rendait pas la main sur ce noeud. J'ai alors deplace la ligne AVANT
# pcp_startup.sh : le noeud n'a plus demarre du tout. Ni SSH ni serveur web,
# seulement le ping. Recuperation par carte SD et "norestore" dans cmdline.txt.
#
# Lecon : NE RIEN INSERER AVANT pcp_startup.sh DANS bootlocal.sh. La pose du lien
# est desormais ajoutee en fin de fichier et purement optionnelle -- si elle n'est
# jamais atteinte, le parc fonctionne quand meme.
BOOT_MARK="pcpna-mode /usr/local/bin"
BOOT_LINE="[ -x $BIN_DIR/pcpna-mode ] && ln -sf $BIN_DIR/pcpna-mode /usr/local/bin/pcpna-mode"

sudo sed -i "\\|$BOOT_MARK|d" /opt/bootlocal.sh 2>/dev/null || true
echo "$BOOT_LINE" | sudo tee -a /opt/bootlocal.sh >/dev/null
log "symlink pcpna-mode : ligne ajoutée en FIN de bootlocal.sh (optionnelle)"

# Pose immediate, qui elle est certaine.
sudo ln -sf "$BIN_DIR/pcpna-mode" /usr/local/bin/pcpna-mode

# En mode hw, snapclient NE démarre PAS au boot : l'état par défaut est LMS.
if [ "$ALSA_MODE" = "dmix" ]; then
    if ! grep -qF "$BIN_DIR/startup.sh" /opt/bootlocal.sh 2>/dev/null; then
        echo "$BIN_DIR/startup.sh &" | sudo tee -a /opt/bootlocal.sh >/dev/null
        log "autostart snapclient ajouté (mode dmix)"
    fi
else
    sudo sed -i "\|$BIN_DIR/startup.sh &|d" /opt/bootlocal.sh 2>/dev/null || true
fi

log "sauvegarde"
filetool.sh -b >/dev/null

# ---------------------------------------------------------------- résumé

cat <<EOF

  $NODE_NAME — installation terminée
  ----------------------------------------------------
  binaire    $BIN_DIR/snapclient ($INSTALLED)
  serveur    $SNAPSERVER
  sortie     $SND_DEVICE
  mode       $ALSA_MODE
  volume     none (bit-perfect)
  tampon     ALSA ${ALSA_BUFFER}ms / $ALSA_FRAGS fragments
  logs       $LOG

EOF

if [ "$ALSA_MODE" = "hw" ]; then
    cat <<EOF
  Bit-perfect préservé. Les deux services s'excluent.
  Au boot : LMS. Bascule :

      pcpna-mode snapcast
      pcpna-mode lms
      pcpna-mode status

EOF
else
    cat <<EOF
  ÉTAPE MANUELLE - interface web pCP :
  Squeezelite Settings > Audio output device > "pcpna_out"
  ALSA Volume Control > vider, puis Save + Restart.
  Sans ça squeezelite garde la carte et snapclient reste muet.

EOF
fi
