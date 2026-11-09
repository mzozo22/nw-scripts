#!/usr/bin/env bash
# Netwatch-managed Zabbix upgrade, Ubuntu APT + local MariaDB, target 8.0 stable.
# Run --check first; --upgrade requires a tested restore and, for prereleases,
# a successful isolated migration of the exact source version/schema.
set -Eeuo pipefail
umask 077

TARGET="8.0"
MODE="${1:---check}"
BACKUP_ROOT="${NETWATCH_BACKUP_ROOT:-/opt/netwatch-backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$BACKUP_ROOT/$STAMP"
REPO_BASE="https://repo.zabbix.com/zabbix/$TARGET/release/ubuntu/pool/main/z/zabbix-release"
REPO_URI="https://repo.zabbix.com/zabbix/$TARGET/stable/ubuntu"
LOGFILE=""
STOPPED=0

say(){ printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
cleanup(){
  status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "UPGRADE ABORTED (exit $status). Do not assume that downgrading packages is a safe rollback." >&2
    if [[ "$STOPPED" -eq 1 ]]; then
      echo "Zabbix server may be stopped. Examine backup/logs before manually restarting." >&2
    fi
    [[ -z "$LOGFILE" ]] || echo "Log: $LOGFILE" >&2
  fi
}
trap cleanup EXIT

[[ "$MODE" == "--check" || "$MODE" == "--upgrade" ]] || die "Usage: sudo bash $0 [--check|--upgrade]"
[[ "$EUID" -eq 0 ]] || die 'Run as root (sudo bash script.sh --check).'
[[ -r /etc/os-release ]] || die 'Unable to identify Ubuntu.'
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die 'Only Ubuntu is supported by this script.'
[[ "$VERSION_ID" =~ ^(22\.04|24\.04|26\.04)$ ]] || die "Unsupported Ubuntu version: $VERSION_ID"
for cmd in dpkg-query dpkg-deb apt-get apt-cache systemctl tar gzip mariadb mariadb-dump awk sed grep find curl mktemp df sort; do need "$cmd"; done

# Exactly a package-managed Zabbix server with a local MariaDB backend.
dpkg-query -W -f='${Status}' zabbix-server-mysql 2>/dev/null | grep -qx 'install ok installed' || die 'zabbix-server-mysql is not installed.'
[[ -f /etc/zabbix/zabbix_server.conf ]] || die 'Missing /etc/zabbix/zabbix_server.conf'
SERVER_VERSION="$(zabbix_server -V | head -1 | awk '{print $NF}')"
[[ "$SERVER_VERSION" =~ ^(7\.4\.|8\.0\.) ]] || die "Only 7.4.x or 8.0.x supported here; found $SERVER_VERSION"
PRERELEASE=0
if [[ "$SERVER_VERSION" =~ (alpha|beta|rc) ]] || dpkg-query -W -f='${Version}' zabbix-server-mysql | grep -Eiq '(alpha|beta|rc|~)'; then PRERELEASE=1; fi
# Use the active database name configured for this Zabbix server, not a hard-coded name.
# NETWATCH_DB_NAME may be provided explicitly but must match the active DBName
# to avoid accidentally backing up a different database than the one in use.
CONFIG_DB_NAME="$(sed -nE 's/^[[:space:]]*DBName[[:space:]]*=[[:space:]]*([^#[:space:]]+).*/\1/p' /etc/zabbix/zabbix_server.conf | tail -1)"
CONFIG_DB_NAME="${CONFIG_DB_NAME:-zabbix}"
DB_NAME="${NETWATCH_DB_NAME:-$CONFIG_DB_NAME}"
[[ "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || die 'DBName contains unsupported characters. Only letters, digits, underscores and hyphens are accepted.'
[[ "$DB_NAME" == "$CONFIG_DB_NAME" ]] || die "NETWATCH_DB_NAME=$DB_NAME differs from server DBName=$CONFIG_DB_NAME. Refusing to back up the wrong database."
DB_HOST="$(sed -nE 's/^[[:space:]]*DBHost[[:space:]]*=[[:space:]]*([^#[:space:]]+).*/\1/p' /etc/zabbix/zabbix_server.conf | tail -1)"
[[ -z "$DB_HOST" || "$DB_HOST" == localhost || "$DB_HOST" == 127.0.0.1 ]] || die "DBHost=$DB_HOST is remote; this script supports local MariaDB only."
if [[ "$DB_HOST" == 127.0.0.1 ]]; then die 'TCP MariaDB detected; configure local socket access or use a reviewed manual procedure.'; fi
# Uses OS root socket auth by default. If DB requires separate credentials, supply
# NETWATCH_DB_DEFAULTS_FILE=/root/secure-mariadb-client.cnf (chmod 600).
DB_ARGS=()
if [[ -n "${NETWATCH_DB_DEFAULTS_FILE:-}" ]]; then
  [[ -f "$NETWATCH_DB_DEFAULTS_FILE" ]] || die 'NETWATCH_DB_DEFAULTS_FILE missing.'
  [[ "$(stat -c '%a' "$NETWATCH_DB_DEFAULTS_FILE")" == 600 ]] || die 'DB client defaults file must have mode 600.'
  DB_ARGS+=("--defaults-extra-file=$NETWATCH_DB_DEFAULTS_FILE")
fi
SQL_VERSION="$(mariadb "${DB_ARGS[@]}" --batch --skip-column-names -e 'SELECT VERSION()' 2>/dev/null)" || die 'Cannot access MariaDB as OS root. Configure NETWATCH_DB_DEFAULTS_FILE.'
DB_SCHEMA="$(mariadb "${DB_ARGS[@]}" --batch --skip-column-names "$DB_NAME" -e 'SELECT mandatory,optional FROM dbversion' 2>/dev/null)" || die 'Cannot read existing Zabbix dbversion.'
# Refuse remote database via other transport config even when DBHost is unset.
DB_LOCATION="$(mariadb "${DB_ARGS[@]}" --batch --skip-column-names -e 'SELECT @@hostname' 2>/dev/null)"
[[ -n "$DB_LOCATION" ]] || die 'Could not identify database host.'

say "OS: Ubuntu $VERSION_ID; installed server: $SERVER_VERSION; MariaDB: $SQL_VERSION; DB: $DB_NAME; schema: $DB_SCHEMA"
if [[ "$PRERELEASE" -eq 1 ]]; then
  say 'PRERELEASE DETECTED: migration from this schema is not guaranteed by the stable package guide.'
fi
say 'Installed Zabbix packages:'
dpkg-query -W -f='${binary:Package}\t${Version}\n' 'zabbix*' 2>/dev/null || true
say 'Existing Zabbix apt source URIs:'
grep -RhE '^URIs:.*repo\.zabbix\.com/zabbix/|^[[:space:]]*deb .*repo\.zabbix\.com/zabbix/' /etc/apt/sources.list.d /etc/apt/sources.list 2>/dev/null || true
say 'Disk space:'; df -h / /opt || true

if [[ "$MODE" == --check ]]; then
  say 'READ-ONLY CHECK COMPLETED. No services stopped or packages changed.'
  echo 'Before --upgrade: externally copy backups, test restore, test migration on an isolated clone.'
  exit 0
fi

[[ "${NETWATCH_RESTORE_TESTED:-}" == YES ]] || die 'Set NETWATCH_RESTORE_TESTED=YES only after a successful backup restore test.'
if [[ "$PRERELEASE" -eq 1 && "${NETWATCH_BETA_MIGRATION_TESTED:-}" != YES ]]; then
  die 'Prerelease requires NETWATCH_BETA_MIGRATION_TESTED=YES after validating the exact DB migration on an isolated clone.'
fi
[[ "${NETWATCH_VM_ROLLBACK_READY:-}" == YES ]] || die 'Set NETWATCH_VM_ROLLBACK_READY=YES only after verifying an application-consistent VM rollback point.'

mkdir -p "$WORK"
LOGFILE="$WORK/upgrade.log"
exec > >(tee -a "$LOGFILE") 2>&1
say "Upgrade workspace: $WORK"
# Record package inventory, metadata and current repository config.
dpkg-query -W -f='${binary:Package}\t${Version}\n' 'zabbix*' > "$WORK/netwatch-packages.tsv" || true
mariadb "${DB_ARGS[@]}" --batch --skip-column-names "$DB_NAME" -e 'SELECT mandatory,optional FROM dbversion' > "$WORK/netwatch-dbversion-before.txt"
mkdir -p "$WORK/apt-before"
cp -a /etc/apt/sources.list.d "$WORK/apt-before/"
[[ ! -f /etc/apt/sources.list ]] || cp -a /etc/apt/sources.list "$WORK/apt-before/"

say 'Stopping Zabbix services before consistent backup.'
for service in zabbix-server zabbix-agent zabbix-agent2 zabbix-proxy; do
  if systemctl is-active --quiet "$service"; then
    systemctl stop "$service"
    echo "$service" >> "$WORK/netwatch-services-stopped.txt"
  fi
done
STOPPED=1

say 'Creating full SQL dump (configuration AND history; no --no-data and no table exclusions).'
# stdout is captured and compressed. pipefail guarantees dump failure aborts.
mariadb-dump "${DB_ARGS[@]}" --single-transaction --quick --routines --triggers --events \
  --databases "$DB_NAME" | gzip -1 > "$WORK/netwatch-database.sql.gz"
gzip -t "$WORK/netwatch-database.sql.gz"
[[ -s "$WORK/netwatch-database.sql.gz" ]] || die 'Database dump empty.'

say 'Archiving Zabbix + web + PHP configuration/files (existing paths only).'
PATHS=(etc/zabbix etc/nginx etc/apache2 etc/php usr/share/zabbix usr/lib/zabbix var/lib/zabbix
       usr/share/zabbix-assets usr/share/zabbix-ui var/log/zabbix)
EXISTING=()
for p in "${PATHS[@]}"; do [[ ! -e "/$p" ]] || EXISTING+=("$p"); done
((${#EXISTING[@]} > 0)) || die 'No filesystem paths found to archive.'
tar -C / -czpf "$WORK/netwatch-files.tar.gz" "${EXISTING[@]}"
gzip -t "$WORK/netwatch-files.tar.gz"
sha256sum "$WORK/netwatch-database.sql.gz" "$WORK/netwatch-files.tar.gz" > "$WORK/netwatch-sha256.txt"
say 'Backups created and checksums recorded. Note: archive checks do not replace a restore test.'

say 'Preparing official 8.0 stable repository.'
DEB="$WORK/zabbix-release_latest+ubuntu${VERSION_ID}_all.deb"
curl --fail --location --retry 2 --silent --show-error \
  "$REPO_BASE/zabbix-release_latest+ubuntu${VERSION_ID}_all.deb" -o "$DEB"
[[ "$(dpkg-deb -f "$DEB" Package)" == zabbix-release ]] || die 'Downloaded repository package is not zabbix-release.'

# Disable all old Zabbix branch apt sources (but not zabbix-tools), preserving originals.
# Uses .disabled extension (APT ignores it). Only own zabbix* source filenames are touched.
mkdir -p "$WORK/disabled-apt-sources"
shopt -s nullglob
for f in /etc/apt/sources.list.d/zabbix*.sources /etc/apt/sources.list.d/zabbix*.list; do
  [[ "$(basename "$f")" == zabbix-tools.* ]] && continue
  cp -a "$f" "$WORK/disabled-apt-sources/"
  mv "$f" "$f.netwatch-disabled"
done
shopt -u nullglob
# Older /etc/apt/sources.list installations require manual review, not blind editing.
if [[ -f /etc/apt/sources.list ]] && grep -Eq 'repo\.zabbix\.com/zabbix/' /etc/apt/sources.list; then
  die 'Zabbix repository found in /etc/apt/sources.list; disable old source manually, then retry with a fresh verified backup.'
fi
# zabbix-release is only a repository config package; use new conffiles for it.
dpkg --force-confnew -i "$DEB"

# APT must not retain enabled unstable or older branch sources.
if grep -RhE '^(URIs:|deb )' /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null \
  | grep -E 'repo\.zabbix\.com/zabbix/' | grep -Ev '/8\.0/stable/ubuntu|/8\.0/release/ubuntu'; then
  die 'Non-8.0 Zabbix repository remains enabled.'
fi
if ! grep -RhF "$REPO_URI" /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null >/dev/null; then
  die '8.0 stable repository not present after repo package install.'
fi
apt-get update

say 'Checking candidate versions for installed Zabbix components.'
PKGS=()
while IFS=$'\t' read -r pkg version; do
  [[ "$pkg" == zabbix-release || "$pkg" == zabbix-release:* ]] && continue
  # zabbix-tools and addons may not share a server release number.
  case "$pkg" in
    zabbix-server-*|zabbix-proxy-*|zabbix-frontend-php|zabbix-nginx-conf|zabbix-apache-conf|zabbix-sql-scripts|zabbix-agent|zabbix-agent2|zabbix-sender|zabbix-get|zabbix-java-gateway)
      candidate="$(apt-cache policy "$pkg" | awk '/Candidate:/ {print $2; exit}')"
      [[ "$candidate" =~ ^([0-9]+:)?8\.0\.[0-9]+ ]] || die "$pkg candidate is not 8.0 stable: $candidate"
      [[ ! "$candidate" =~ (alpha|beta|rc|~) ]] || die "$pkg candidate is prerelease: $candidate"
      PKGS+=("$pkg")
      printf '  %-32s %s -> %s\n' "$pkg" "$version" "$candidate"
      ;;
    *) echo "Skipping optional/non-core package: $pkg";;
  esac
done < <(dpkg-query -W -f='${binary:Package}\t${Version}\n' 'zabbix*' 2>/dev/null || true)
((${#PKGS[@]} > 0)) || die 'No Zabbix packages selected.'

say 'Simulating upgrade. Any package removal aborts.'
apt-get -s install --only-upgrade "${PKGS[@]}" | tee "$WORK/netwatch-apt-simulation.txt"
if grep -qE '^Remv ' "$WORK/netwatch-apt-simulation.txt"; then
  die 'Simulation would remove packages; inspect simulation manually.'
fi

printf '\nThe SQL backup is at %s\n' "$WORK/netwatch-database.sql.gz"
printf 'Repository setup has changed; server is STOPPED.\n'
printf 'Type UPGRADE to install 8.0 packages (anything else aborts): '
read -r confirm
[[ "$confirm" == UPGRADE ]] || die 'Operator did not approve package changes.'

say 'Installing stable 8.0 packages. Keep existing config files; review .dpkg-dist files after upgrade.'
DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::=--force-confold \
  install --only-upgrade "${PKGS[@]}"

# Never silently change the DB schema yourself; Zabbix server handles it.
say 'Starting/restarting web stack and Zabbix components.'
if systemctl list-unit-files | grep -q '^nginx.service'; then nginx -t; systemctl restart nginx; fi
for service in $(systemctl list-unit-files --no-legend | awk '/^php[0-9.]+-fpm\.service/ {print $1}'); do
  systemctl restart "$service"
done
systemctl start zabbix-server
# Zabbix may take minutes to finish automatic database migrations. Do not assume success here.
if [[ -f "$WORK/netwatch-services-stopped.txt" ]]; then
  while IFS= read -r service; do
    [[ "$service" == zabbix-server ]] || systemctl start "$service" || true
  done < "$WORK/netwatch-services-stopped.txt"
fi
STOPPED=0
say 'New binary version:'; zabbix_server -V | head -2
say 'Server status (migration may still be in progress):'; systemctl --no-pager --full status zabbix-server || true
say "Inspect /var/log/zabbix/zabbix_server.log and run UI/inventory/history checks. Backup: $WORK"
say 'IMPORTANT: rollback requires restoring the matching PRE-UPGRADE database AND files/VM snapshot, not merely package downgrade.'
