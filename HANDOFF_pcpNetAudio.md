# Handoff — pcpNetAudio

**Destinataire :** agent en SSH sur le Raspberry Pi 3B+ serveur.
**Dernière mise à jour :** 15 août 2026, session « déploiement du parc ».
**Dépôt :** `https://github.com/beaucasque/pcpNetAudio` — à jour, poussé depuis
`/home/patrice/pcpNetAudio` sur le serveur (`gh` authentifié, credential helper
posé : `git push` ne demande plus rien).

| | |
|---|---|
| **Serveur** | `piSnap`, RPi 3B+, Debian Trixie 64 bits, **192.168.1.27** — HAT HiFiBerry DAC+ADC hw v1.2 |
| **Clients** | 5 nœuds piCorePlayer 11.1.0 — `.22` `.23` `.24` `.25` `.26` |
| **Transport** | Snapcast **0.35.0** sur Ethernet, codec `pcm` |
| **LMS existant** | 192.168.1.30 |

---

## 1. Ce que le projet fait, et pourquoi ainsi

Diffuser une source analogique (table de mixage, platines) vers un parc de
lecteurs piCorePlayer, en multiroom synchronisé, **sans les secondes de latence**
du streaming line-in intégré de pCP.

```
Source analogique
      │
      ▼
 HAT HiFiBerry DAC+ADC line-in (I2S)
      │
 RPi 3B+ serveur « piSnap » — Trixie 64 bits — 192.168.1.27
      ├── snapserver 0.35.0   source alsa:// — lit la carte directement
      │                       (flux « live », codec pcm)
      └── deploy.sh / fleet.sh → contrôle du parc par SSH
      │
      ├────────── Ethernet ──────────┐
      ▼                               ▼
 pCP + snapclient              pCP + snapclient
```

Le Pi serveur cumule **deux rôles** : snapserver, et machine de contrôle.

**Pourquoi ce Pi et pas le Mac.** L'agent Claude Desktop ne supporte que x86_64,
arm64 et Windows. Les nœuds pCP sont en `armv6l`/`armv7l` — inatteignables
directement. Le serveur en Trixie **64 bits** est le point d'entrée.

**Pourquoi un HAT et pas l'Edirol UA-25EX.** Sur 3B+, l'Ethernet passe par le
contrôleur USB 2.0 partagé. Une capture USB y aurait ajouté de la gigue. Le HAT
est en I2S : seul le réseau utilise l'USB.

---

## 2. État réel du serveur — FAIT, ne pas refaire

Tout ce qui suit a été installé et vérifié le 14 août 2026.

### Étape A — plateforme

| | |
|---|---|
| OS | Debian Trixie 64 bits, `aarch64`, noyau 6.18.34 |
| Hostname | `piSnap` |
| IP | **192.168.1.27, réservation DHCP Omada faite** |
| HAT | HiFiBerry DAC+ADC hw v1.2, overlay `hifiberry-dacplusadc` |
| Carte ALSA | `sndrpihifiberry`, playback **et** capture, `card 0` |

`/boot/firmware/config.txt` (sauvegarde `.bak-pcpna-*` à côté) :

```
dtparam=i2c_arm=on            # activé, pour i2cdetect
#dtparam=audio=on             # DÉSACTIVÉ : supprime la carte parasite bcm2835
dtoverlay=hifiberry-dacplusadc
```

Capture validée : `arecord -D hw:CARD=sndrpihifiberry -f S16_LE -r 48000 -c 2 -t raw`.
Formats acceptés : **44,1 → 192 kHz, 16/24/32 bits**.

### Étape B — snapserver

`/etc/snapserver.conf` (sauvegarde `.bak-pcpna`) :

```
source = alsa:///?name=live&device=hw:CARD=sndrpihifiberry\
         &silence_threshold_percent=0.01&idle_threshold=3000
default_source = live          # nouveauté 0.35.0
sampleformat = 48000:16:2
codec = pcm
buffer = 80                    # latence de bout en bout, cf. §8
chunk_ms = 10
initial_volume = 100           # inerte : les clients sont en --mixer none
```

Commande effective d'un nœud :

```
snapclient tcp://192.168.1.27:1704 --hostID <nom> \
    --soundcard hw:CARD=sndrpihifiberry \
    --player alsa:buffer_time=40,fragments=4 \
    --mixer none
```

**La capture ne passe plus par `arecord` + FIFO.** snapserver lit la carte
directement via sa source `alsa://`, ce qui supprime un étage et — surtout — permet
la détection de silence : `pipe://` ne sait pas distinguer le silence de l'absence
de données, donc le flux restait `playing` même entrée débranchée.

Deux conséquences à ne pas oublier :

- snapserver ouvre la carte lui-même, `/dev/snd/*` est en `root:audio` 0660 → override
  `SupplementaryGroups=audio` dans `/etc/systemd/system/snapserver.service.d/audio.conf` ;
- **`pcpna-capture.service` est DÉSACTIVÉ.** Le fichier reste au dépôt comme repli,
  mais le réactiver rouvrirait la carte et entrerait en conflit avec snapserver.

Ports : **1704** flux, **1705** contrôle JSON-RPC, **1780** interface web.

### Validation de bout en bout

snapclient 0.35.0 est aussi installé **sur le serveur lui-même** (`/etc/default/snapclient`,
pointé sur `tcp://127.0.0.1:1704`, sortie `hw:CARD=sndrpihifiberry`). La chaîne
complète ADC → FIFO → snapserver → snapclient → DAC tourne : **0 underrun,
horloge à 0,002 ms, aucune erreur**. Sert de témoin permanent : si le parc
décroche mais que ce client local tient, le problème est réseau ou côté nœud.

### Étape C — SSH

Clé `~/.ssh/id_ed25519` (`pcpna-server`) déposée sur les **4 nœuds**, accès sans
mot de passe vérifié. `~/.ssh/config` porte le multiplexage (`ControlMaster`).
Les 4 empreintes d'hôte correspondent au relevé d'origine — et un cycle
d'alimentation réel sur `.23` a confirmé qu'elles **ne sont pas régénérées au
reboot**.

---

## 3. ⚠️ Snapcast 0.35.0 des deux côtés — ne pas revenir en arrière

**Debian Trixie livre snapserver 0.31.0, quatre versions en retard**, alors que
le snapclient validé sur les nœuds est en 0.35.0. Le serveur utilise donc le
`.deb` upstream :

```
snapserver_0.35.0-1_arm64_trixie.deb        # + snapclient_0.35.0-1_arm64_trixie.deb
```

Les deux sont en **`apt-mark hold`**. Ne pas faire `apt install snapserver` :
ça réintroduirait la 0.31.

Ce n'est pas cosmétique — **0.33.0 a renommé des sections de `snapserver.conf`** :
`[tcp]` → `[tcp-control]`, et les réglages de streaming TCP sont sortis de
`[stream]` vers `[tcp-streaming]`. Une conf écrite pour l'une n'est pas valide
pour l'autre. La 0.34.0 a ajouté les builds Raspberry Pi OS trixie, la 0.35.0
l'option `default_source`.

**`--host` et `--port` de snapclient sont dépréciés depuis 0.32.0.** La forme
actuelle est un argument positionnel : `snapclient tcp://192.168.1.27:1704`.

---

## 4. Le parc, relevé réellement

`./fleet.sh inventory`, 14 août 2026. **Ce relevé contredit les suppositions
antérieures — s'y fier plutôt qu'à la mémoire.**

| nœud | IP | modèle | rev | arch | RAM | HAT | mixer |
|---|---|---|---|---|---|---|---|
| `pcpDJ` | .23 | Pi 3 Model B+ | `a020d3` | armv7l | 921 Mo | HiFiBerry **DAC+** | oui |
| `pcpSystem` | .25 | Pi 3 Model B+ | `a020d3` | armv7l | 921 Mo | HiFiBerry **DAC+** | oui |
| `pcpBunker` | .22 | **Pi Zero W** | `9000c1` | **armv6l** | 427 Mo | HiFiBerry DAC | **non** |
| `pcpKitchen` | .24 | Pi Zero 2 W | `902120` | armv7l | 426 Mo | HiFiBerry DAC | **non** |
| `pcpLobby` | .26 | Pi Zero 2 W | `902120` | armv7l | 426 Mo | HiFiBerry DAC | **non** |

Points qui en découlent :

- **Les 4 sont en filaire (`eth0`).** Les trois Zero passent par un adaptateur
  USB. **Aucun nœud n'est en Wi-Fi** : la question ouverte sur la gigue Wi-Fi et
  le relèvement du `buffer` est close, les cibles de latence restent basses.
- **`pcpBunker` est un Zero W de première génération, pas un Zero 2.** ARMv6
  mono-cœur, VFPv2, sans NEON. **Ce n'est pas bloquant** : le `.deb` armhf de
  snapcast est compilé pour ARMv6 (`Tag_CPU_arch: v6`, `Tag_FP_arch: VFPv2`,
  vérifié au `readelf`) et le dépôt pCP **`armhf` est commun à armv6 et armv7**
  — les 7 dépendances s'y téléchargent. Avec `codec=pcm`, snapclient ne décode
  rien, ce qui ménage le mono-cœur. Reste le seul nœud susceptible de décrocher
  sur la synchro à 20 ms. Un Zero 2 W de rechange est disponible si besoin.
- **Trois HAT sur quatre n'ont aucun mixer ALSA.** Sans objet depuis que le
  volume est retiré (`--mixer none`), mais déterminant si le mode `dmix` était un
  jour retenu : l'atténuation logicielle y serait obligatoire.
- **`bcm2835` est actif sur `pcpDJ` et `pcpSystem`** (card 0 « Headphones »), les
  deux Pi 3B+. Ce sont les seuls nœuds où le bug 2 se manifestait.
- `CLOSEOUT="5"` est désormais posé sur **les 4 nœuds** (`install.sh` le fait).
- Les 4 nœuds portent le binaire snapclient 0.35.0 `bookworm` dans
  `/mnt/mmcblk0p2/pcpNetAudio/bin/`.

---

## 5. ⚠️ Dix bugs corrigés dans l'outillage — contexte indispensable

Les scripts n'avaient jamais tourné. Dix défauts trouvés et corrigés les 14 et
15 août ; plusieurs auraient causé des dégâts silencieux.

| # | Fichier | Défaut | Conséquence évitée |
|---|---|---|---|
| 1 | `probe.sh:58` | `aplay -d 0 /dev/zero` | durée illimitée sur source infinie → **blocage définitif**, `aplay` accroché au DAC de chaque nœud traversé |
| 2 | `probe.sh:50` | filtre `bcm2835` sur le mauvais champ | `nodes.conf` rempli avec `card Headphones` → **son par la prise jack au lieu du HAT** |
| 3 | `probe.sh:37` | `ip route get` | **`ip` n'existe pas sur pCP** (busybox) → IP et type de lien vides, ligne `--conf` cassée. Réécrit sur `/proc/net/route` + `ifconfig` |
| 4 | `fleet.sh` ×3 | `ssh` sans `-n` dans `while read` | ssh **avale stdin** → seul le 1er nœud traité, les autres disparaissent sans message |
| 5 | `deploy.sh` ×2 | idem | **seul le premier nœud déployé** |
| 6 | `deploy.sh:35` | `MODE="${4:-dmix}"` | défaut contraire à la doc → **bit-perfect perdu** silencieusement |
| 7 | `install.sh` ×4 | bugs 1, 2 dupliqués + `NB=$(… grep -c)` sous `set -e` (sort en 1 quand le compte est 0, **tue le script**) + `--host` déprécié | |

| 8 | `install.sh` | `mkdir -p "$BIN_DIR"` sans sudo | `/mnt/mmcblk0p2` est à root:root en 0755 → **échec sur tout nœud neuf**. Invisible sur pcpDJ, où le répertoire existait déjà : `mkdir -p` y était un no-op |
| 9 | `fleet.sh` | `nodes \| while read … done` | le tube met la boucle dans un **sous-shell** : les jobs `&` sont ses enfants, le `wait` du shell principal n'attend rien, il rend la main en **53 ms**, le `cat` lit un répertoire vide et le `rm -rf` supprime la cible pendant que les ssh tournent |

| 10 | `install.sh` (`pcpna-mode`, `startup.sh`) | `pgrep -f` / `pkill -f` sur un CHEMIN | `-f` compare la ligne de commande entière : tout processus qui **mentionne** le chemin est compté. `status` annonçait `snapcast` sans client actif, et le `pkill` correspondant **tuait le processus innocent**. Remplacé par une identification exacte via `/proc/<pid>/exe` |

`fleet.sh inventory` a en plus reçu un `timeout 30` par nœud : `ConnectTimeout`
ne couvre que l'établissement de la connexion, pas la durée d'exécution.

**Leçon générale : ne rien croire de non testé dans ce dépôt.** `install.sh`
reste le seul script jamais exécuté de bout en bout.

---

## 6. Acquis pCP validés antérieurement

| | |
|---|---|
| Version | piCorePlayer 11.1.0 |
| tcedir | `/mnt/mmcblk0p2/tce` (ext4) |
| Miroir | `https://repo.pcplayer.org/repo/` → **`16.x/armhf/tcz/`**, commun armv6 + armv7 |
| Init squeezelite | `/usr/local/etc/init.d/squeezelite start\|stop\|restart\|status\|force` |

**Binaire : snapclient 0.35.0, variante `bookworm`.** bullseye échoue
(`libcrypto.so.1.1`, `libFLAC.so.8`), bookworm passe (`libcrypto.so.3`,
`libFLAC.so.12`). `ldd` ne voit pas les symboles manquants — **seul `--version`
valide**.

Dépendances : `avahi flac libvorbis libopus gcc_libs pcp-libsoxr openssl`.
Toutes disponibles, y compris en armv6. `libatomic` et `libssp` **ne sont pas
des extensions** : `gcc_libs` fournit `libatomic.so.1` et `libssp.so.0`.
Pièges de nommage : `opus` n'existe pas (c'est `libopus`) ; le préfixe `pcp-` ne
signifie **pas** « plus récent » (`pcp-libopus` = 1.3.1, `libopus` = 1.5.2).

Persistance : payload sur `/mnt/mmcblk0p2` (ext4, natif) ; `/opt`, `/home`,
`usr/local/etc/pcp` via `mydata.tgz` (`filetool.sh -b`) ; hook `/opt/bootlocal.sh`
exécuté **après** montage de p2.

---

## 7. Décision de conception : hw, pas dmix

**Retenu : mode `hw`, bit-perfect préservé.** Les deux sources ne jouent jamais
simultanément sur une même enceinte dans l'usage prévu.

`dmix` coûte trois choses : rééchantillonnage vers une fréquence fixe, sommation,
et atténuation numérique obligatoire (×0,3 ≈ −10 dB ≈ 1,7 bit perdu — un 16 bits
devient ~14 bits utiles). Sans atténuation la somme de deux flux sature, les HAT
DAC n'ayant pas de volume matériel — ce que le relevé du §4 confirme sur trois
nœuds sur quatre.

Conséquences en mode hw : pas de `.asoundrc`, `CLOSEOUT` positionné, script
`pcpna-mode` déposé, et **snapclient ne démarre pas au boot** — l'état par défaut
est LMS.

---

## 8. Travail restant

### Immédiat, bloquant

1. **Brancher la table de mixage sur l'entrée ligne.** La chaîne transporte
   actuellement du silence à −93 dBFS. L'ADC convertit bien (37 % d'échantillons
   non nuls = bruit analogique réel, pas des zéros), mais rien n'est branché.
   **Le DAC+ADC n'expose AUCUN contrôle de gain d'entrée** — pas un seul contrôle
   `Capture`/`ADC`/`PGA`, l'étage d'entrée est câblé en dur. Le niveau se règle
   **exclusivement à la sortie de la table**. Pour mesurer : arrêter
   `pcpna-capture` (elle tient la carte en `hw:` exclusif), échantillonner 5 s,
   relancer.
2. **Réservation DHCP Omada pour `.27`**, avant tout déploiement : l'IP part en
   dur dans chaque nœud.

### Réglage du buffer — prochaine étape

`buffer` est le budget de latence **de bout en bout**, pas un tampon réseau.
**RÉGLÉ à 80 ms** (15 août), contre 1000 au départ — soit −92 %.

`buffer` ne se règle pas seul : il ne peut pas descendre sous la somme des étages
FIXES de la chaîne — le tampon ALSA du lecteur et `chunk_ms` côté serveur. Aux
défauts amont (80 ms + 20 ms) ce plancher vaut ~150 ms, et c'est précisément là
que butait le premier réglage.

| Configuration | Plancher |
|---|---|
| ALSA 80 / chunk 20, `pipe://` — défauts amont | ~150 ms |
| ALSA 40 / chunk 10, `pipe://` | ~100 ms |
| ALSA 40 / chunk 10, **`alsa://`** | **~80 ms — retenu** |
| ALSA 20 / 2 fragments | **pire** : décroche dès 80 ms |

Vérifié à 80 ms : **0 anomalie sur 150 s** en régime permanent, clients et serveur.

⚠ **Mesurer le régime permanent, pas le démarrage.** Chaque bascule vers snapcast
produit un transitoire — le tampon de capture ALSA a accumulé du retard que
snapserver rattrape d'un coup (`fast forwarding from 149,5 ms to 30 ms`), d'où un
`onResync` d'environ 117 ms et un XRUN chez les clients. C'est audible comme un
bref accroc **au moment de la bascule**, puis plus rien. Purger les journaux
30 s après le démarrage avant toute mesure, sinon on impute au réglage ce qui
n'appartient qu'à la mise en route.

**Descendre n'est pas monotone.** Sous 40 ms de tampon ALSA, celui-ci n'amortit
plus la gigue d'ordonnancement et sous-alimente la carte : à 80 ms de buffer on
passe de 2-3 anomalies à plusieurs centaines. Ne pas « optimiser » plus bas sans
remesurer.

Réglages effectifs :

```
/etc/snapserver.conf     buffer = 80      chunk_ms = 10
sur chaque nœud          --player alsa:buffer_time=40,fragments=4
```

Exposés par `ALSA_BUFFER` / `ALSA_FRAGS` dans `install.sh`, relayés par `deploy.sh`.

**Le facteur limitant n'est PAS le nœud le plus faible.** Contre-intuitif mais
mesuré : à 60 ms, `pcpBunker` (Zero W, ARMv6 mono-cœur) journalise **57** anomalies
contre **~1370** pour les deux Zero 2 W, et sa charge ne bouge pas quand on
quadruple sa fréquence de réveil (0,52 → 0,38). Si l'on veut un jour descendre plus
bas, c'est du côté de `pcpKitchen` et `pcpLobby` qu'il faut chercher. Le plancher
est paramétrique, pas matériel.

**Conséquence acoustique :** 80 ms équivaut à une enceinte placée à ~27 m. Si une
zone Snapcast est dans la cabine, à portée du monitoring direct, le flam entre les
deux sera audible — et il l'est à n'importe quel réglage. La parade n'est pas de
baisser le buffer : c'est de **ne pas mettre de zone Snapcast dans la cabine**,
dont le monitoring sort de la table à latence nulle.

### Volume : décision arrêtée

**Il n'y a aucun réglage de volume, et c'est délibéré.** snapclient tourne en
`--mixer none`. Ni le volume logiciel (multiplication 16 bits) ni le volume
matériel (atténuation 32 bits dans le DAC) ne sont bit-perfect sous 100 %. Le
niveau se règle en **analogique**, sur les amplis de zone.

Conséquence : les curseurs de l'interface snapweb (port 1780) restent affichés mais
n'ont **aucun effet** — vérifié, une consigne à 30 % est reçue et journalisée par le
client sans que le contrôle ALSA du DAC bouge. Ne pas rouvrir ce sujet sans élément
nouveau : il a été implémenté, mesuré, puis retiré en connaissance de cause.

---

## 9. Optimisations, par rapport bénéfice/effort

- **Multiplexage SSH** — déjà en place dans `~/.ssh/config` du serveur. Écart
  assumé avec l'ancienne recommandation `Host 192.168.1.2*`, qui capturait aussi
  `.27` (le serveur lui-même) : les 4 nœuds sont listés explicitement.
- **Déclencheur physique** — DOIO KB16-01 ou macropad CH57x, une touche mappée
  sur `ssh serveur ./fleet.sh snapcast`. Probablement le plus fort gain
  d'ergonomie du lot : bascule depuis la cabine, sans terminal.
- **Interface web Snapcast** — `http://192.168.1.27:1780`, sans configuration.
  Assignation des clients, groupes, volumes par zone. Elle ne peut ni démarrer un
  snapclient arrêté ni libérer la carte côté pCP : elle complète `fleet.sh`.
- **Sources multiples** — snapserver accepte plusieurs sources. Ajouter un flux
  alimenté par une instance squeezelite sur le serveur permettrait de basculer
  « musique LMS » / « live » **par zone** depuis le web. Changement
  d'architecture, pas un réglage : à évaluer une fois le socle stable.
- **Contrôle de santé** — cron appelant `fleet.sh status`, pour ne pas découvrir
  une zone muette en pleine soirée.
- **Détection de signal** — bascule automatique sur niveau ADC. Séduisant mais
  fragile (seuils, hystérésis, faux positifs). Après plusieurs mois d'usage
  manuel seulement.

---

## 10. Pièges connus

**`/tmp` est en tmpfs sur pCP, et c'est la RACINE du système** — 385 Mo partagés
avec la RAM sur les nœuds à 427 Mo. Un `/` plein est une panne franche.

C'est pourquoi le journal de snapclient est en **`/mnt/mmcblk0p2/pcpNetAudio/snapclient.log`**
(ext4, 28 Go) et non dans `/tmp` : snapclient écrit en ajout sans borne, et lors
d'un essai à 60 ms de buffer un nœud a produit **1746 lignes en 30 s**. `install.sh`
le tronque en plus au-delà de 4 Mo, en gardant la fin — c'est l'incident récent qui
intéresse, pas le début. Bénéfice secondaire : il survit au reboot, ce qui permet
d'analyser après coup un incident survenu pendant une soirée.

**busybox, pas coreutils** — `#!/bin/sh`, pas de bashisms, `[ ]` et non `[[ ]]`,
`rm -f` dans les scripts. Et **`ip` n'existe pas** : utiliser `ifconfig`,
`route`, ou `/proc/net/route`.

**`ssh` sans `-n` dans une boucle `while read`** avale stdin. Cause des bugs 4
et 5. À vérifier dans tout nouveau script.

**`grep -c` sort en 1 quand le compte est 0** — mortel sous `set -e` dans une
substitution de commande.

**Extensions liées au noyau** — `*-6.12.67-pcpCore-v7.tcz` sont remplacées à
chaque montée de pCP. Le binaire snapclient est du userspace pur et survit :
c'est l'argument pour l'extraction de `.deb` plutôt que la compilation.

**`pcp mode`** renvoie l'état de lecture (`play`/`stop`).

---

## 11. Questions ouvertes

- **Niveau réel de la source** — rien n'a encore été branché sur l'entrée ligne.
- **Tenue de `pcpBunker`** (ARMv6 mono-cœur) sur la synchro à 20 ms. Un Zero 2 W
  de rechange est disponible.
- **snapclient relâche-t-il la carte sans flux ?** Si oui, la cohabitation avec
  squeezelite devient automatique et `pcpna-mode` ne sert plus qu'au forçage.
  Testable dès l'Étape D.
- **Pourquoi les Zero 2 W décrochent-ils avant le Zero W ?** `pcpKitchen` et
  `pcpLobby` sont matériellement identiques (`rev 902120`) et lâchent au même seuil,
  à trente anomalies près — mais **plus tôt que `pcpBunker`**, pourtant un Zero W
  mono-cœur ARMv6, plus ancien et plus faible. Ce sont eux qui fixent le plancher
  du parc.

  **Deux pistes déjà éliminées, ne pas les rouvrir :**

  - *Adaptateur Ethernet USB* — c'est le **même modèle** sur les trois Zero.
  - *Fréquence CPU / governor* — les Zero 2 W tournaient à 700-800 MHz sous
    `ondemand` contre 1000 pour le Zero W, hypothèse séduisante : sur un mono-cœur
    la charge de snapclient est visible et le governor maintient le maximum, tandis
    que diluée sur quatre cœurs elle passe inaperçue. **Testé : faux.** En
    `performance`, les quatre cœurs montent bien à 1000 MHz (et pcpDJ à 1400), et le
    plancher ne bouge pas d'un millimètre — 70 ms reste marginal, 60 ms rompt. Le
    governor a été remis à `ondemand` : inutile de consommer et chauffer pour rien.

  Restent : interruptions du Wi-Fi/BT embarqué, comportement du pilote USB, ou la
  migration du fil audio entre cœurs sur un quad-cœur — un mono-cœur sérialise tout
  et n'a ni migration ni rebond de cache. Cette dernière piste est cohérente avec
  l'observation, mais **non vérifiée**.

  À relativiser : la somme des étages fixes (ALSA 40 + chunk 10) vaut 50 ms, et la
  rupture est à 60. On est donc à ~10-20 ms du plancher théorique de l'architecture.
  Il reste peu à gagner, quelle qu'en soit la cause.

---

## 12. Options écartées

Ne pas rouvrir sans élément nouveau.

| Option | Motif |
|---|---|
| Agent Claude Desktop sur pCP | pas de binaire `armv6l`/`armv7l` |
| Migration piCore64 | reflash complet, gain incertain |
| `m-kloeckner/snapcast-tcz` | snapclient **0.6** (~2016), protocole incompatible |
| Compilation depuis les sources | inutile : le `.deb` bookworm fonctionne, y compris en ARMv6 |
| Remplacer le Zero W de pcpBunker | non nécessaire : le `.deb` armhf est compilé ARMv6 et le dépôt pCP est commun. À reconsidérer seulement si le mono-cœur décroche |
| trx / RTP point-à-point | pas de synchro multiroom |
| AES67 | pas de PTP matériel sur Pi 3/4 |
| AVB | exige un shaper 802.1Qav dans la NIC + switches SRP |
| Dante | propriétaire, matériel dédié |
| Line-in pCP → LMS | latence de plusieurs secondes |
| Snapserver sur pCP | pas de `.tcz`, extraction plus lourde que pour le client |
| Snake XLR passif | 0 ms, mais pas de multiroom |
| Pi 5 en serveur | surdimensionné ; le 3B+ suffit avec un HAT I2S |
| mode dmix par défaut | sacrifie le bit-perfect pour un cas d'usage inexistant ici |
| snapserver depuis apt (Debian) | 0.31.0, incompatible avec la conf et les clients 0.35 |

---

## 13. Contexte utilisateur

Communication en **français**. Réponses techniques denses, commandes explicites,
marqueurs d'incertitude assumés plutôt que généralités prudentes. Corriger les
erreurs franchement, y compris les siennes propres formulées plus tôt.

Environnement : Mac (Claude Desktop, Claude Code), Ubuntu Studio 192.168.1.71,
FreedomBox (RPi4 arm64), PiDeck Next (RPi5), LMS 192.168.1.30, parc pCP.
Matériel de déclenchement disponible : DOIO KB16-01, macropad CH57x.
