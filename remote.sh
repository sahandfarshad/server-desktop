# Server Desktop remote script. Runs on the target server as root, fed via
# stdin by the panel with SD_ACTION, SD_USER, SD_PASS, SD_PORT, SD_FIREFOX,
# SD_SUDO set. Installs a light IceWM desktop reachable over RDP (xrdp).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
step() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "root (or passwordless sudo) is required"
UNITS="xrdp xrdp-sesman"
# restart xrdp even when an old session hangs its stop
xrestart() {
  timeout 20 systemctl restart $UNITS && return 0
  echo "xrdp did not stop cleanly; forcing it"
  systemctl kill -s KILL xrdp xrdp-sesman 2>/dev/null; pkill -9 -x xrdp 2>/dev/null; pkill -9 -x xrdp-sesman 2>/dev/null; sleep 1
  systemctl reset-failed xrdp xrdp-sesman 2>/dev/null; systemctl start $UNITS
}
MARK=/etc/server-desktop.user

status() {
  for u in $UNITS; do printf '%-16s %s\n' "$u" "$(systemctl is-active $u 2>/dev/null || true)"; done
  P=$(sed -n 's/^port=\([0-9]*\).*/\1/p' /etc/xrdp/xrdp.ini 2>/dev/null | head -n1)
  [ -n "$P" ] && printf 'RDP port          %s\n' "$P"
  [ -f $MARK ] && printf 'Desktop user      %s\n' "$(cat $MARK)"
  if [ -n "$P" ]; then
    n=$(ss -Htn state established "( sport = :$P )" 2>/dev/null | wc -l)
    printf 'Connected now     %s\n' "$n"
  fi
  command -v firefox >/dev/null && printf 'Firefox           %s\n' "$(firefox --version 2>/dev/null | awk '{print $NF}')"
  free -h | sed -n 2p | awk '{print "RAM               "$3" / "$2}'
  df -h / | awk 'NR==2{print "Disk              "$3" / "$2}'
}

case "$SD_ACTION" in
status) status; exit 0 ;;
restart)
  step "Restarting xrdp"
  if [ -f $MARK ]; then
    U=$(cat $MARK)
    pkill -u "$U" -f 'Xorg|icewm|xrdp-chansrv' 2>/dev/null && echo "closed the open desktop session of $U" || true
  fi
  xrestart; sleep 2; status
  for u in $UNITS; do systemctl is-active --quiet $u || die "$u is not running (journalctl -u $u)"; done
  exit 0 ;;
uninstall)
  step "Removing Server Desktop from this server"
  P=$(sed -n 's/^port=\([0-9]*\).*/\1/p' /etc/xrdp/xrdp.ini 2>/dev/null | head -n1)
  systemctl disable --now $UNITS 2>/dev/null || true
  apt-get purge -yq xrdp xorgxrdp 2>&1 | grep -E '^(Removing|E:)' || true
  if [ -f $MARK ]; then
    U=$(cat $MARK)
    pkill -u "$U" 2>/dev/null || true; sleep 1
    userdel -r "$U" 2>/dev/null && echo "user $U and its home folder removed" || true
    rm -f $MARK /etc/sudoers.d/server-desktop
  fi
  if [ -n "$P" ] && command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then ufw delete allow "$P/tcp" >/dev/null 2>&1 || true; fi
  echo "IceWM and Firefox packages were kept (apt purge icewm firefox to remove them)."
  exit 0 ;;
install) ;;
*) die "unknown action $SD_ACTION" ;;
esac

# ---------------------------------------------------------------- install
echo "$SD_USER" | grep -Eq '^[a-z_][a-z0-9_-]{2,31}$' || die "invalid desktop username: $SD_USER (lowercase letters, digits, - and _)"
case "$SD_USER" in root|daemon|bin|sys|sync|games|man|lp|mail|news|nobody|xrdp|messagebus|sshd|www-data) die "username $SD_USER is reserved; choose another" ;; esac
[ ${#SD_PASS} -ge 8 ] || die "desktop password must be at least 8 characters"
echo "$SD_PORT" | grep -Eq '^[0-9]{2,5}$' && [ "$SD_PORT" -ge 1 ] && [ "$SD_PORT" -le 65535 ] || die "invalid RDP port: $SD_PORT"
. /etc/os-release
case "$ID:$VERSION_ID" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) echo "OS: $PRETTY_NAME" ;;
  *) die "supported: Ubuntu 22.04, Ubuntu 24.04, Debian 12/13 (this is ${PRETTY_NAME:-unknown})" ;;
esac
if [ -f $MARK ] && [ "$(cat $MARK)" != "$SD_USER" ]; then
  echo "NOTE: previous desktop user $(cat $MARK) is kept; new user is $SD_USER"
fi
INUSE=$(ss -Hltnp "( sport = :$SD_PORT )" 2>/dev/null | grep -v xrdp || true)
[ -z "$INUSE" ] || die "port $SD_PORT is already used by another program: $INUSE"

step "Installing packages (IceWM desktop + xrdp)"
if [ "$ID" = ubuntu ] && ! grep -rhqs '^deb .* universe' /etc/apt/sources.list /etc/apt/sources.list.d/ && ! grep -rqs 'universe' /etc/apt/sources.list.d/*.sources; then
  apt-get update -q && apt-get install -yq software-properties-common && add-apt-repository -y universe
fi
apt-get update -q
apt-get install -yq --no-install-recommends ca-certificates curl wget gnupg openssl \
  xrdp xorgxrdp icewm xterm pcmanfm scrot dbus-x11 x11-xserver-utils xdg-utils \
  fonts-dejavu-core fonts-liberation fonts-noto-core ssl-cert 2>&1 | grep -E '^(Setting up|E:)' || true
for c in xrdp xrdp-sesman icewm-session xterm scrot; do command -v $c >/dev/null || die "$c failed to install"; done
for f in fonts-vazirmatn fonts-noto-color-emoji; do apt-get install -yq --no-install-recommends $f >/dev/null 2>&1 || echo "(optional font $f not available)"; done

if [ "${SD_FIREFOX:-0}" = 1 ]; then
  step "Installing Firefox from Mozilla's official repository"
  install -d -m 0755 /etc/apt/keyrings
  wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O /etc/apt/keyrings/packages.mozilla.org.asc
  echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' >/etc/apt/sources.list.d/mozilla.list
  printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' >/etc/apt/preferences.d/mozilla
  if command -v snap >/dev/null && snap list firefox >/dev/null 2>&1; then snap remove firefox || true; fi
  apt-get update -q
  apt-get install -yq --allow-downgrades firefox 2>&1 | grep -E '^(Setting up|E:)' || true
  command -v firefox >/dev/null || die "Firefox failed to install"
  firefox --version 2>/dev/null || true
fi

step "Creating the desktop user $SD_USER"
if ! id "$SD_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$SD_USER"
fi
printf '%s:%s\n' "$SD_USER" "$SD_PASS" | chpasswd
H=$(getent passwd "$SD_USER" | cut -d: -f6)
echo "$SD_USER" >$MARK; chmod 600 $MARK
if [ "${SD_SUDO:-0}" = 1 ]; then
  usermod -aG sudo "$SD_USER"; echo "sudo: enabled for $SD_USER"
else
  gpasswd -d "$SD_USER" sudo >/dev/null 2>&1 || true
fi
echo "icewm-session" >"$H/.xsession"
install -d -m 755 -o "$SD_USER" -g "$SD_USER" "$H/.icewm" "$H/Desktop"
cat >"$H/.icewm/preferences" <<'P'
TaskBarShowWorkspaces=0
TaskBarShowCPUStatus=1
TaskBarShowNetStatus=1
TaskBarShowMEMStatus=1
ShowTaskBar=1
TaskBarAtTop=0
DesktopBackgroundColor="rgb:1E/22/2A"
P
{
  echo 'prog "Terminal" utilities-terminal xterm -fa Monospace -fs 11'
  echo 'prog "Files" system-file-manager pcmanfm'
  command -v firefox >/dev/null && echo 'prog "Firefox" firefox firefox'
} >"$H/.icewm/toolbar"
cp "$H/.icewm/toolbar" "$H/.icewm/menu"
# Screenshots: saved to ~/Pictures (Print = whole screen, Shift+Print or the menu = pick an area)
SHOT='mkdir -p ~/Pictures && scrot'
SHOTF='~/Pictures/screenshot-%Y-%m-%d_%H-%M-%S.png'
echo "prog \"Screenshot\" camera-photo sh -c \"$SHOT -d 1 $SHOTF\"" >>"$H/.icewm/toolbar"
{
  echo "prog \"Screenshot\" camera-photo sh -c \"$SHOT -d 1 $SHOTF\""
  echo "prog \"Screenshot (area)\" camera-photo sh -c \"$SHOT -s $SHOTF\""
  echo 'prog "Pictures" folder pcmanfm Pictures'
} >>"$H/.icewm/menu"
cat >"$H/.icewm/keys" <<K
key "Print" sh -c "$SHOT $SHOTF"
key "Shift+Print" sh -c "$SHOT -s $SHOTF"
key "Ctrl+Alt+s" sh -c "$SHOT -s $SHOTF"
K
install -d -m 755 -o "$SD_USER" -g "$SD_USER" "$H/Pictures"
chown -R "$SD_USER:$SD_USER" "$H/.xsession" "$H/.icewm" "$H/Pictures"
# Default system-wide session too, so any user logs into IceWM.
update-alternatives --set x-session-manager /usr/bin/icewm-session >/dev/null 2>&1 || true

step "Configuring xrdp (port $SD_PORT)"
adduser xrdp ssl-cert >/dev/null 2>&1 || true
# Only the listen port in [Globals]; the session sections keep port=-1 (a fixed
# port there makes the session connect back to xrdp itself = black screen).
sed -i "0,/^port=/s/^port=.*/port=$SD_PORT/" /etc/xrdp/xrdp.ini
sed -i '/^\[Xorg\]/,$ s/^port=.*/port=-1/' /etc/xrdp/xrdp.ini
grep -q "^port=$SD_PORT" /etc/xrdp/xrdp.ini || die "could not set the RDP port in /etc/xrdp/xrdp.ini"
sed -i 's/^max_bpp=.*/max_bpp=24/' /etc/xrdp/xrdp.ini
# Speed: bigger send buffer (xrdp's own advice for laggy links) + compression on.
sed -i 's/^#\?tcp_send_buffer_bytes=.*/tcp_send_buffer_bytes=4194304/' /etc/xrdp/xrdp.ini
grep -q '^tcp_send_buffer_bytes=' /etc/xrdp/xrdp.ini || sed -i '0,/^\[Globals\]/s//[Globals]\ntcp_send_buffer_bytes=4194304/' /etc/xrdp/xrdp.ini
sed -i 's/^bitmap_compression=.*/bitmap_compression=true/; s/^bulk_compression=.*/bulk_compression=true/' /etc/xrdp/xrdp.ini
echo 'net.core.wmem_max = 8388608' >/etc/sysctl.d/60-server-desktop.conf; sysctl -q -p /etc/sysctl.d/60-server-desktop.conf || true
# Only offer the Xorg session on the login screen (Xvnc/vnc-any/neutrinordp are not installed/used).
awk '/^\[/{n=$0; gsub(/[][]/,"",n); skip=(n=="Xvnc"||n=="vnc-any"||n=="neutrinordp-any"||n=="Xvnc-any")} !skip' /etc/xrdp/xrdp.ini >/etc/xrdp/xrdp.ini.sd && mv /etc/xrdp/xrdp.ini.sd /etc/xrdp/xrdp.ini
# Root login over RDP off; one session per user that reconnects on return.
sed -i 's/^AllowRootLogin=.*/AllowRootLogin=false/' /etc/xrdp/sesman.ini
sed -i 's/^Policy=.*/Policy=Default/' /etc/xrdp/sesman.ini
# Stop the polkit "authentication required" popups some systems show in RDP.
if [ -d /etc/polkit-1/localauthority/50-local.d ]; then
cat >/etc/polkit-1/localauthority/50-local.d/45-server-desktop.pkla <<'K'
[Allow colord for all users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
K
fi
systemctl enable $UNITS >/dev/null 2>&1
xrestart
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then ufw allow "$SD_PORT/tcp" >/dev/null; echo "ufw: $SD_PORT opened"; fi

step "Checking"
sleep 2
status
for u in $UNITS; do systemctl is-active --quiet $u || { journalctl -u $u -n 15 --no-pager; die "$u is not running"; }; done
ss -Hltn "( sport = :$SD_PORT )" | grep -q . || die "xrdp is not listening on port $SD_PORT"
MYIP=$(curl -4 -fsS --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')
echo "Connect with Remote Desktop: ${MYIP:-this server}:$SD_PORT   user: $SD_USER"
