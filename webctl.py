#!/usr/bin/env python3
"""pcpNetAudio - console web de contrôle du parc.

Deux fonctions, et rien de plus :

  - bascule GLOBALE du parc : 100 % piCorePlayer (LMS) ou 100 % Snapcast.
    Pas de sélecteur par zone : le projet assume un mode ou l'autre, chacun
    avec ses forces, et pas un panachage.
  - volume par snapclient, qui est le réglage réellement utilisé au quotidien.

La bascule délègue à fleet.sh : aucune logique n'est dupliquée ici. Les volumes
passent par le JSON-RPC de snapserver sur le port 1705.

Écoute sur le LAN sans authentification, et expose un point d'entrée qui lance
fleet.sh. C'est acceptable sur un réseau domestique, mais c'est la raison pour
laquelle le paramètre de mode est validé par liste blanche stricte et jamais
interpolé dans un shell.

    python3 webctl.py [port]        # défaut 8080
"""

import json
import socket
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
_last_switch = {"running": False, "result": ""}


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


def etat():
    """Photo du parc : clients, volumes, et mode déduit.

    Le mode se déduit des connexions plutôt que d'interroger les nœuds en SSH :
    un nœud rendu à LMS a coupé son snapclient, donc il apparaît déconnecté.
    C'est instantané et gratuit, là où un `fleet.sh status` coûte 2 s.
    """
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
                "volume": c["config"]["volume"]["percent"],
                "mute": c["config"]["volume"]["muted"],
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
    return {
        "mode": mode,
        "clients": clients,
        "flux": flux.get("id", "?"),
        "flux_etat": flux.get("status", "?"),
        "bascule_en_cours": _last_switch["running"],
        "bascule_resultat": _last_switch["result"],
    }


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

            if self.path == "/api/volume":
                cid = corps.get("id")
                pct = corps.get("volume")
                mute = corps.get("mute")
                if not isinstance(cid, str) or not cid:
                    return self._envoi(400, json.dumps({"erreur": "id manquant"}))
                if not isinstance(pct, int) or not 0 <= pct <= 100:
                    return self._envoi(400, json.dumps({"erreur": "volume hors bornes"}))
                rpc("Client.SetVolume", {
                    "id": cid,
                    "volume": {"percent": pct, "muted": bool(mute)},
                })
                return self._envoi(200, json.dumps({"ok": True}))

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
.zone{background:var(--carte);border:1px solid var(--bord);border-radius:14px;
  padding:14px 16px;margin-bottom:10px}
.zone.hs{opacity:.45}
.tete{display:flex;align-items:baseline;justify-content:space-between;gap:10px}
.nom{font-weight:600}
.pct{font-variant-numeric:tabular-nums;font-size:14px;color:var(--doux);
  font-family:ui-monospace,monospace}
.ligne{display:flex;align-items:center;gap:12px;margin-top:10px}
input[type=range]{flex:1;appearance:none;height:28px;background:transparent;cursor:pointer}
input[type=range]::-webkit-slider-runnable-track{height:6px;border-radius:3px;background:var(--bord)}
input[type=range]::-webkit-slider-thumb{appearance:none;width:24px;height:24px;border-radius:50%;
  background:var(--curseur);margin-top:-9px;border:3px solid var(--carte);
  box-shadow:0 1px 4px #0004}
input[type=range]::-moz-range-track{height:6px;border-radius:3px;background:var(--bord)}
input[type=range]::-moz-range-thumb{width:20px;height:20px;border-radius:50%;
  background:var(--curseur);border:3px solid var(--carte)}
input[type=range]:disabled{opacity:.4}
button.mute{appearance:none;border:1px solid var(--bord);background:transparent;
  color:var(--doux);border-radius:9px;width:42px;height:34px;cursor:pointer;font-size:16px}
button.mute.on{background:var(--texte);color:var(--fond);border-color:var(--texte)}
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

<div class="note">Le volume est appliqué par snapclient, en logiciel.
À 100 % le flux est inchangé, donc bit-perfect.</div>

<script>
let glisse = null;          // id du client en cours de réglage : on ne l'écrase pas
let attente = new Map();    // id -> timer d'anti-rebond

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
  document.getElementById('msg').textContent =
    e.bascule_en_cours ? 'bascule en cours…' : (e.bascule_resultat || '');

  const hote = document.getElementById('zones');
  for (const c of e.clients){
    let d = document.getElementById('z-'+c.id);
    if (!d){
      d = document.createElement('div');
      d.id = 'z-'+c.id;
      d.innerHTML =
        '<div class="tete"><span class="nom"></span><span class="pct"></span></div>' +
        '<div class="ligne">' +
          '<button class="mute">◼</button>' +
          '<input type="range" min="0" max="100" step="1">' +
        '</div>';
      const r = d.querySelector('input'), m = d.querySelector('button');
      r.oninput = () => { glisse = c.id; d.querySelector('.pct').textContent = r.value+' %'; };
      r.onchange = () => { glisse = null; pousser(c.id, +r.value, m.classList.contains('on')); };
      m.onclick = () => { const on = !m.classList.contains('on');
                          m.classList.toggle('on', on); pousser(c.id, +r.value, on); };
      hote.appendChild(d);
    }
    d.className = 'zone' + (c.connecte ? '' : ' hs');
    d.querySelector('.nom').textContent = c.nom + (c.connecte ? '' : '  — hors ligne');
    const r = d.querySelector('input'), m = d.querySelector('button');
    r.disabled = !c.connecte;
    if (glisse !== c.id){
      r.value = c.volume;
      d.querySelector('.pct').textContent = c.volume + ' %';
      m.classList.toggle('on', c.mute);
    }
  }
}

function pousser(id, volume, mute){
  clearTimeout(attente.get(id));
  attente.set(id, setTimeout(() => {
    fetch('/api/volume', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({id, volume, mute})});
  }, 120));                        // anti-rebond : un glissement = une requête
}

async function mode(m){
  document.getElementById('b-snap').disabled = true;
  document.getElementById('b-lms').disabled = true;
  document.getElementById('msg').textContent = 'bascule en cours…';
  await fetch('/api/mode', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({mode:m})});
  charger();
}

charger();
setInterval(charger, 2000);
</script>
</body>
</html>
"""


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"pcpNetAudio - console web sur http://0.0.0.0:{port}")
    srv.serve_forever()
