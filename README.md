# pcpNetAudio

Déploiement et contrôle de Snapcast sur un parc piCorePlayer, depuis un serveur Debian.

Validé sur **pCP 11.1.0 / piCore 16.x / armhf** (Raspberry Pi 3B+).

Dérivé de [somebox/piCorePlayer-snapcast](https://github.com/somebox/piCorePlayer-snapcast),
réécrit pour piCore 16.x, le déploiement multi-nœuds non interactif et le mode bit-perfect.

## Architecture

```
Source analogique (table de mixage, platines)
        │
        ▼
   HAT HiFiBerry avec entrée ligne (I2S)
        │
   RPi 3B+ « serveur » — Debian Trixie 64 bits Lite
        ├── arecord -t raw → FIFO
        ├── snapserver
        └── deploy.sh / fleet.sh  (contrôle du parc par SSH)
        │
        ├──────────── Ethernet ────────────┐
        ▼                                   ▼
  pCP + snapclient                   pCP + snapclient
  HiFiBerry DAC                      HiFiBerry DAC
```

Le HAT est en I2S et non en USB : sur 3B+, l'Ethernet partage le contrôleur USB 2.0,
et une capture USB y ajouterait de la gigue.

## Fichiers

| Fichier | S'exécute sur | Rôle |
|---|---|---|
| `probe.sh` | chaque nœud pCP | reconnaissance matérielle |
| `install.sh` | chaque nœud pCP | deps, binaire, ALSA, persistance, `pcpna-mode` |
| `deploy.sh` | serveur | installation / mise à jour du parc (rare) |
| `fleet.sh` | serveur | reconnaissance, bascule, diagnostic (parallélisé) |
| `nodes.conf` | — | inventaire : nom, IP, mode ALSA, carte |

## Version de Snapcast — 0.35.0 des deux côtés

**Ne pas installer snapserver depuis les dépôts Debian.** Trixie livre la 0.31.0, quatre
versions en retard sur le snapclient déployé. Utiliser le `.deb` upstream, puis
`apt-mark hold` :

```
snapserver_0.35.0-1_arm64_trixie.deb
```

Ce n'est pas cosmétique : **0.33.0 a renommé des sections de `snapserver.conf`**
(`[tcp]` → `[tcp-control]`, streaming TCP sorti de `[stream]` vers `[tcp-streaming]`).
Une conf écrite pour l'une n'est pas valide pour l'autre. La 0.34.0 a ajouté les builds
Raspberry Pi OS trixie, la 0.35.0 l'option `default_source`.

Côté client, **`--host` et `--port` sont dépréciés depuis 0.32.0** : la forme actuelle est
un argument positionnel, `snapclient tcp://<serveur>:1704`.

## Parc hétérogène

Les nœuds n'ont **ni le même modèle de Raspberry Pi ni le même HAT audio**. Relevé réel
d'un parc de quatre :

| nœud | modèle | arch | RAM | HAT | mixer |
|---|---|---|---|---|---|
| pcpDJ | Pi 3 Model B+ | armv7l | 921 Mo | HiFiBerry DAC+ Pro | oui |
| pcpBunker | **Pi Zero W** | **armv6l** | 427 Mo | HiFiBerry DAC | non |
| pcpKitchen | Pi Zero 2 W | armv7l | 426 Mo | HiFiBerry DAC | non |
| pcpLobby | Pi Zero 2 W | armv7l | 426 Mo | HiFiBerry DAC | non |

Un Zero W de première génération (ARMv6, VFPv2, sans NEON) fonctionne : le `.deb` armhf
de snapcast est compilé pour ARMv6 (`Tag_CPU_arch: v6`, vérifiable au `readelf`), et le
dépôt pCP **`armhf` est commun à armv6 et armv7**. Avec `codec=pcm` snapclient ne décode
rien, ce qui ménage un mono-cœur.

Rien dans l'outillage ne suppose l'uniformité :

- la détection de carte exclut l'audio interne `bcm2835` (souvent en `card 0`, et
  presque jamais le HAT voulu) ;
- `card` est surchargeable par nœud dans `nodes.conf` ;
- `install.sh` avertit s'il trouve plusieurs cartes candidates, ou aucun mixer ALSA
  (beaucoup de HAT type PCM5102A n'ont pas de volume matériel) ;
- `probe.sh` relève modèle, EEPROM du HAT, RAM, type de lien réseau, formats et
  fréquences réellement acceptés par le DAC.

**Commencer par la reconnaissance**, avant tout déploiement :

```sh
./fleet.sh inventory           # lisible, avec avertissements par nœud
./fleet.sh inventory --conf    # lignes prêtes à coller dans nodes.conf
```

Points d'attention que la reconnaissance fait remonter : RAM sous 700 Mo (Zero 2 W),
lien Wi-Fi (relever le buffer snapcast), absence de mixer matériel, audio interne
`bcm2835` encore actif, présence d'une entrée de capture.

## Utilisation

```sh
# reconnaissance
./fleet.sh inventory

# installation
DRY_RUN=1 SNAPSERVER=192.168.1.50 ./deploy.sh
SNAPSERVER=192.168.1.50 ./deploy.sh

# exploitation
./fleet.sh status
./fleet.sh snapcast          # tout le parc vers le flux live
./fleet.sh lms               # retour à la bibliothèque
./fleet.sh snapcast pcpDJ    # un seul nœud
./fleet.sh log pcpDJ
```

Sur un nœud isolé : `pcpna-mode snapcast|lms|status`.

## Console web

`webctl.py` sert une page de contrôle sur le port 8080 du serveur, pensée pour le
téléphone depuis la cabine :

```sh
sudo systemctl enable --now pcpna-web        # unité pcpna-web.service
```

Une seule fonction, délibérément : **la bascule globale** — 100 % piCorePlayer ou
100 % Snapcast. Pas de sélecteur par zone, le projet assume un mode ou l'autre avec
ses forces, pas un panachage. La bascule délègue à `fleet.sh`, aucune logique n'est
dupliquée. Le reste de la page affiche l'état de chaque zone.

Aucun réglage de volume n'est exposé — voir la section suivante.

Après une bascule vers LMS, les quatre nœuds sont de nouveau visibles dans Lyrion
**en 6 secondes**, connectés et allumés. La lecture ne reprend pas d'elle-même : il
faut la relancer depuis Lyrion.

## Latence

`buffer` dans `snapserver.conf` **est** la latence de bout en bout : snapclient
programme la lecture à *(instant de capture + buffer)*. Ce n'est pas un tampon
réseau.

Réglé à **150 ms**, mesuré par paliers sur les 4 nœuds. Le point de rupture est
entre 125 et 100 ms : à 100 ms les décrochages sont massifs, à 125 ms c'est propre
mais la marge est de 25 ms seulement. 150 ms tient sans une anomalie sur 90 s et
laisse 50 % de marge — de quoi encaisser un pic de charge sans couper une zone en
plein set.

**La profondeur de bits n'a aucun effet sur la latence** : un chunk de 20 ms dure
20 ms qu'il soit en 16 ou 24 bits. Et le 16 bits n'est pas non plus un compromis de
qualité ici — le plancher de bruit mesuré de l'ADC est de 0,7 LSB RMS, contre
~0,29 LSB pour le bruit de quantification d'un 16 bits dithéré. Le bruit analogique
du convertisseur est ~7,6 dB **au-dessus** du plancher du 16 bits : c'est le
convertisseur qui limite, pas le format. Passer en 24 bits numériserait du bruit
avec plus de précision.

**Conséquence acoustique :** 150 ms équivaut à une enceinte à ~50 m. Une zone
Snapcast placée dans la cabine produira un flam audible avec le monitoring direct,
à n'importe quel réglage. Le monitoring cabine doit sortir de la table.

## Volume : il n'y en a pas, et c'est délibéré

`install.sh` lance snapclient avec **`--mixer none`**. Le flux traverse le client
sans qu'un seul échantillon soit touché. Le niveau se règle en **analogique**, sur
les amplis de zone.

La raison : snapclient sait atténuer de deux façons, et **aucune n'est bit-perfect
sous 100 %**.

| Mode | Ce qui se passe | Coût sous 100 % |
|---|---|---|
| `software` | multiplication d'échantillons **16 bits**, requantifiée en 16 bits | −10 dB ≈ 1,7 bit perdu |
| `hardware:<contrôle>` | atténuation par le DAC dans son chemin interne **32 bits** | négligeable, mais non nul |
| **`none`** | **rien** | **aucun** |

Le mode matériel est un net progrès sur le logiciel, pas une préservation. Puisque
tout le reste du projet est construit pour le bit-perfect — mode ALSA `hw`, `dmix`
écarté, `codec=pcm` — offrir un curseur reviendrait à fournir un moyen commode de
perdre ce qu'on protège partout ailleurs.

**Conséquence à connaître : les curseurs de volume de l'interface web de snapserver
(port 1780) restent affichés mais n'ont plus aucun effet.** Vérifié : une consigne à
30 % est bien reçue par le client et journalisée, sans que le contrôle ALSA du DAC
bouge d'un cran. `initial_volume = 100` est figé dans `snapserver.conf` pour que
l'affichage ne suggère pas une atténuation inexistante.

Si le besoin d'un volume logiciel réapparaissait, deux pièges sont documentés dans
l'historique git : `--mixer hardware` **sans nom de contrôle** cherche un mixer
appelé `PCM`, absent du PCM512x, et le client meurt sur une erreur fatale ; et sur
HiFiBerry le contrôle `Analogue` existe mais ne compte que 2 crans (0 / −6 dB),
inutilisable comme volume — seul `Digital` (0-207) l'est, et uniquement sur le
DAC+ Pro.

Le mode affiché est déduit des connexions snapserver plutôt que d'un `fleet.sh
status` en SSH : un nœud rendu à LMS a coupé son snapclient, donc il apparaît
déconnecté. C'est instantané là où l'interrogation SSH coûte deux secondes.

La page n'a **pas d'authentification** et expose un point d'entrée qui lance
`fleet.sh`. Acceptable sur un réseau domestique ; c'est la raison pour laquelle le
paramètre de mode est validé par liste blanche stricte et jamais interpolé dans un
shell.

## hw ou dmix

Sur un nœud pCP, **squeezelite tient le DAC en `hw:` exclusif**. snapclient ne peut pas
ouvrir le même périphérique tant qu'il tourne.

### Mode `hw` — défaut recommandé

Bit-perfect préservé, pas d'atténuation, latence minimale. Les deux services
s'excluent ; `pcpna-mode` arrête l'un avant de lancer l'autre. Au boot, l'état est LMS.

`install.sh` positionne `CLOSEOUT="5"` dans `pcp.cfg` (option `-C` de squeezelite) :
le périphérique est libéré après 5 s de silence, ce qui lisse les transitions. **Cela
ne remplace pas l'arrêt explicite** — LMS peut relancer une lecture à tout moment et
entrer en collision.

### Mode `dmix` — cohabitation simultanée

Nécessaire seulement si les deux sources doivent sonner **en même temps sur la même
enceinte**. Trois coûts :

| Cause | Effet |
|---|---|
| Rééchantillonnage | dmix tourne à fréquence fixe ; tout autre contenu est recalculé |
| Sommation | deux flux additionnés produisent de nouvelles valeurs |
| Atténuation | ×0,3 ≈ −10 dB ≈ 1,7 bit perdu → 16 bits deviennent ~14 bits utiles |

L'atténuation n'est pas optionnelle : la plupart des HAT DAC n'ont pas de volume
matériel, et sans elle la somme de deux flux sature.

La capture étant en 48 kHz, la fréquence dmix décide **quel chemin paie** :

| dmix | Snapcast (48 k) | LMS (44,1 k typique) |
|---|---|---|
| 48000 | propre | rééchantillonné |
| 44100 | rééchantillonné | propre |

Aucun réglage ne préserve les deux.

En mode dmix, une **étape manuelle** subsiste : interface web pCP, *Squeezelite
Settings > Audio output device* → `pcpna_out`, vider *ALSA Volume Control*, Save +
Restart.

## Écarts avec l'amont

L'installeur d'origine cible pCP 10.x / TinyCore 15.x et échoue sur 16.x :

| Point | Amont | Ici |
|---|---|---|
| Dépôt | `tinycorelinux.net/15.x/armv7` en dur | `tce-load` depuis `/opt/tcemirror` |
| Variante Debian | fixe | choisie selon les SONAME présents |
| `libatomic`, `libssp`, OpenSSL | absents | inclus |
| `opus` | nom incorrect | `libopus` |
| Emplacement binaire | `/home/tc` (RAM au boot) | `/mnt/mmcblk0p2` (ext4) |
| Démarrage | User Commands (web, manuel) | `bootlocal.sh` (scriptable) |
| Mode ALSA | dmix imposé | `hw` par défaut, dmix optionnel |
| Bascule | absente | `pcpna-mode` + `fleet.sh` |
| Exécution | interactive | paramétrée, idempotente |

Dépôt pCP 16.x armhf : `https://repo.pcplayer.org/repo/16.x/armhf/tcz/`.
L'architecture s'y nomme **`armhf`**, là où TinyCore amont utilise `armv7`
(`tinycorelinux.net/16.x/armv7/` renvoie 404).

### Choix de la variante Debian

| Variante | OpenSSL | FLAC | piCore 16.x |
|---|---|---|---|
| bullseye | `libcrypto.so.1.1` | `libFLAC.so.8` | ❌ |
| **bookworm** | `libcrypto.so.3` | `libFLAC.so.12` | ✅ validé |
| trixie | `libcrypto.so.3` | `libFLAC.so.12` | non testé |

`ldd` ne détecte que les bibliothèques absentes, **pas les symboles manquants** — seul
`./snapclient --version` valide réellement. Les variantes `with-pulse` et
`with-pipewire` sont écartées : aucune n'existe sur Tiny Core.

### Pièges de nommage des paquets

- `opus` n'existe pas → **`libopus`**
- `libopus` = 1.5.2 (2024) ; `pcp-libopus` = 1.3.1 compilé pour piCore 10.x
- le préfixe `pcp-` ne signifie **pas** « plus récent » : souvent un portage figé
- `pcp-libsoxr` (0.1.3) est la seule option soxr
- `libatomic` (via `gcc_libs`) et `libssp` sont requis, absents de la liste amont

## Persistance

| Élément | Emplacement | Mécanisme |
|---|---|---|
| binaire, scripts | `/mnt/mmcblk0p2/pcpNetAudio/` | ext4, natif, aucun backup |
| `.asoundrc` (dmix) | `/home/tc/` | `mydata.tgz` |
| `pcp.cfg` (`CLOSEOUT`) | `/usr/local/etc/pcp/` | `mydata.tgz` |
| symlink `pcpna-mode` | `/opt/bootlocal.sh` | recréé à chaque boot |

`home`, `opt` et `usr/local/etc/pcp` figurent déjà dans `.filetool.lst` par défaut.
`bootlocal.sh` s'exécute **après** le montage de p2 (vérifié).

## Diagnostic

```sh
pcpna-mode status
tail -f /tmp/snapclient.log
ldd /mnt/mmcblk0p2/pcpNetAudio/bin/snapclient | grep 'not found'
aplay -l && ps aux | grep '[s]queezelite'
```

**Device busy** : squeezelite détient la carte → `pcpna-mode snapcast`.
**Connection refused** : vérifier l'IP du snapserver et le port 1704.
**Son distordu (dmix)** : baisser `atten` dans `nodes.conf`, redéployer.

## Pièges de scripting sur pCP

Trois causes de bugs silencieux, toutes rencontrées en vrai dans ce dépôt :

- **`ip` n'existe pas** (busybox). Toute détection écrite avec `ip route get` / `ip addr`
  renvoie du vide **sans erreur**. Utiliser `/proc/net/route`, `ifconfig` ou `route`.
- **`ssh` sans `-n` dans une boucle `while read` avale stdin** : seule la première
  itération s'exécute, les suivantes disparaissent sans message. `-n` ne peut pas aller
  dans une variable d'options partagée avec `scp`, qui ne connaît pas cette option.
- **`grep -c` sort en 1 quand le compte est 0** : mortel sous `set -e` dans une
  substitution de commande.

Et deux pièges ALSA :

- **`aplay --dump-hw-params -d 0 /dev/zero` ne rend jamais la main** (durée illimitée sur
  source infinie) et reste accroché au DAC. Utiliser `/dev/null`, sous `timeout`.
- **Filtrer l'audio interne sur `^bcm2835` ne marche pas** : la carte se nomme
  `Headphones` en nom court, `bcm2835` n'apparaît que dans la description
  (`card 0: Headphones [bcm2835 Headphones]`). Filtrer sur les deux champs.

## Limites connues

- Le réglage squeezelite en mode dmix n'est pas automatisé (web pCP).
- Non testé sur arm64.
- `install.sh` n'a pas encore tourné de bout en bout, malgré quatre correctifs.

## Crédits

- [badaix/snapcast](https://github.com/badaix/snapcast)
- [somebox/piCorePlayer-snapcast](https://github.com/somebox/piCorePlayer-snapcast)
- [m-kloeckner/snapcast-tcz](https://github.com/m-kloeckner/snapcast-tcz)
