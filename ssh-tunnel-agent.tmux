#!/usr/bin/env bash

# ssh-tunnel-agent.tmux
#
#   Maintains multiple SSH tunnels in a persistent tmux session

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# shellcheck disable=SC2155
declare -r _self_id=$( basename "${BASH_SOURCE[0]}" .tmux  )

# Default configuration file locations (first found wins)
declare -ar _config_path=(
  "${XDG_CONFIG_HOME:-${HOME}/.config}/${_self_id}/config"
  "${HOME}/.local/etc/${_self_id}/config"
  "/usr/local/etc/${_self_id}/config"
  "/usr/etc/${_self_id}/config"
  "/etc/${_self_id}/config"
)

# Session name for tmux
declare -r _session_id=${_self_id//./-}

# Log file for debugging (used by launchd/systemd)
declare -r _log_file="${XDG_STATE_HOME:-${HOME}/.local/state}/${_self_id}/tunnel.log"

# ============================================================================
# Functions
# ============================================================================

log() {
  local level="$1"
  shift
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "${_log_file}"
}

error() {
  log "ERROR" "$@" >&2
}

info() {
  log "INFO" "$@"
}

debug() {
  if [[ -n "${DEBUG:-}" ]]; then
    log "DEBUG" "$@"
  fi
}

die() {
  error "$@"
  exit 1
}

# Load configuration from file (required)
load_config() {
  local config_file=""

  for path in "${_config_path[@]}"; do
    if [[ -f "${path}" ]]; then
      config_file="${path}"
      break
    fi
  done

  if [[ -z "${config_file}" ]]; then
    die "No configuration file found. Searched:" \
        "${_config_path[*]}"
  fi

  info "Loading configuration from ${config_file}"
  # shellcheck source=/dev/null
  source "${config_file}"

  # Validate required settings
  local missing=()
  [[ -z "${ssh_host:-}" ]] && missing+=("ssh_host")
  [[ -z "${ssh_port:-}" ]] && missing+=("ssh_port")
  [[ -z "${ssh_user:-}" ]] && missing+=("ssh_user")
  [[ -z "${ssh_term:-}" ]] && missing+=("ssh_term")

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required config settings: ${missing[*]}" \
        "(in ${config_file})"
  fi
}

# Validate that required commands exist
validate_dependencies() {
  local missing=()

  for cmd in tmux ssh; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required commands: ${missing[*]}"
  fi
}

# Ensure log directory exists
ensure_log_dir() {
  local log_dir
  log_dir="$(dirname "${_log_file}")"

  if [[ ! -d "${log_dir}" ]]; then
    mkdir -p "${log_dir}" || die "Failed to create log directory: ${log_dir}"
  fi
}

# Parse tunnel specification into SSH arguments
# Appends results to global _forward_args array
parse_tunnel_spec() {
  local spec="$1"
  local tunnel_name="$2"

  local type="${spec%%:*}"
  local rest="${spec#*:}"

  case "${type}" in
    L)
      # L:localport:remotehost:remoteport
      if [[ "${rest}" =~ ^([0-9]+):([^:]+):([0-9]+)$ ]]; then
        _forward_args+=("-L" "localhost:${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}")
      else
        error "Invalid local forward specification for ${tunnel_name}: ${spec}"
        return 1
      fi
      ;;
    D)
      # D:localport
      if [[ "${rest}" =~ ^([0-9]+)$ ]]; then
        _forward_args+=("-D" "${BASH_REMATCH[1]}")
      else
        error "Invalid dynamic forward specification for ${tunnel_name}: ${spec}"
        return 1
      fi
      ;;
    R)
      # R:remoteport:localhost:localport
      if [[ "${rest}" =~ ^([0-9]+):([^:]+):([0-9]+)$ ]]; then
        _forward_args+=("-R" "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}")
      else
        error "Invalid remote forward specification for ${tunnel_name}: ${spec}"
        return 1
      fi
      ;;
    *)
      error "Unknown tunnel type '${type}' for ${tunnel_name}: ${spec}"
      return 1
      ;;
  esac

  return 0
}

# Build SSH command for a tunnel
# Sets global _ssh_cmd array with the result
build_ssh_command() {
  local tunnel_name="$1"
  local tunnel_specs_str="$2"

  _forward_args=()

  # Parse each tunnel specification
  for spec in ${tunnel_specs_str}; do
    parse_tunnel_spec "${spec}" "${tunnel_name}" || return 1
  done

  if [[ ${#_forward_args[@]} -eq 0 ]]; then
    error "No valid forwarding specifications for tunnel: ${tunnel_name}"
    return 1
  fi

  local -a ssh_argv=(
    "ssh"
    "-v" "-N" "-T"
    "-p" "${ssh_port}"
    "-o" "SetEnv=TERM=${ssh_term}"
    "-o" "SessionType=none"
    "-o" "ExitOnForwardFailure=yes"
    "-o" "ServerAliveInterval=60"
    "-o" "ServerAliveCountMax=3"
    "${_forward_args[@]}"
    "${ssh_user}@${ssh_host}"
  )

  # Wrap ssh in a bash runner that records startup, the "ready" moment (when
  # all forwards are bound and ssh enters its interactive session), and any
  # non-zero exit. This makes tunnel health visible in the shared log file
  # even when running detached.
  # Args to the runner: <tunnel-name> <log-file> <ssh...>
  local runner='
    name=$1; log=$2; shift 2
    ts() { date +"%Y-%m-%d %H:%M:%S"; }
    errfile=$(mktemp -t ssh-tunnel-agent.XXXXXX) || errfile=/tmp/ssh-tunnel-agent.$$.err
    trap "rm -f \"$errfile\"" EXIT
    printf "[%s] [INFO] tunnel %s: starting ssh\n" "$(ts)" "$name" >> "$log"
    # Stream ssh stderr: keep it visible in the pane, save to errfile for
    # later inclusion in the error report, and watch for the readiness marker.
    "$@" 2> >(
      ready=0
      while IFS= read -r line; do
        printf "%s\n" "$line" >&2
        printf "%s\n" "$line" >> "$errfile"
        if [[ $ready -eq 0 && $line == *"Entering interactive session."* ]]; then
          ready=1
          printf "[%s] [INFO] tunnel %s: ready\n" "$(ts)" "$name" >> "$log"
        fi
      done
    )
    rc=$?
    if [[ $rc -ne 0 ]]; then
      {
        printf "[%s] [ERROR] tunnel %s: ssh exited with code %d\n" "$(ts)" "$name" "$rc"
        printf "[%s] [ERROR] tunnel %s: last lines of ssh stderr:\n" "$(ts)" "$name"
        tail -n 20 "$errfile" | sed "s/^/    /"
      } >> "$log"
      # keep the pane alive briefly so an attached user can read the error
      printf "\n>>> tunnel %s failed (exit %d); see %s <<<\n" "$name" "$rc" "$log" >&2
      sleep 10
    else
      printf "[%s] [INFO] tunnel %s: ssh exited cleanly\n" "$(ts)" "$name" >> "$log"
    fi
    exit "$rc"
  '

  _ssh_cmd=(
    "bash" "-c" "${runner}" "ssh-tunnel-runner"
    "${tunnel_name}" "${_log_file}"
    "${ssh_argv[@]}"
  )

  return 0
}

# Show current tunnel status
show_status() {
  if ! tmux has-session -t "${_session_id}" 2>/dev/null; then
    echo "Tunnel session '${_session_id}' is not running"
    return 1
  fi

  echo "Tunnel session '${_session_id}' is active"
  echo
  echo "Panes:"
  tmux list-panes -t "${_session_id}" -F "  #{pane_index}: #{pane_current_command} (#{pane_pid})" 2>/dev/null || true
  echo
  echo "Active port forwards:"
  local i
  for i in "${!tunnel_names[@]}"; do
    echo "  ${tunnel_names[i]}:"
    for spec in ${tunnel_specs[i]}; do
      case "${spec%%:*}" in
        L) echo "    Local: ${spec#*:}" ;;
        D) echo "    SOCKS: ${spec#*:}" ;;
        R) echo "    Remote: ${spec#*:}" ;;
      esac
    done
  done
}

# List configured tunnels
list_tunnels() {
  echo "Configured tunnels:"
  local i
  for i in "${!tunnel_names[@]}"; do
    echo "  ${tunnel_names[i]}: ${tunnel_specs[i]}"
  done
}

# Wait for each started tunnel to become ready or fail, with timeout.
# Reads the shared log file, scanning only lines appended since this session
# started, and prints a status summary plus any error details.
# Args: list of tunnel names that were launched
# Respects TUNNEL_READY_TIMEOUT (seconds, default 15).
wait_for_tunnels() {
  local -a names=("$@")
  local timeout="${TUNNEL_READY_TIMEOUT:-15}"
  local start_epoch
  start_epoch=$(date +%s)

  local log_start_line=0
  if [[ -f "${_log_file}" ]]; then
    log_start_line=$(wc -l < "${_log_file}" | tr -d '[:space:]')
    log_start_line=${log_start_line:-0}
  fi

  info "Waiting up to ${timeout}s for ${#names[@]} tunnel(s) to stabilize..."

  # Parallel arrays: statuses[i] is the state of names[i].
  # Values: "pending", "ready", "failed".
  local -a statuses=()
  local n
  for n in "${names[@]}"; do statuses+=("pending"); done

  local all_done=0
  while [[ ${all_done} -eq 0 ]]; do
    # Scan all new log lines and update status.
    local line
    while IFS= read -r line; do
      local j
      for j in "${!names[@]}"; do
        [[ "${statuses[j]}" != "pending" ]] && continue
        if [[ "${line}" == *"tunnel ${names[j]}: ready"* ]]; then
          statuses[j]="ready"
        elif [[ "${line}" == *"tunnel ${names[j]}: ssh exited with code"* ]]; then
          statuses[j]="failed"
        fi
      done
    done < <(tail -n "+$((log_start_line + 1))" "${_log_file}" 2>/dev/null)

    all_done=1
    local s
    for s in "${statuses[@]}"; do
      if [[ "${s}" == "pending" ]]; then all_done=0; break; fi
    done

    if [[ ${all_done} -eq 1 ]]; then break; fi

    local now elapsed
    now=$(date +%s)
    elapsed=$((now - start_epoch))
    if (( elapsed >= timeout )); then break; fi

    sleep 1
  done

  # Summary
  echo
  echo "Tunnel status:"
  local any_failed=0
  local any_pending=0
  local j
  for j in "${!names[@]}"; do
    case "${statuses[j]}" in
      ready)   echo "  [OK]   ${names[j]}: ready" ;;
      failed)  echo "  [FAIL] ${names[j]}: failed to start"; any_failed=1 ;;
      *)       echo "  [??]   ${names[j]}: did not stabilize within ${timeout}s"; any_pending=1 ;;
    esac
  done

  # If anything went wrong, dump the ERROR lines from this start cycle.
  if [[ ${any_failed} -eq 1 || ${any_pending} -eq 1 ]]; then
    echo
    echo "Errors since start (${_log_file}):"
    tail -n "+$((log_start_line + 1))" "${_log_file}" 2>/dev/null \
      | grep -E '\[(ERROR|WARN)\]' \
      | sed 's/^/  /' \
      || echo "  (no error lines captured; check the log for ssh debug output)"
    return 1
  fi

  return 0
}

# Start tunnel session
start_tunnels() {
  local attach_mode="${1:-}"

  if tmux has-session -t "${_session_id}" 2>/dev/null; then
    info "Tunnel session already exists"
    if [[ "${attach_mode}" == "attach" ]]; then
      exec tmux attach-session -t "${_session_id}"
    fi
    return 0
  fi

  info "Starting tunnel session: ${_session_id}"

  # Build tmux command
  local -a tmux_cmd=(
    "new-session"
    "-s" "${_session_id}"
    "-n" "tunnels"
  )

  # Add -d flag if not attaching
  if [[ "${attach_mode}" != "attach" ]]; then
    tmux_cmd+=("-d")
  fi

  local first_pane=1
  local pane_count=0
  local -a added_names=()

  # Create a pane for each tunnel
  local i
  for i in "${!tunnel_names[@]}"; do
    local tunnel_name="${tunnel_names[i]}"
    _ssh_cmd=()

    if ! build_ssh_command "${tunnel_name}" "${tunnel_specs[i]}"; then
      error "Skipping tunnel ${tunnel_name} due to configuration error"
      continue
    fi

    if [[ ${first_pane} -eq 1 ]]; then
      # First pane: create session
      tmux_cmd+=("${_ssh_cmd[@]}" ";")
      first_pane=0
    else
      # Subsequent panes: split window
      tmux_cmd+=("split-window" "-c" "${HOME}" "${_ssh_cmd[@]}" ";")
    fi

    # Use prefix-increment to prevent evaluating to error (0), which would exit
    # the script due to shopt errexit (-e).
    ((++pane_count))
    added_names+=("${tunnel_name}")
    info "Added tunnel: ${tunnel_name}"
  done

  if [[ ${pane_count} -eq 0 ]]; then
    info "No tunnels configured; waiting for config file update"
    return 0
  fi

  # Apply even-vertical layout for equal height horizontal panes
  if [[ ${pane_count} -gt 1 ]]; then
    tmux_cmd+=("select-layout" "even-vertical")
  fi

  debug "Executing: tmux ${tmux_cmd[*]}"

  if ! tmux "${tmux_cmd[@]}"; then
    die "Failed to start tunnel session"
  fi

  info "Tunnel session started with ${pane_count} pane(s); monitoring readiness..."

  # When attaching, tmux takes over the terminal and we can't monitor.
  if [[ "${attach_mode}" == "attach" ]]; then
    return 0
  fi

  # Block until each tunnel is ready or has failed (or timeout).
  local rc=0
  wait_for_tunnels "${added_names[@]}" || rc=$?
  return ${rc}
}

# Stop tunnel session
stop_tunnels() {
  if ! tmux has-session -t "${_session_id}" 2>/dev/null; then
    info "Tunnel session is not running"
    return 0
  fi

  info "Stopping tunnel session: ${_session_id}"
  tmux kill-session -t "${_session_id}"
}

# Restart tunnel session
restart_tunnels() {
  stop_tunnels
  sleep 1
  start_tunnels
}

# Show usage information
show_usage() {
  cat <<EOF
Usage: ${_self_id} [COMMAND] [OPTIONS]

Commands:
  start           Start tunnel session (default)
  stop            Stop tunnel session
  restart         Restart tunnel session
  status          Show tunnel session status
  list            List configured tunnels
  attach          Attach to tunnel session
  help            Show this help message

Options:
  -a, --attach    Start and attach to session
  -h, --help      Show this help message

Environment Variables:
  DEBUG=1                 Enable debug logging
  TUNNEL_READY_TIMEOUT=N  Seconds to wait for tunnels to stabilize (default 15)

Configuration:
  Config files are loaded from (first found):
    - ${XDG_CONFIG_HOME:-~/.config}/${_self_id}/config
    - ~/.local/etc/${_self_id}/config
    - /usr/local/etc/${_self_id}/config
    - /usr/etc/${_self_id}/config
    - /etc/${_self_id}/config

  Config file must define the following SSH variables:
    ssh_host    - SSH proxy host
    ssh_port    - SSH port
    ssh_user    - SSH user
    ssh_term    - Terminal type

  tunnel_names/tunnel_specs format (parallel arrays):
    tunnel_names+=( "name" )
    tunnel_specs+=( "type:spec type:spec ..." )

    Types:
      L:localport:remotehost:remoteport  - Local port forward
      D:localport                        - Dynamic SOCKS proxy
      R:remoteport:localhost:localport   - Remote port forward

Examples:
  ${_self_id} start          # Start in background
  ${_self_id} start -a       # Start and attach
  ${_self_id} status         # Check status
  ${_self_id} attach         # Attach to running session

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
  ensure_log_dir
  validate_dependencies
  load_config

  local command="start"
  local attach_mode=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help)
        show_usage
        exit 0
        ;;
      -a|--attach)
        attach_mode="attach"
        shift
        ;;
      start|stop|restart|status|list|attach)
        command="$1"
        shift
        ;;
      *)
        error "Unknown argument: $1"
        show_usage
        exit 1
        ;;
    esac
  done

  # Execute command
  case "${command}" in
    start)
      start_tunnels "${attach_mode}"
      ;;
    stop)
      stop_tunnels
      ;;
    restart)
      restart_tunnels
      ;;
    status)
      show_status
      ;;
    list)
      list_tunnels
      ;;
    attach)
      if tmux has-session -t "${_session_id}" 2>/dev/null; then
        exec tmux attach-session -t "${_session_id}"
      else
        die "Tunnel session is not running. Start it first with: $0 start"
      fi
      ;;
    *)
      error "Unknown command: ${command}"
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
