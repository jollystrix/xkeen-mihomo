(
# Original author: dorian6996 (https://github.com/dorian6996)
# Original repository: https://github.com/dorian6996/Mihomo-HWID-Subscription

CONF_DIR="/opt/etc/mihomo"
CONFIG_PATH="$CONF_DIR/config.yaml"
SUB_FILE="$CONF_DIR/.subscription"
UPDATE_SCRIPT="$CONF_DIR/update-config.sh"
TPROXY_PORT=1181

XKEEN_TARBALL_URL="https://github.com/jameszeroX/XKeen/releases/latest/download/xkeen.tar.gz"
MIHOMO_RELEASE_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
MIHOMO_DOWNLOAD_BASE="https://github.com/MetaCubeX/mihomo/releases/download"
YQ_UPSTREAM_BASE="https://github.com/mikefarah/yq/releases/latest/download"
YQ_WORKAROUND_BASE="https://github.com/jameszeroX/yq/releases/latest/download"


progress_wait() {
  message="$1"
  shift
  printf "  %s" "$message"
  "$@" >/dev/null 2>&1 &
  pid="$!"
  while kill -0 "$pid" 2>/dev/null; do
    printf "."
    sleep 2
  done
  wait "$pid"
  rc="$?"
  if [ "$rc" -eq 0 ]; then echo " ready"; else echo " error"; fi
  return "$rc"
}

download_file_attempts() {
  url="$1"
  output="$2"
  rm -f "$output"
  for prefix in "" "https://gh-proxy.com/" "https://ghfast.top/"; do
    if curl -fsSL --connect-timeout 10 -m 90 "${prefix}${url}" -o "$output"; then
      return 0
    fi
  done
  rm -f "$output"
  return 1
}

download_file() {
  url="$1"; output="$2"; label="$3"
  if progress_wait "Downloading $label" download_file_attempts "$url" "$output"; then
    return 0
  fi
  echo "Failed to download $label."
  return 1
}

xkeen_is_installed() {
  [ -x /opt/sbin/xkeen ] &&
    [ -f /opt/sbin/.xkeen/import.sh ] &&
    [ -x /opt/etc/init.d/S05xkeen ]
}

mihomo_is_installed() {
  [ -x /opt/sbin/mihomo ] &&
    [ -x /opt/sbin/yq ] &&
    /opt/sbin/mihomo -v >/dev/null 2>&1 &&
    /opt/sbin/yq --version >/dev/null 2>&1
}

xkeen_run() {
  if command -v xkeen >/dev/null 2>&1; then
    XKEEN_FOREGROUND=1 xkeen "$@"
  else
    XKEEN_FOREGROUND=1 /opt/sbin/xkeen "$@"
  fi
}

install_xkeen_packages() {
  command -v opkg >/dev/null 2>&1 || return 0
  progress_wait "Updating Entware package list" opkg update || return 1
  for package in curl jq ip-full iptables ipset ca-bundle coreutils-uname coreutils-nohup; do
    if ! opkg list-installed 2>/dev/null | grep -q "^$package "; then
      progress_wait "Installing package $package" opkg install "$package" || return 1
    fi
  done
}

detect_xkeen_architecture() {
  ARCHITECTURE=""
  SOFTFLOAT=""

  if command -v opkg >/dev/null 2>&1; then
    opkg_arch="$(opkg print-architecture 2>/dev/null | awk '!/all/ {print $2; exit}' | cut -d- -f1)"
    case "$opkg_arch" in
      *aarch64*) ARCHITECTURE="arm64-v8a" ;;
      *mipsel*) ARCHITECTURE="mips32le" ;;
      *mips*) ARCHITECTURE="mips32" ;;
    esac
  fi

  if [ -z "$ARCHITECTURE" ]; then
    uname_arch="$(uname -m 2>/dev/null)"
    case "$uname_arch" in
      aarch64|arm64) ARCHITECTURE="arm64-v8a" ;;
      mipsel*|mipsle*) ARCHITECTURE="mips32le" ;;
      mips*) ARCHITECTURE="mips32" ;;
    esac
  fi

  if [ "$ARCHITECTURE" = "mips32le" ]; then
    router_version="$(curl -fsS --connect-timeout 2 -m 5 "localhost:79/rci/show/version" 2>/dev/null || ndmc -c 'show version' 2>/dev/null)"
    case "$router_version" in
      *KN-1212*|*KN-2310*|*KN-2311*|*KN-2910*) SOFTFLOAT="true" ;;
    esac
  fi

  case "$ARCHITECTURE" in
    arm64-v8a|mips32le|mips32) return 0 ;;
  esac

  echo "Failed to determine supported architecture of Entware."
  return 1
}

latest_mihomo_version() {
  for prefix in "" "https://gh-proxy.com/" "https://ghfast.top/"; do
    version="$(
      curl -fsSL --connect-timeout 10 -m 30 "${prefix}${MIHOMO_RELEASE_API}" 2>/dev/null |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1
    )"
    [ -n "$version" ] && echo "$version" && return 0
  done

  return 1
}



download_mihomo_binary() {
  detect_xkeen_architecture || return 1
  
  version="$(latest_mihomo_version)"
  echo $version
  if [ -z "$version" ]; then
    echo "Failed to get the latest version of Mihomo."
    return 1
  fi

  case "$ARCHITECTURE" in
    arm64-v8a)
      mihomo_asset="mihomo-linux-arm64-$version.gz"
      yq_asset="yq_linux_arm64"
      yq_base="$YQ_UPSTREAM_BASE"
      ;;
    mips32le)
      if [ "$SOFTFLOAT" = "true" ]; then
        mihomo_asset="mihomo-linux-mipsle-softfloat-$version.gz"
        yq_base="$YQ_WORKAROUND_BASE"
      else
        mihomo_asset="mihomo-linux-mipsle-hardfloat-$version.gz"
        yq_base="$YQ_UPSTREAM_BASE"
      fi
      yq_asset="yq_linux_mipsle"
      ;;
    mips32)
      mihomo_asset="mihomo-linux-mips-hardfloat-$version.gz"
      yq_asset="yq_linux_mips"
      yq_base="$YQ_UPSTREAM_BASE"
      ;;
  esac

  mkdir -p /opt/sbin /tmp/xkeen-mihomo

  if ! /opt/sbin/yq --version >/dev/null 2>&1; then
    download_file "$yq_base/$yq_asset" "/opt/sbin/yq" "yq" || return 1
    chmod +x /opt/sbin/yq
  fi

  mihomo_gz="/tmp/xkeen-mihomo/mihomo.gz"
  mihomo_tmp="/tmp/xkeen-mihomo/mihomo"

  download_file "$MIHOMO_DOWNLOAD_BASE/$version/$mihomo_asset" "$mihomo_gz" "Mihomo $version" || return 1
  if ! gzip -cd "$mihomo_gz" > "$mihomo_tmp"; then
    rm -f "$mihomo_gz" "$mihomo_tmp"
    echo "Failed to unpack Mihomo."
    return 1
  fi

  mv "$mihomo_tmp" /opt/sbin/mihomo
  chmod +x /opt/sbin/mihomo
  rm -f "$mihomo_gz"

  if ! /opt/sbin/mihomo -v >/dev/null 2>&1; then
    echo "The installed Mihomo is not working."
    return 1
  fi
}

install_xkeen_distribution() {
  mkdir -p /opt/sbin /tmp/xkeen-mihomo
  xkeen_archive="/tmp/xkeen-mihomo/xkeen.tar.gz"
  xkeen_extract_dir="/tmp/xkeen-mihomo/xkeen-dist"

  download_file "$XKEEN_TARBALL_URL" "$xkeen_archive" "XKeen" || return 1
  if ! tar -tzf "$xkeen_archive" >/dev/null 2>&1; then
    rm -f "$xkeen_archive"
    echo "XKeen archive is corrupted or has an invalid format."
    return 1
  fi

  rm -rf "$xkeen_extract_dir"
  mkdir -p "$xkeen_extract_dir"
  if ! tar -xzf "$xkeen_archive" -C "$xkeen_extract_dir"; then
    rm -rf "$xkeen_extract_dir" "$xkeen_archive"
    echo "Failed to unpack XKeen."
    return 1
  fi

  if [ -d "$xkeen_extract_dir/_xkeen" ]; then
    xkeen_scripts_dir="$xkeen_extract_dir/_xkeen"
  elif [ -d "$xkeen_extract_dir/.xkeen" ]; then
    xkeen_scripts_dir="$xkeen_extract_dir/.xkeen"
  else
    rm -rf "$xkeen_extract_dir" "$xkeen_archive"
    echo "Scripts not found in XKeen archive."
    return 1
  fi

  if [ ! -f "$xkeen_extract_dir/xkeen" ]; then
    rm -rf "$xkeen_extract_dir" "$xkeen_archive"
    echo "Startup file not found in XKeen archive."
    return 1
  fi

  mv -f "$xkeen_extract_dir/xkeen" /opt/sbin/xkeen
  rm -rf /opt/sbin/.xkeen /opt/sbin/_xkeen
  mv "$xkeen_scripts_dir" /opt/sbin/.xkeen
  chmod +x /opt/sbin/xkeen
  rm -rf "$xkeen_extract_dir" "$xkeen_archive"
}

register_xkeen_offline() {
  if ! printf '1\n1\n' | XKEEN_FOREGROUND=1 /opt/sbin/xkeen -io; then
    echo "Failed to perform offline installation of XKeen."
    exit 1
  fi
}

ensure_xkeen_mihomo() {
  if xkeen_is_installed; then
    echo "XKeen is already installed."
    if ! mihomo_is_installed; then
      echo "Installing Mihomo"
      download_mihomo_binary || exit 1
      register_xkeen_offline
    fi
    xkeen_run -mihomo >/dev/null 2>&1 || true
    return 0
  fi

  install_xkeen_packages || exit 1
  echo "Installing Mihomo"
  download_mihomo_binary || exit 1
  echo "Installing XKeen"
  install_xkeen_distribution || exit 1
  register_xkeen_offline
  xkeen_run -mihomo >/dev/null 2>&1 || true
}

echo
echo "Mihomo & Xkeen Installer Subscription Edition"
echo

ensure_xkeen_mihomo
mkdir -p "$CONF_DIR"

if [ -f "$CONFIG_PATH" ]; then
  echo "Found file config.yaml."
  echo "It will be completely replaced with the config from the subscription (backup: config.yaml.bak)."
  printf "Continue? [y/N]: "
  read -r ANSWER
  case "$ANSWER" in
    y|Y|д|Д) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
fi

rm -rf /opt/etc/mihomo/*


SUB_URL="${1:-}"
if [ -z "$SUB_URL" ]; then
  printf "Enter subscription link without https: "
  IFS= read -r SUB_URL
fi
[ -z "$SUB_URL" ] && echo "Link is not specified." && exit 0

( umask 077; printf '%s\n' "$SUB_URL" > "$SUB_FILE" )


cat > "$UPDATE_SCRIPT" <<'UPDATEEOF'
#!/bin/sh
export PATH="/opt/sbin:/opt/bin:/sbin:/bin:/usr/sbin:/usr/bin"

KEENETIC_IP=$(ip -4 addr show br0 | grep inet | awk '{print $2}' | cut -d/ -f1)

curl -X POST "http://${KEENETIC_IP}:9090/ui/upgrade"

CONF_DIR="/opt/etc/mihomo"
CONFIG_PATH="$CONF_DIR/config.yaml"
SUB_FILE="$CONF_DIR/.subscription"
TPROXY_PORT=1181
TMP="/tmp/mihomo-sub.$$.yaml"
NEW="/tmp/mihomo-sub.$$.new.yaml"

trap 'rm -f "$TMP" "$NEW"' EXIT
fail() { echo "[$(date '+%F %T')] ERROR: $*" >&2; exit 1; }

INSTALLER_URL="https://cdn.jsdelivr.net/gh/jollystrix/xkeen-mihomo@master/install.sh"
SELF_PATH="$CONF_DIR/update-config.sh"

SELF_TMP="/tmp/mihomo-self.$$.sh"
if curl -fsSL --connect-timeout 10 -m 30 "$INSTALLER_URL" 2>/dev/null \
  | awk '/^cat > "\$UPDATE_SCRIPT" <<.UPDATEEOF.$/ {f=1; next}
         /^UPDATEEOF$/ {if (f) exit}
         f' > "$SELF_TMP" \
  && [ -s "$SELF_TMP" ] && sh -n "$SELF_TMP" 2>/dev/null \
  && ! cmp -s "$SELF_TMP" "$SELF_PATH"; then
  cp "$SELF_PATH" "$SELF_PATH.bak"
  chmod +x "$SELF_TMP" && mv -f "$SELF_TMP" "$SELF_PATH"
  echo "[$(date '+%F %T')] Update script updated (will be used on next run)."
fi
rm -f "$SELF_TMP"

[ -s "$SUB_FILE" ] || fail "Not found file: $SUB_FILE"
SUB_URL="$(head -n 1 "$SUB_FILE")"


NDM_INFO="$(ndmc -c 'show version' 2>/dev/null)"
OS_VER="$(echo "$NDM_INFO" | awk '/title:/ {print $2}')"
MODEL_RAW="$(echo "$NDM_INFO" | awk -F': ' '/model:/ {print $2}')"
MODEL="$(echo "$MODEL_RAW" | tr ' ()' '--' | tr -cd '[:alnum:]._-\n')"

MAC_ADDR="$(cat /sys/class/net/br0/address 2>/dev/null || cat /sys/class/net/eth0/address)"
HWID="$(echo "$MAC_ADDR" | tr -d ':' | tr '[:lower:]' '[:upper:]')"

MIHOMO_VER="$(mihomo -v 2>/dev/null | head -n1 | grep -oE 'v[0-9]+(\.[0-9]+){1,2}')"
[ -z "$MIHOMO_VER" ] && MIHOMO_VER="v1.0.0"
UA="mihomo/$MIHOMO_VER"
export UA HWID OS_VER MODEL

HTTP_CODE="$(curl -sSL --connect-timeout 15 -m 60 -w '%{http_code}' -o "$TMP" \
  -H "x-hwid: $HWID" \
  -H "x-device-os: Keenetic OS" \
  -H "x-ver-os: $OS_VER" \
  -H "x-device-model: $MODEL" \
  -H "User-Agent: $UA" \
  "$SUB_URL")" || fail "Failed to download subscription"

[ "$HTTP_CODE" = "200" ] || fail "Subscription server returned HTTP $HTTP_CODE (check the link / device limit)"
[ -s "$TMP" ] || fail "Subscription returned an empty response"

yq -e 'tag == "!!map"' "$TMP" >/dev/null 2>&1 \
  || fail "Subscription response is not a YAML config (possibly a list of links/base64 for another client)"

yq -e '((.proxies // []) | length) > 0 or ((.["proxy-providers"] // {}) | length) > 0' "$TMP" >/dev/null 2>&1 \
  || fail "Subscription config has no proxies or proxy-providers"

cp "$TMP" "$NEW"


yq -i '.listeners = ((.listeners // []) | map(select(.name != "tproxy" and .type != "tproxy"))) + [{"name":"tproxy","type":"tproxy","port":'"$TPROXY_PORT"'}]' "$NEW"


yq -i '.["mixed-port"] = (.["mixed-port"] // 1080)' "$NEW"
yq -i '.["allow-lan"] = true' "$NEW"
yq -i '.profile["store-selected"] = true' "$NEW"

yq -i '.["external-controller"] = "0.0.0.0:9090"' "$NEW"
yq -i '.["external-ui"] = "ui"' "$NEW"
yq -i '.["external-ui-url"] = "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"' "$NEW"


yq -i 'del(.tun)' "$NEW"
yq -i 'del(.proxies)' "$NEW"



CNT="$(yq '.proxies | length' "$TMP" 2>/dev/null)"
[ "${CNT:-0}" -gt 0 ] || fail "No proxies found in $TMP"

yq -i '
  (load("'"$TMP"'") | [.proxies[].name]) as $names |
  (.proxy-groups[] | select(has("proxies")) | .proxies) |=
    map(select(. as $p | $names | any_c(. == $p) | not))
' "$NEW"


yq -i '
  del(.proxy-groups[] | select(has("proxies") and (.proxies | length) == 0) | .proxies)
' "$NEW"

yq -i '
  .proxy-providers.subscription = {
    "type": "http",
    "url": "'"$SUB_URL"'",
    "interval": 3600,
    "path": "./proxy_providers/sub.yml",
    "header": {
      "User-Agent": ["'"$UA"'"],
      "x-hwid": ["'"$HWID"'"],
      "x-device-os": ["Keenetic OS"],
      "x-ver-os": ["'"$OS_VER"'"],
      "x-device-model": ["'"$MODEL"'"]
    },
    "override": {"udp": true},
    "health-check": {
      "enable": true,
      "url": "http://www.gstatic.com/generate_204",
      "interval": 300,
      "timeout": 5000,
      "lazy": true,
      "expected-status": 204
    }
  }
' "$NEW"

yq -i '.proxy-groups[] |= (.use = ((.use // []) + ["subscription"] | unique))' "$NEW"

if yq -e '((.["proxy-providers"] // {}) | length) > 0' "$NEW" >/dev/null 2>&1; then
  yq -i '(.["proxy-providers"][] | select(.type == "http") | .header) = {"User-Agent":[strenv(UA)],"x-hwid":[strenv(HWID)],"x-device-os":["Keenetic OS"],"x-ver-os":[strenv(OS_VER)],"x-device-model":[strenv(MODEL)]}' "$NEW"
fi


if ! TEST_OUT="$(mihomo -t -d "$CONF_DIR" -f "$NEW" 2>&1)"; then
  echo "$TEST_OUT" >&2
  fail "mihomo -t did not accept the config, config.yaml not changed"
fi

if [ -f "$CONFIG_PATH" ] && cmp -s "$NEW" "$CONFIG_PATH"; then
  echo "[$(date '+%F %T')] Config has not changed."
  exit 0
fi

[ -f "$CONFIG_PATH" ] && cp "$CONFIG_PATH" "$CONFIG_PATH.bak"
cp "$NEW" "$CONFIG_PATH"
echo "[$(date '+%F %T')] Config updated."

if command -v xkeen >/dev/null 2>&1; then
  XKEEN_FOREGROUND=1 xkeen -restart
else
  XKEEN_FOREGROUND=1 /opt/sbin/xkeen -restart
fi


UPDATEEOF

chmod +x "$UPDATE_SCRIPT"

echo
echo "Downloading config from subscription..."
if ! "$UPDATE_SCRIPT"; then
  echo
  echo "Failed to install config. Details above."
  exit 1
fi

echo
echo "Automatically update config from subscription every 3 days at 5:00?"
echo "1) Yes"
echo "2) No"
printf "Choose [1-2]: "
read -r CRON_CHOICE

if [ "$CRON_CHOICE" = "1" ]; then
  mkdir -p /opt/var/log
  CRON_MARKER="# mihomo-config-update"
  CRON_JOB="0 5 */3 * * $UPDATE_SCRIPT >> /opt/var/log/mihomo-update.log 2>&1 $CRON_MARKER"
  ( crontab -l 2>/dev/null | grep -v "$CRON_MARKER"; echo "$CRON_JOB" ) | crontab -
  echo "Schedule set."
fi

echo
echo "Ready. Manual update: $UPDATE_SCRIPT"
)
