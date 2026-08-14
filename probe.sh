#!/bin/sh
# pcpNetAudio - reconnaissance matérielle d'un nœud
#
# À exécuter AVANT le déploiement, pour remplir nodes.conf sur des faits
# plutôt que sur des suppositions. Le parc est hétérogène : modèles de Pi et
# HAT audio différents d'un nœud à l'autre.
#
#   ./probe.sh            # lisible
#   ./probe.sh --conf     # ligne prête à coller dans nodes.conf

CONF_MODE=""
[ "$1" = "--conf" ] && CONF_MODE=1

# ---------------------------------------------------------------- matériel

MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "inconnu")

# EEPROM du HAT si présente (absente si l'overlay est forcé dans config.txt)
if [ -r /proc/device-tree/hat/product ]; then
    HAT=$(tr -d '\0' < /proc/device-tree/hat/product)
    HAT_VENDOR=$(tr -d '\0' < /proc/device-tree/hat/vendor 2>/dev/null)
else
    HAT="(pas d'EEPROM - overlay forcé ?)"
    HAT_VENDOR=""
fi

ARCH=$(uname -m)
KERNEL=$(uname -r)
PCPVER=$(sed -n 's/^PCPVERS="\(.*\)"/\1/p' /usr/local/etc/pcp/pcpversion.cfg 2>/dev/null)
RAM_TOTAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
RAM_AVAIL=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)

# ---------------------------------------------------------------- réseau
# Détermine si le nœud est filaire ou Wi-Fi : conditionne les cibles de latence
# et le réglage buffer de snapcast.

# ATTENTION : busybox sur pCP n'embarque PAS la commande "ip". Toute detection
# ecrite avec "ip route get" / "ip addr" renvoie du vide en silence, ce qui
# produisait une ligne nodes.conf sans adresse en mode --conf.
# Disponibles sur pCP : ifconfig, route. /proc/net/route est le plus sur des
# trois, il ne depend d'aucun binaire.

# Interface portant la route par defaut : destination 00000000 dans /proc/net/route.
IFACE=$(awk 'NR>1 && $2=="00000000" {print $1; exit}' /proc/net/route 2>/dev/null)
[ -n "$IFACE" ] || IFACE=$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $NF; exit}')

case "$IFACE" in
    eth*|en*)  LINK="filaire" ;;
    wlan*|wl*) LINK="wifi" ;;
    *)         LINK="inconnu" ;;
esac

# busybox ifconfig ecrit "inet addr:192.168.1.23", net-tools recent "inet 192.168.1.23".
IP=$(ifconfig "$IFACE" 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -1)
[ -n "$IP" ] || IP=$(ifconfig "$IFACE" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)

# ---------------------------------------------------------------- cartes son
# NE PAS prendre bêtement la première carte : l'audio interne bcm2835
# (HDMI / jack) apparaît souvent en card 0 et n'est pas le HAT.

ALL_CARDS=$(aplay -l 2>/dev/null | sed -n 's/^card \([0-9]*\): \([^ ]*\) \[\([^]]*\)\].*/\2|\3/p')
# L'audio interne se nomme "Headphones" en nom court et ne porte "bcm2835" que
# dans sa description :
#     Headphones|bcm2835 Headphones
# Filtrer sur le seul nom court (^bcm2835) ne matche donc JAMAIS et laisse
# passer la carte interne. Le filtre porte sur les deux champs.
HAT_CARD=$(printf '%s\n' "$ALL_CARDS" | grep -viE '(^|\|)bcm2835|(^|\|)Headphones|vc4hdmi' | head -1 | cut -d'|' -f1)
[ -n "$HAT_CARD" ] || HAT_CARD=$(printf '%s\n' "$ALL_CARDS" | head -1 | cut -d'|' -f1)

CAPTURE=$(arecord -l 2>/dev/null | sed -n 's/^card [0-9]*: \([^ ]*\) .*/\1/p' | head -1)
[ -n "$CAPTURE" ] || CAPTURE="aucune"

# Capacités réelles du DAC : formats et fréquences acceptés
if [ -n "$HAT_CARD" ]; then
    # NE PAS utiliser "-d 0 /dev/zero" : durée illimitée sur une source infinie,
    # aplay ne rend jamais la main et reste accroché au DAC. fleet.sh appelant
    # probe.sh sans timeout, la boucle d'inventaire se fige sur le 1er nœud.
    # /dev/null suffit : aplay dumpe les paramètres puis sort sur EOF immédiat.
    # Le timeout est une ceinture en plus des bretelles.
    HW=$(timeout 5 aplay -D "hw:CARD=$HAT_CARD" --dump-hw-params /dev/null 2>&1)
    FORMATS=$(printf '%s' "$HW" | sed -n '/^FORMAT:/{n;p;}' | head -1)
    [ -n "$FORMATS" ] || FORMATS=$(printf '%s' "$HW" | grep -A1 '^FORMAT' | tail -1)
    RATES=$(printf '%s' "$HW" | grep -A1 '^RATE' | tail -1)
fi

# Contrôle de volume matériel : absent sur beaucoup de HAT (PCM5102A et
# assimilés). Détermine si une atténuation logicielle est nécessaire.
MIXERS=$(amixer -c "$HAT_CARD" scontrols 2>/dev/null | sed "s/.*'\(.*\)'.*/\1/" | tr '\n' ' ')
[ -n "$MIXERS" ] || MIXERS="(aucun)"

SL_LINE=$(ps aux 2>/dev/null | sed -n 's/.*\(\/usr\/local\/bin\/squeezelite .*\)/\1/p' | head -1)

# ---------------------------------------------------------------- sortie

if [ -n "$CONF_MODE" ]; then
    printf '%-10s %-14s client   hw     -      %s\n' \
        "$(hostname)" "$IP" "$HAT_CARD"
    exit 0
fi

cat <<EOF
======================================================================
 $(hostname)   —   $IP   ($LINK, $IFACE)
======================================================================
 Modèle      $MODEL
 HAT EEPROM  $HAT ${HAT_VENDOR:+/ $HAT_VENDOR}
 pCP         ${PCPVER:-inconnu}
 Noyau       $KERNEL   ($ARCH)
 RAM         ${RAM_TOTAL} Mo total, ${RAM_AVAIL} Mo dispo

 Cartes détectées
$(printf '%s\n' "$ALL_CARDS" | sed 's/|/  —  /' | sed 's/^/   /')

 Carte retenue    $HAT_CARD
 Capture          $CAPTURE
 Formats          ${FORMATS:-non sondé}
 Fréquences       ${RATES:-non sondé}
 Mixers ALSA      $MIXERS

 squeezelite
   ${SL_LINE:-non actif}
======================================================================
EOF

# ---------------------------------------------------------------- avertissements

echo ""
[ "$RAM_TOTAL" -lt 700 ] && \
    echo " ! RAM < 700 Mo — marge étroite, surveiller après démarrage de snapclient"
[ "$LINK" = "wifi" ] && \
    echo " ! Wi-Fi — relever le buffer snapcast (300 ms minimum) et attendre plus de gigue"
[ "$MIXERS" = "(aucun)" ] && \
    echo " ! Aucun mixer ALSA — pas de volume matériel ; en mode dmix l'atténuation logicielle est obligatoire"
printf '%s\n' "$ALL_CARDS" | grep -q '^bcm2835' && \
    echo " ! Audio interne bcm2835 actif — vérifier que '$HAT_CARD' est bien le HAT voulu"
[ "$CAPTURE" != "aucune" ] && \
    echo " > Entrée de capture présente ($CAPTURE) — ce nœud pourrait servir de source"
exit 0
