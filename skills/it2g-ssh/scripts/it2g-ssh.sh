#!/usr/bin/env bash
# SSH-доступ к хостам IT2G: логин/пароль берутся из IPAM, порт 22,
# host keys не проверяются (accept-new), sudo без пароля.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LOOKUP="$SCRIPT_DIR/ipam-lookup.py"

SSH_PORT=22
KNOWN_HOSTS=${IT2G_KNOWN_HOSTS:-$HOME/.ssh/it2g_known_hosts}
CONNECT_TIMEOUT=${IT2G_CONNECT_TIMEOUT:-10}

usage() {
  cat <<'EOF'
Использование: it2g-ssh.sh <host> [опции] [-- команда...]

Действия:
  (без действия)                 интерактивная сессия
  -c, --command 'CMD'            выполнить команду (через sudo, если не root)
  -f, --script FILE              залить FILE на хост и выполнить через bash -s
                                 (через sudo, если не root); остальные аргументы
                                 после -- передаются скрипту
Опции:
  -u, --user sadmin|root         только этот пользователь, без fallback
      --no-sudo                  не оборачивать команду в sudo
      --refresh                  не использовать кэш IPAM
      --creds                    показать учётные данные из IPAM и выйти
  -v, --verbose                  подробный вывод ssh

Порядок входа: sadmin (пароль из поля "Пароль") -> root (поле "Root_Password").
Требуется sshpass; креды IPAM берутся из ~/.config/it2g/domain.creds.
EOF
}

die() { printf 'it2g-ssh: %s\n' "$*" >&2; exit 1; }

host=""
user_override=""
remote_command=""
script=""
use_sudo=1
refresh=""
show_creds=0
verbose=0
rest_args=()
script_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -c|--command) remote_command=${2?нужен аргумент}; shift 2 ;;
    -f|--script) script=${2?нужен аргумент}; shift 2 ;;
    -u|--user) user_override=${2?нужен аргумент}; shift 2 ;;
    --no-sudo) use_sudo=0; shift ;;
    --refresh) refresh=--refresh; shift ;;
    --creds) show_creds=1; shift ;;
    -v|--verbose) verbose=1; shift ;;
    --) shift; rest_args=("$@"); break ;;
    -*) die "неизвестная опция: $1" ;;
    *)
      if [ -z "$host" ]; then host=$1; else rest_args+=("$1"); fi
      shift ;;
  esac
done

[ -n "$host" ] || { usage; exit 1; }
if [ ${#rest_args[@]} -gt 0 ]; then
  if [ -n "$script" ]; then
    script_args=("${rest_args[@]}")
  elif [ -n "$remote_command" ]; then
    remote_command="$remote_command $(printf '%q ' "${rest_args[@]}")"
  else
    remote_command=$(printf '%q ' "${rest_args[@]}")
  fi
fi
[ -n "$script" ] && [ ! -r "$script" ] && die "не читается файл скрипта: $script"
command -v sshpass >/dev/null || die "не найден sshpass"

creds_json=$("$LOOKUP" "$host" $refresh)
lookup_rc=$?
if [ "$lookup_rc" -ne 0 ]; then
  [ "$lookup_rc" -eq 2 ] && die "хост $host не найден в IPAM"
  die "не удалось получить креды из IPAM для $host"
fi
json_get() { printf '%s' "$creds_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$1"; }

if [ "$show_creds" = 1 ]; then
  printf '%s\n' "$creds_json" | python3 -m json.tool
  exit 0
fi

hostname_ipam=$(json_get hostname)
sadmin_pass=$(json_get password)
root_pass=$(json_get root_password)

# Что пробуем: сначала sadmin, затем root.
candidates=()
if [ -n "$user_override" ]; then
  case "$user_override" in
    sadmin) candidates=("sadmin:$sadmin_pass") ;;
    root) candidates=("root:$root_pass") ;;
    *) die "поддерживаются только sadmin и root" ;;
  esac
else
  [ -n "$sadmin_pass" ] && candidates+=("sadmin:$sadmin_pass")
  [ -n "$root_pass" ] && candidates+=("root:$root_pass")
fi
[ ${#candidates[@]} -gt 0 ] || die "в IPAM для $host не заполнены поля Пароль/Root_Password"

mkdir -p "$(dirname -- "$KNOWN_HOSTS")"
[ -f "$KNOWN_HOSTS" ] || : > "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS" 2>/dev/null

ssh_opts=(
  -p "$SSH_PORT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o PreferredAuthentications=password,keyboard-interactive
  -o PubkeyAuthentication=no
  -o NumberOfPasswordPrompts=1
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=4
)
[ "$verbose" = 1 ] && ssh_opts+=(-v)

login_user=""
login_pass=""
login_is_root=0

probe_login() {
  local user=$1 pass=$2
  SSHPASS="$pass" sshpass -e ssh "${ssh_opts[@]}" "$user@$host" true 2>/dev/null
}

idx=0
for candidate in "${candidates[@]}"; do
  idx=$((idx + 1))
  user=${candidate%%:*}
  pass=${candidate#*:}
  [ -n "$pass" ] || continue
  if probe_login "$user" "$pass"; then
    login_user=$user; login_pass=$pass
    [ "$user" = root ] && login_is_root=1
    break
  fi
  if [ "$idx" -lt ${#candidates[@]} ]; then
    printf 'it2g-ssh: вход %s@%s не удался, пробую следующего\n' "$user" "$host" >&2
  fi
done

[ -n "$login_user" ] || die "не удалось войти на $host ни под одним пользователем из IPAM"

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

remote_ssh() { # $1 = команда для ssh; stdin пробрасывается
  local remote=$1
  if [ "$login_is_root" = 1 ] || [ "$use_sudo" = 0 ]; then
    SSHPASS="$login_pass" sshpass -e ssh "${ssh_opts[@]}" "$login_user@$host" "$remote"
  else
    SSHPASS="$login_pass" sshpass -e ssh "${ssh_opts[@]}" "$login_user@$host" \
      "sudo -n bash -c $(shell_quote "$remote")"
  fi
}

[ -n "$hostname_ipam" ] && printf 'it2g-ssh: %s (%s) как %s\n' "$host" "$hostname_ipam" "$login_user" >&2 \
  || printf 'it2g-ssh: %s как %s\n' "$host" "$login_user" >&2

if [ -n "$script" ]; then
  args=""
  [ ${#script_args[@]} -gt 0 ] && args=" $(printf '%q ' "${script_args[@]}")"
  if [ "$login_is_root" = 1 ] || [ "$use_sudo" = 0 ]; then
    remote_cmd="bash -s --$args"
  else
    remote_cmd="sudo -n bash -s --$args"
  fi
  tty_args=()
  [ -t 0 ] && [ -t 1 ] && tty_args=(-tt)
  SSHPASS="$login_pass" sshpass -e ssh "${ssh_opts[@]}" "${tty_args[@]}" "$login_user@$host" "$remote_cmd" < "$script"
  exit $?
fi

if [ -n "$remote_command" ]; then
  remote_ssh "$remote_command"
  exit $?
fi

# Интерактивная сессия: под root — сразу shell, иначе shell под sudo.
export SSHPASS="$login_pass"
if [ "$login_is_root" = 1 ] || [ "$use_sudo" = 0 ]; then
  exec sshpass -e ssh -tt "${ssh_opts[@]}" "$login_user@$host" </dev/tty
fi
exec sshpass -e ssh -tt "${ssh_opts[@]}" "$login_user@$host" "sudo -n -i" </dev/tty
