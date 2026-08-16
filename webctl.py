#!/usr/bin/env python3
"""pcpNetAudio - console web de contrôle du parc.

Une seule fonction : la bascule GLOBALE du parc, 100 % piCorePlayer (LMS) ou
100 % Snapcast. Pas de sélecteur par zone — le projet assume un mode ou l'autre,
chacun avec ses forces, et pas un panachage.

Il n'y a DÉLIBÉRÉMENT aucun réglage de volume. snapclient tourne en
"--mixer none" : le flux le traverse sans qu'un échantillon soit touché. Ni le
volume logiciel (multiplication 16 bits) ni le volume matériel (atténuation
32 bits dans le DAC) ne sont bit-perfect sous 100 %. Le niveau se règle en
analogique, sur les amplis de zone. Exposer un curseur ici reviendrait à offrir
un moyen commode de perdre ce que tout le reste du projet cherche à préserver.

La bascule délègue à fleet.sh : aucune logique n'est dupliquée ici. L'état est
lu par le JSON-RPC de snapserver sur le port 1705.

Écoute sur le LAN sans authentification, et expose un point d'entrée qui lance
fleet.sh. C'est acceptable sur un réseau domestique, mais c'est la raison pour
laquelle le paramètre de mode est validé par liste blanche stricte et jamais
interpolé dans un shell.

    python3 webctl.py [port]        # défaut 8080
"""

import json
import socket
import time
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

RPC_HOST = "127.0.0.1"
RPC_PORT = 1705
REPO = Path(__file__).resolve().parent
FLEET = REPO / "fleet.sh"

# Une seule bascule à la fois : fleet.sh met ~4 s et deux exécutions
# concurrentes se marcheraient dessus sur les mêmes nœuds.
_switch_lock = threading.Lock()
_last_switch = {"running": False, "result": "", "fin": 0.0}

# Cache court de l'etat, borne cote SERVEUR.
#
# Chaque appel a rpc() ouvre une connexion neuve vers snapserver, qui journalise
# connexion + deconnexion + nettoyage de session : TROIS lignes par sondage. Un
# navigateur laisse ouvert produisait ainsi ~90 lignes/minute en permanence dans
# le journal systemd, ecrites sur la carte SD.
#
# Le cache rend cette charge independante du nombre d'onglets ouverts et de leur
# cadence -- y compris une page ancienne restee en cache navigateur. L'etat d'un
# parc audio ne change pas seul : 3 s de peremption sont sans consequence, et le
# cache est court-circuite pendant une bascule, ou la fraicheur compte.
_cache = {"t": 0.0, "v": None}
_cache_lock = threading.Lock()


def rpc(method, params=None):
    """Un aller-retour JSON-RPC avec snapserver.

    Le protocole est une ligne JSON par message. On lit jusqu'au \n plutôt
    qu'un recv() de taille fixe : Server.GetStatus dépasse largement 4 Ko dès
    qu'il y a plusieurs clients.
    """
    req = {"id": 1, "jsonrpc": "2.0", "method": method}
    if params:
        req["params"] = params
    with socket.create_connection((RPC_HOST, RPC_PORT), timeout=5) as s:
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.split(b"\n")[0])


def noeuds_connus():
    """Noms des nœuds déclarés dans nodes.conf, hors ceux marqués skip.

    C'est le filtre de l'interface. Se fier à l'IP ne suffit pas : snapserver
    garde une entrée par client vu au moins une fois, y compris le témoin local
    du serveur et tout client de test lancé à la main. Ces fantômes restent
    « déconnectés » à vie et feraient basculer le mode en « partiel » pour
    toujours. install.sh passe NODE_NAME en --hostID, donc l'id snapcast d'un
    nœud est exactement son nom dans nodes.conf.
    """
    noms = set()
    try:
        for ligne in (REPO / "nodes.conf").read_text().splitlines():
            ligne = ligne.strip()
            if not ligne or ligne.startswith("#"):
                continue
            champs = ligne.split()
            if len(champs) >= 3 and champs[2] != "skip":
                noms.add(champs[0])
    except OSError:
        pass
    return noms


def etat(frais=False):
    """Photo du parc : clients déclarés, connectés ou non, et mode déduit.

    Le mode se déduit des connexions plutôt que d'interroger les nœuds en SSH :
    un nœud rendu à LMS a coupé son snapclient, donc il apparaît déconnecté.
    C'est instantané et gratuit, là où un `fleet.sh status` coûte 2 s.
    """
    with _cache_lock:
        if (not frais and _cache["v"] is not None
                and time.time() - _cache["t"] < 3.0
                and not _last_switch["running"]):
            return _cache["v"]

    st = rpc("Server.GetStatus")["result"]["server"]
    connus = noeuds_connus()

    clients = []
    for groupe in st["groups"]:
        for c in groupe["clients"]:
            # Seuls les nœuds declares comptent. Ecarte d'office le temoin local
            # du serveur et les entrees fantomes laissees par des tests.
            if connus and c["id"] not in connus:
                continue
            clients.append({
                "id": c["id"],
                "nom": c["config"]["name"] or c["host"]["name"],
                "connecte": c["connected"],
            })
    clients.sort(key=lambda c: c["nom"].lower())

    connectes = sum(1 for c in clients if c["connecte"])
    if not clients:
        mode = "inconnu"
    elif connectes == len(clients):
        mode = "snapcast"
    elif connectes == 0:
        mode = "lms"
    else:
        mode = "partiel"

    flux = st["streams"][0] if st["streams"] else {}
    resultat = {
        "mode": mode,
        "clients": clients,
        "flux": flux.get("id", "?"),
        "flux_etat": flux.get("status", "?"),
        "bascule_en_cours": _last_switch["running"],
        # Le resultat d'une bascule est une information TRANSITOIRE. L'afficher
        # indefiniment la presente comme actuelle : apres l'ajout d'un noeud, la
        # console montrait encore le compte-rendu d'une bascule anterieure, donc
        # un nœud de moins que la realite. On l'oublie au bout de 30 s.
        "bascule_resultat": (_last_switch["result"]
                             if time.time() - _last_switch["fin"] < 30 else ""),
    }
    with _cache_lock:
        _cache["t"], _cache["v"] = time.time(), resultat
    return resultat


def basculer(mode):
    """Lance fleet.sh en tâche de fond et publie son résultat.

    Synchrone, la requête HTTP tiendrait 4 s et la page paraîtrait figée.
    On rend la main tout de suite ; l'interface suit par son sondage.
    """
    def run():
        try:
            p = subprocess.run(
                [str(FLEET), mode],
                cwd=str(REPO), capture_output=True, text=True, timeout=120,
            )
            _last_switch["result"] = (p.stdout + p.stderr).strip() or "(aucune sortie)"
        except subprocess.TimeoutExpired:
            _last_switch["result"] = "délai dépassé (120 s)"
        except Exception as exc:                       # noqa: BLE001
            _last_switch["result"] = f"erreur : {exc}"
        finally:
            _last_switch["fin"] = time.time()
            _last_switch["running"] = False
            _switch_lock.release()

    if not _switch_lock.acquire(blocking=False):
        return False
    _last_switch["running"] = True
    _last_switch["result"] = ""
    threading.Thread(target=run, daemon=True).start()
    return True


class Handler(BaseHTTPRequestHandler):
    def _envoi(self, code, corps, ctype="application/json"):
        data = corps if isinstance(corps, bytes) else corps.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        try:
            if self.path in ("/", "/index.html"):
                self._envoi(200, PAGE, "text/html")
            elif self.path == "/api/etat":
                self._envoi(200, json.dumps(etat()))
            else:
                self._envoi(404, json.dumps({"erreur": "inconnu"}))
        except Exception as exc:                       # noqa: BLE001
            self._envoi(500, json.dumps({"erreur": str(exc)}))

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            corps = json.loads(self.rfile.read(n) or b"{}")

            if self.path == "/api/mode":
                mode = corps.get("mode")
                # Liste blanche stricte : ce paramètre finit en argument de
                # processus. Ne jamais le laisser passer sans validation.
                if mode not in ("snapcast", "lms"):
                    return self._envoi(400, json.dumps({"erreur": "mode invalide"}))
                if not basculer(mode):
                    return self._envoi(409, json.dumps({"erreur": "bascule déjà en cours"}))
                return self._envoi(202, json.dumps({"ok": True}))

            self._envoi(404, json.dumps({"erreur": "inconnu"}))
        except Exception as exc:                       # noqa: BLE001
            self._envoi(500, json.dumps({"erreur": str(exc)}))

    def log_message(self, *a):
        pass                                            # journal systemd déjà verbeux


PAGE = """<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>pcpNetAudio</title>
<style>
:root{
  --fond:#f4f4f5; --carte:#fff; --texte:#18181b; --doux:#71717a;
  --bord:#e4e4e7; --actif:#16a34a; --actif-doux:#dcfce7;
  --lms:#2563eb; --lms-doux:#dbeafe; --curseur:#18181b;
}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){
  --fond:#09090b; --carte:#18181b; --texte:#fafafa; --doux:#a1a1aa;
  --bord:#27272a; --actif:#22c55e; --actif-doux:#14532d;
  --lms:#3b82f6; --lms-doux:#1e3a8a; --curseur:#fafafa;
}}
*{box-sizing:border-box}
body{margin:0;padding:16px;background:var(--fond);color:var(--texte);
  font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;
  max-width:640px;margin-inline:auto;-webkit-font-smoothing:antialiased}
h1{font-size:15px;font-weight:600;letter-spacing:.02em;text-transform:uppercase;
  color:var(--doux);margin:0 0 4px}
.flux{font-size:13px;color:var(--doux);margin-bottom:20px}
.pastille{display:inline-block;width:8px;height:8px;border-radius:50%;
  background:var(--doux);margin-right:6px;vertical-align:1px}
.pastille.on{background:var(--actif)}
.modes{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:8px}
button.mode{appearance:none;border:2px solid var(--bord);background:var(--carte);
  color:var(--texte);border-radius:14px;padding:18px 12px;cursor:pointer;
  font:600 15px/1.3 inherit;text-align:left;transition:.15s}
button.mode:active{transform:scale(.98)}
button.mode span{display:block;font-weight:400;font-size:12px;color:var(--doux);margin-top:3px}
button.mode.actif-snap{border-color:var(--actif);background:var(--actif-doux)}
button.mode.actif-lms{border-color:var(--lms);background:var(--lms-doux)}
button.mode:disabled{opacity:.5;cursor:wait}
.msg{font-size:12px;color:var(--doux);min-height:18px;margin-bottom:18px;
  white-space:pre-wrap;font-family:ui-monospace,monospace}
.zone{background:var(--carte);border:1px solid var(--bord);border-radius:12px;
  padding:13px 16px;margin-bottom:8px;display:flex;align-items:center;
  justify-content:space-between;gap:10px}
.zone.hs{opacity:.5}
.nom{font-weight:600}
.etat{font-size:13px;color:var(--doux)}
.note{font-size:12px;color:var(--doux);margin-top:18px;padding-top:14px;
  border-top:1px solid var(--bord)}
</style>
</head>
<body>
<h1>pcpNetAudio</h1>
<div class="flux" id="flux">…</div>

<div class="modes">
  <button class="mode" id="b-snap" onclick="mode('snapcast')">Snapcast
    <span>tout le parc sur le flux live</span></button>
  <button class="mode" id="b-lms" onclick="mode('lms')">piCorePlayer
    <span>tout le parc rendu à LMS</span></button>
</div>
<div class="msg" id="msg"></div>

<div id="zones"></div>

<div class="note">Pas de réglage de volume : snapclient tourne en
<code>--mixer none</code>, le flux le traverse sans qu'un échantillon soit touché.
Le niveau se règle en analogique, sur les amplis de zone.</div>

<script>
async function charger(){
  let e;
  try { e = await (await fetch('/api/etat')).json(); }
  catch { document.getElementById('msg').textContent = 'serveur injoignable'; return; }

  document.getElementById('flux').innerHTML =
    '<span class="pastille' + (e.flux_etat==='playing'?' on':'') + '"></span>' +
    'flux « ' + e.flux + ' » — ' + e.flux_etat;

  const bs = document.getElementById('b-snap'), bl = document.getElementById('b-lms');
  bs.className = 'mode' + (e.mode==='snapcast' ? ' actif-snap' : '');
  bl.className = 'mode' + (e.mode==='lms' ? ' actif-lms' : '');
  bs.disabled = bl.disabled = e.bascule_en_cours;
  cadence(e.bascule_en_cours);
  document.getElementById('msg').textContent =
    e.bascule_en_cours ? 'bascule en cours…' : (e.bascule_resultat || '');

  const hote = document.getElementById('zones');
  for (const c of e.clients){
    let d = document.getElementById('z-'+c.id);
    if (!d){
      d = document.createElement('div');
      d.id = 'z-'+c.id;
      d.innerHTML = '<span class="nom"></span><span class="etat"></span>';
      hote.appendChild(d);
    }
    d.className = 'zone' + (c.connecte ? '' : ' hs');
    d.querySelector('.nom').textContent = c.nom;
    d.querySelector('.etat').innerHTML =
      c.connecte ? '<span class="pastille on"></span>sur le flux'
                 : '<span class="pastille"></span>rendu à LMS';
  }
}

async function mode(m){
  document.getElementById('b-snap').disabled = true;
  document.getElementById('b-lms').disabled = true;
  document.getElementById('msg').textContent = 'bascule en cours…';
  cadence(true);
  await fetch('/api/mode', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({mode:m})});
  charger();
}

// Sondage ADAPTATIF : lent au repos, rapide pendant une bascule.
//
// Chaque appel ouvre une connexion JSON-RPC neuve vers snapserver, qui
// journalise connexion + deconnexion + nettoyage de session. A 2 s, cela
// faisait 90 lignes/minute dans le journal systemd du serveur en permanence,
// pour une page que personne ne regarde la plupart du temps. Mesure a
// l'appui : 57 connexions en 3 minutes.
//
// 5 s au repos suffit largement -- l'etat d'un parc audio ne change pas seul.
// 1 s pendant une bascule, ou l'utilisateur attend un retour immediat.
let periode = null;
function cadence(rapide){
  const v = rapide ? 1000 : 5000;
  if (periode === v) return;
  periode = v;
  if (window._t) clearInterval(window._t);
  window._t = setInterval(charger, v);
}
charger();
cadence(false);
</script>
</body>
</html>
"""


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"pcpNetAudio - console web sur http://0.0.0.0:{port}")
    srv.serve_forever()
