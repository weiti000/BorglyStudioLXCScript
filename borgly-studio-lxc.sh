#!/usr/bin/env bash
# =============================================================================
#  Borgly Studio – Test-LXC für Proxmox VE (im Stil der Community Scripts)
#
#  Anlegen (Proxmox-Shell als root):   bash borgly-studio-lxc.sh
#  Repo: https://github.com/weiti000/BorglyStudioLXCScript
#  Update vom Host aus:                bash borgly-studio-lxc.sh update <CTID>
#  Update im LXC:                      update        (oder: borgly update)
#
#  Legt einen unprivilegierten Debian-LXC mit Docker an, erzeugt einen
#  GitHub-Deploy-Key, klont das Repo und startet es per Docker Compose.
#  © Weiti Software
# =============================================================================
set -Eeuo pipefail

APP="Borgly Studio (Test)"
VERSION="1.0.0"

# --- Ausgabe -----------------------------------------------------------------
msg()  { echo -e "\e[1;36m▶\e[0m $*"; }
ok()   { echo -e "\e[1;32m✔\e[0m $*"; }
warn() { echo -e "\e[1;33m!\e[0m $*"; }
die()  { echo -e "\e[1;31m✖\e[0m $*" >&2; exit 1; }
trap 'echo -e "\e[1;31m✖ Abbruch in Zeile $LINENO: $BASH_COMMAND\e[0m" >&2' ERR

# --- Im LXC gestartet? Dann Update ---------------------------------------------
if ! command -v pct >/dev/null 2>&1; then
  [ -x /usr/local/bin/borgly ] && exec /usr/local/bin/borgly update "$@"
  die "Dieses Skript auf dem Proxmox-Host ausführen."
fi
[ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen."

# --- Update vom Host aus ---------------------------------------------------------
if [ "${1:-}" = "update" ]; then
  CTID="${2:-}"
  if [ -z "$CTID" ]; then
    CTID=$(pct list | awk 'NR>1 && $NF ~ /^borgly-studio/ {print $1; exit}')
    [ -n "$CTID" ] || die "Kein Borgly-LXC gefunden. Nutzung: $0 update <CTID>"
  fi
  pct status "$CTID" | grep -q running || { msg "Starte LXC $CTID"; pct start "$CTID"; sleep 5; }
  msg "Update in LXC $CTID"
  pct exec "$CTID" -- /usr/local/bin/borgly update
  exit 0
fi

command -v whiptail >/dev/null || die "whiptail fehlt (apt install whiptail)."

# --- Standardwerte -----------------------------------------------------------------
CTID=$(pvesh get /cluster/nextid)
HN="borgly-studio-test"
CORES=2
RAM=4096
SWAP=512
DISK=20
BRIDGE="vmbr0"
NET="dhcp"
GW=""
VLAN=""
PW=""
PORT=3000
PUBURL="https://studio-test.weiti.online"
REPO="git@github.com:weiti000/BorglyStudioServer.git"
BRANCH="main"
STORAGE=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}')
TSTORE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')
[ -n "$STORAGE" ] || die "Kein Speicher für Container (rootdir) gefunden."
[ -n "$TSTORE" ]  || die "Kein Speicher für Vorlagen (vztmpl) gefunden."

ask() { whiptail --title "$APP" --inputbox "$1" 10 72 "$2" 3>&1 1>&2 2>&3 || exit 1; }

whiptail --title "$APP" --yesno "Borgly Studio Test-LXC anlegen.\n\nStandard-Einstellungen verwenden?\n\nID $CTID · $HN · $CORES Kerne · $RAM MB · ${DISK} GB · $BRIDGE/DHCP" \
  14 72 --yes-button "Standard" --no-button "Erweitert" && ADV=0 || ADV=1

if [ "$ADV" -eq 1 ]; then
  CTID=$(ask "Container-ID" "$CTID")
  HN=$(ask "Hostname" "$HN")
  CORES=$(ask "CPU-Kerne" "$CORES")
  RAM=$(ask "Arbeitsspeicher in MB" "$RAM")
  DISK=$(ask "Festplatte in GB" "$DISK")
  STORAGE=$(ask "Speicher für den Container ($(pvesm status -content rootdir | awk 'NR>1{printf "%s ",$1}'))" "$STORAGE")
  BRIDGE=$(ask "Netzwerk-Bridge" "$BRIDGE")
  NET=$(ask "IP-Adresse mit Präfix (z. B. 192.168.178.120/24) oder dhcp" "$NET")
  [ "$NET" != "dhcp" ] && GW=$(ask "Gateway" "192.168.178.1")
  VLAN=$(ask "VLAN-Tag (leer = keins)" "$VLAN")
  PW=$(ask "Root-Passwort (leer = keins, Zugang über pct enter)" "")
  PORT=$(ask "Port der Studio-API im LXC" "$PORT")
  PUBURL=$(ask "Adresse über Nginx Proxy Manager" "$PUBURL")
  REPO=$(ask "GitHub-Repo (SSH)" "$REPO")
  BRANCH=$(ask "Branch" "$BRANCH")
fi

pct status "$CTID" >/dev/null 2>&1 && die "Container-ID $CTID ist bereits vergeben."

whiptail --title "$APP" --yesno "Zusammenfassung\n
ID / Hostname:   $CTID / $HN
Ressourcen:      $CORES Kerne, $RAM MB RAM, ${DISK} GB auf $STORAGE
Netz:            $BRIDGE, $NET ${GW:+(GW $GW)} ${VLAN:+VLAN $VLAN}
Repo:            $REPO ($BRANCH)
Adresse:         $PUBURL → Port $PORT\n
Jetzt anlegen?" 18 76 || exit 1

# --- Vorlage ------------------------------------------------------------------------
msg "Prüfe Debian-Vorlage"
pveam update >/dev/null 2>&1 || warn "Vorlagenliste konnte nicht aktualisiert werden."
TEMPLATE=$(pveam available --section system | awk '/debian-13-standard/ {print $2}' | sort -V | tail -1)
[ -n "$TEMPLATE" ] || TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -1)
[ -n "$TEMPLATE" ] || die "Keine Debian-Vorlage gefunden."
if ! pveam list "$TSTORE" | grep -q "$TEMPLATE"; then
  msg "Lade $TEMPLATE"
  pveam download "$TSTORE" "$TEMPLATE" >/dev/null
fi
ok "Vorlage: $TEMPLATE"

# --- Container anlegen ----------------------------------------------------------------
NET0="name=eth0,bridge=$BRIDGE,ip=$NET"
[ -n "$GW" ]   && NET0+=",gw=$GW"
[ -n "$VLAN" ] && NET0+=",tag=$VLAN"

msg "Lege LXC $CTID an"
# shellcheck disable=SC2054  # Kommas gehören zu den Optionswerten
CREATE=(pct create "$CTID" "$TSTORE:vztmpl/$TEMPLATE"
  --hostname "$HN" --cores "$CORES" --memory "$RAM" --swap "$SWAP"
  --rootfs "$STORAGE:$DISK" --net0 "$NET0"
  --features nesting=1,keyctl=1 --unprivileged 1 --onboot 1
  --ostype debian --tags borgly --timezone Europe/Berlin
  --description "## Borgly Studio – Testumgebung
Nur Testdaten. Update im LXC: \`update\`
Adresse: $PUBURL")
[ -n "$PW" ] && CREATE+=(--password "$PW")
"${CREATE[@]}" >/dev/null
pct start "$CTID"
ok "LXC $CTID gestartet"

msg "Warte auf Netzwerk"
for _ in $(seq 1 30); do
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 2
done
pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 || die "Keine Internetverbindung im LXC."
ok "Netzwerk bereit"

# --- Dateien für den LXC --------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/borgly.conf" <<CONF
# Borgly Studio – Konfiguration der Testumgebung
REPO_URL="$REPO"
BRANCH="$BRANCH"
APP_DIR="/opt/borgly-studio"
ENV_FILE="/etc/borgly-studio/studio.env"
DB_SERVICE="db"
BACKUP_DIR="/var/backups/borgly-studio"
STUDIO_PORT="$PORT"
PUBLIC_URL="$PUBURL"
CONF

# ---------- Installationsskript (läuft einmalig im LXC) ----------
cat > "$TMP/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
. /etc/borgly-studio/borgly.conf

echo "▶ System aktualisieren"
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confold dist-upgrade
apt-get -y -qq install curl ca-certificates git openssh-client openssl gnupg sudo >/dev/null

echo "▶ Docker installieren"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
systemctl enable --now docker >/dev/null
docker compose version >/dev/null

echo "▶ Deploy-Key für GitHub"
install -d -m 700 /root/.ssh
[ -f /root/.ssh/borgly_deploy ] || ssh-keygen -q -t ed25519 -N "" -C "borgly-studio@$(hostname)" -f /root/.ssh/borgly_deploy
cat > /root/.ssh/config <<'CFG'
Host github.com
  HostName github.com
  User git
  IdentityFile /root/.ssh/borgly_deploy
  IdentitiesOnly yes
CFG
chmod 600 /root/.ssh/config
ssh-keyscan -t ed25519 github.com 2>/dev/null >> /root/.ssh/known_hosts
sort -u -o /root/.ssh/known_hosts /root/.ssh/known_hosts

echo "▶ Zugangsdaten (nur im LXC, nie im Repo)"
if [ ! -f "$ENV_FILE" ]; then
  umask 077
  cat > "$ENV_FILE" <<ENV
# Borgly Studio – Testumgebung. Nicht ins Repo übernehmen!
NODE_ENV=development
STUDIO_PORT=$STUDIO_PORT
PUBLIC_URL=$PUBLIC_URL
POSTGRES_USER=borgly
POSTGRES_DB=borgly
POSTGRES_PASSWORD=$(openssl rand -hex 24)
SESSION_SECRET=$(openssl rand -hex 32)
ENV
fi

install -d -m 755 "$BACKUP_DIR"
printf '#!/usr/bin/env bash\nexec /usr/local/bin/borgly update "$@"\n' > /usr/local/bin/update
chmod 755 /usr/local/bin/update

cat > /etc/motd <<'MOTD'

  Borgly Studio – Testumgebung (nur Testdaten)

  update          System, Docker und Studio aktualisieren
  borgly status   Zustand anzeigen      borgly logs    Protokolle
  borgly deploy   Repo holen + starten  borgly backup  Datenbank sichern
  borgly key      Deploy-Key anzeigen

MOTD
rm -f /root/borgly-install.sh
echo "✔ Installation abgeschlossen"
INSTALL

# ---------- Werkzeug "borgly" (bleibt im LXC, Update-Funktion) ----------
cat > "$TMP/borgly" <<'BORGLY_TOOL'
#!/usr/bin/env bash
# borgly – Verwaltung der Borgly-Studio-Testumgebung
set -Eeuo pipefail
CONF=/etc/borgly-studio/borgly.conf
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
: "${REPO_URL:=git@github.com:weiti000/BorglyStudioServer.git}"
: "${BRANCH:=main}"
: "${APP_DIR:=/opt/borgly-studio}"
: "${ENV_FILE:=/etc/borgly-studio/studio.env}"
: "${DB_SERVICE:=db}"
: "${BACKUP_DIR:=/var/backups/borgly-studio}"
KEY=/root/.ssh/borgly_deploy

msg()  { echo -e "\e[1;36m▶\e[0m $*"; }
ok()   { echo -e "\e[1;32m✔\e[0m $*"; }
warn() { echo -e "\e[1;33m!\e[0m $*"; }
die()  { echo -e "\e[1;31m✖\e[0m $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen."

compose_file() {
  local f
  for f in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
    [ -f "$APP_DIR/$f" ] && { echo "$APP_DIR/$f"; return 0; }
  done
  return 1
}
dc() {
  local f; f=$(compose_file) || die "Kein compose.yml in $APP_DIR."
  docker compose -f "$f" --project-directory "$APP_DIR" --env-file "$ENV_FILE" -p borgly-studio "$@"
}
github_ok() { ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com 2>&1 | grep -q "successfully authenticated"; }

cmd_key() {
  echo
  echo "Deploy-Key – bei GitHub hinterlegen unter:"
  echo "Repo → Settings → Deploy keys → Add deploy key (Schreibzugriff NICHT aktivieren)"
  echo
  cat "$KEY.pub"
  echo
}

repo_sync() {
  if [ ! -d "$APP_DIR/.git" ]; then
    github_ok || { warn "Noch kein Zugriff auf GitHub."; cmd_key; return 1; }
    msg "Klone $REPO_URL ($BRANCH)"
    git clone -q --branch "$BRANCH" "$REPO_URL" "$APP_DIR" \
      || { warn "Klonen fehlgeschlagen – ist das Repo noch leer oder fehlt der Branch $BRANCH?"; return 1; }
  else
    msg "Hole neuesten Stand ($BRANCH)"
    git -C "$APP_DIR" fetch -q --prune origin
    git -C "$APP_DIR" checkout -q "$BRANCH"
    git -C "$APP_DIR" merge -q --ff-only "origin/$BRANCH" \
      || { warn "Lokale Änderungen im LXC verhindern das Update (git -C $APP_DIR status)."; return 1; }
  fi
  ok "Stand: $(git -C "$APP_DIR" log -1 --format='%h %s (%cr)')"
}

tool_selfupdate() {
  local src="$APP_DIR/deploy/borgly"
  if [ -f "$src" ] && ! cmp -s "$src" /usr/local/bin/borgly; then
    install -m 0755 "$src" /usr/local/bin/borgly
    ok "Werkzeug borgly aus dem Repo aktualisiert (gilt ab dem nächsten Aufruf)"
  fi
}

cmd_deploy() {
  repo_sync || return 1
  tool_selfupdate
  if compose_file >/dev/null; then
    msg "Baue und starte Container"
    dc up -d --build --remove-orphans
    docker image prune -f >/dev/null
    ok "Studio läuft"
    dc ps
  else
    warn "Noch kein compose.yml im Repo – nichts zu starten."
  fi
}

cmd_backup() {
  compose_file >/dev/null 2>&1 || { warn "Kein compose.yml – kein Backup."; return 1; }
  dc ps --status running --services 2>/dev/null | grep -qx "$DB_SERVICE" \
    || { warn "Datenbank-Dienst '$DB_SERVICE' läuft nicht – kein Backup."; return 1; }
  mkdir -p "$BACKUP_DIR"
  local f; f="$BACKUP_DIR/borgly-$(date +%Y%m%d-%H%M%S).sql.gz"
  msg "Datenbank-Backup → $f"
  # shellcheck disable=SC2016
  if ! dc exec -T "$DB_SERVICE" sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip > "$f"; then
    rm -f "$f"; warn "Backup fehlgeschlagen."; return 1
  fi
  ls -1t "$BACKUP_DIR"/borgly-*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
  ok "Backup fertig (die letzten 7 bleiben erhalten)"
}

cmd_update() {
  msg "System-Updates (Debian und Docker)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y -qq -o Dpkg::Options::=--force-confold dist-upgrade
  apt-get -y -qq autoremove --purge >/dev/null
  ok "System aktuell"
  [ "${1:-}" = "--system-only" ] && return 0
  if [ -d "$APP_DIR/.git" ] && compose_file >/dev/null 2>&1; then
    cmd_backup || warn "Ohne Backup weiter."
    msg "Basis-Images aktualisieren"
    dc pull -q --ignore-buildable 2>/dev/null || true
  fi
  cmd_deploy || warn "Studio nicht aktualisiert (siehe oben)."
  [ -f /var/run/reboot-required ] && warn "Neustart des LXC empfohlen (auf dem Host: pct reboot <ID>)."
  return 0
}

cmd_status() {
  echo "Host:     $(hostname) · $(hostname -I | awk '{print $1}')"
  echo "Docker:   $(systemctl is-active docker) · $(docker --version | cut -d, -f1)"
  echo "Adresse:  ${PUBLIC_URL:-–} → Port ${STUDIO_PORT:-–}"
  if [ -d "$APP_DIR/.git" ]; then
    echo "Repo:     $(git -C "$APP_DIR" log -1 --format='%h %s (%cr)')"
    compose_file >/dev/null && dc ps
  else
    echo "Repo:     noch nicht geklont (borgly deploy)"
  fi
  github_ok && echo "GitHub:   Zugriff ok" || echo "GitHub:   kein Zugriff (borgly key)"
}

cmd_help() {
  cat <<HELP
borgly – Borgly Studio Testumgebung

  borgly update [--system-only]  System, Docker und Studio aktualisieren (Kurzform: update)
  borgly deploy                  Repo holen/aktualisieren und Container starten
  borgly status                  Zustand anzeigen
  borgly logs [dienst]           Protokolle verfolgen
  borgly backup                  Datenbank sichern ($BACKUP_DIR)
  borgly key                     Deploy-Key für GitHub anzeigen
HELP
}

case "${1:-help}" in
  update) shift; cmd_update "$@" ;;
  deploy) cmd_deploy ;;
  status) cmd_status ;;
  logs)   shift; dc logs -f --tail=100 "$@" ;;
  backup) cmd_backup ;;
  key)    cmd_key ;;
  *)      cmd_help ;;
esac
BORGLY_TOOL

# --- Installation im LXC -------------------------------------------------------------
pct exec "$CTID" -- mkdir -p /etc/borgly-studio
pct push "$CTID" "$TMP/borgly.conf" /etc/borgly-studio/borgly.conf --perms 0644
pct push "$CTID" "$TMP/borgly"      /usr/local/bin/borgly          --perms 0755
pct push "$CTID" "$TMP/install.sh"  /root/borgly-install.sh        --perms 0755
pct exec "$CTID" -- bash /root/borgly-install.sh

IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
PUBKEY=$(pct exec "$CTID" -- cat /root/.ssh/borgly_deploy.pub)

# --- Deploy-Key und erstes Klonen --------------------------------------------------------
echo
echo "──────────────── Deploy-Key ────────────────"
echo "$PUBKEY"
echo "─────────────────────────────────────────────"
echo "GitHub → Repo → Settings → Deploy keys → Add deploy key"
echo "(Titel z. B. borgly-studio-test, Schreibzugriff NICHT aktivieren)"
echo
if whiptail --title "$APP" --yesno "Deploy-Key ist oben in der Konsole ausgegeben.\n\nIst er bei GitHub hinterlegt und das Repo schon angelegt?\n\nJa = jetzt klonen und starten\nNein = später im LXC: borgly deploy" 14 72; then
  pct exec "$CTID" -- /usr/local/bin/borgly deploy || warn "Noch nicht geklont – später im LXC: borgly deploy"
fi

# --- Abschluss ----------------------------------------------------------------------------
echo
ok "$APP v$VERSION fertig – LXC $CTID ($HN), IP $IP"
cat <<DONE

Nächste Schritte
  1. Nginx Proxy Manager: Proxy Host ${PUBURL#https://} → http://$IP:$PORT
     SSL: Let's Encrypt per DNS-Challenge, "Force SSL" an
  2. AdGuard: DNS-Umschreibung ${PUBURL#https://} → IP des NPM (nur Heimnetz)
  3. Nicht über den Cloudflare Tunnel freigeben

Bedienung
  LXC öffnen:        pct enter $CTID
  Update im LXC:     update
  Update vom Host:   bash $0 update $CTID
DONE
