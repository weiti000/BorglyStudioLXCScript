# Borgly Studio – Proxmox-LXC-Skript

Legt auf Proxmox VE einen Test-LXC für [BorglyStudioServer](https://github.com/weiti000/BorglyStudioServer) an,
im Stil der Proxmox Community Scripts: Debian, Docker, Deploy-Key, Klonen und Start per Docker Compose.

© Weiti Software

## Anlegen

Auf dem Proxmox-Host als root:

```bash
bash borgly-studio-lxc.sh
```

Ist dieses Repo öffentlich, geht es auch ohne Download:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/weiti000/BorglyStudioLXCScript/main/borgly-studio-lxc.sh)"
```

Ablauf: Standard oder Erweitert wählen → Zusammenfassung bestätigen → Deploy-Key wird angezeigt →
bei **BorglyStudioServer** unter Settings → Deploy keys hinterlegen (Schreibzugriff aus) → klonen und starten.

Standard: nächste freie ID, Debian 13 (Rückfall 12), 2 Kerne, 4 GB RAM, 20 GB, vmbr0/DHCP,
unprivilegiert, `nesting=1`, `keyctl=1`, Autostart, Zeitzone Europe/Berlin.

## Update

| Wo | Befehl |
|---|---|
| im LXC | `update` |
| auf dem Host | `bash borgly-studio-lxc.sh update <CTID>` (ohne ID: erster LXC namens `borgly-studio*`) |

Das Update aktualisiert Debian und Docker, sichert die Datenbank (die letzten 7 Backups bleiben),
holt den neuesten Stand von BorglyStudioServer und baut die Container neu.

## Werkzeug im LXC

```
borgly update [--system-only]   System, Docker und Studio aktualisieren
borgly deploy                   Repo holen/aktualisieren und starten
borgly status                   Zustand anzeigen
borgly logs [dienst]            Protokolle verfolgen
borgly backup                   Datenbank sichern (/var/backups/borgly-studio)
borgly key                      Deploy-Key anzeigen
```

Konfiguration: `/etc/borgly-studio/borgly.conf` · Zugangsdaten: `/etc/borgly-studio/studio.env` (nur im LXC).

## Pflege

Das Werkzeug `borgly` ist im Skript eingebettet **und** liegt als `deploy/borgly` in BorglyStudioServer.
Beim Update ersetzt die Fassung aus BorglyStudioServer die installierte. Änderungen daher in beiden Repos gleich einpflegen.

Nach dem Anlegen in Nginx Proxy Manager einen Proxy Host `studio-test.weiti.online` → `http://<LXC-IP>:3000`
eintragen (Let's Encrypt per DNS-Challenge), nur im Heimnetz, nicht über den Cloudflare Tunnel.
