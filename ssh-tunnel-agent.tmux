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
  "/etc/${_self_id}/config"
)

# Session name for tmux
declare -r _session_id=${_self_id//./-}

# Log file for debugging (used by launchd)
declare -r _log_file="${XDG_STATE_HOME:-${HOME}/.local/state}/${_self_id}/tunnel.log"

# Default SSH connection settings (can be overridden in config)
declare -A ssh_config=(
  [host]="jumphost"
  [port]="22"
  [user]=${USER}
  [term]=${TERM}
)

# Tunnel definitions (can be overridden by config file)
# Format: [name]="type:spec type:spec ..."
# Types:
#   L:localport:remotehost:remoteport  - Local port forward
#   D:localport                        - Dynamic SOCKS proxy
#   R:remoteport:localhost:localport   - Remote port forward
declare -A tunnel_spec=(
  [svn]="L:3690:remotehost:3690 L:3343:remotehost:3343"
  [jira]="L:8081:remotehost:8081"
  [socks]="D:65135"
)

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

# Load configuration from file if it exists
load_config() {
  local config_file=""

  for path in "${_config_path[@]}"; do
    if [[ -f "${path}" ]]; then
      config_file="${path}"
      break
    fi
  done

  if [[ -n "${config_file}" ]]; then
    info "Loading configuration from ${config_file}"
    # shellcheck source=/dev/null
    source "${config_file}"
  else
    debug "No configuration file found, using defaults"
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
# Returns array of SSH arguments via nameref
parse_tunnel_spec() {
  local -n result_array=$1
  local spec="$2"
  local tunnel_name="$3"

  local type="${spec%%:*}"
  local rest="${spec#*:}"

  case "${type}" in
    L)
      # L:localport:remotehost:remoteport
      if [[ "${rest}" =~ ^([0-9]+):([^:]+):([0-9]+)$ ]]; then
        result_array+=("-L" "localhost:${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}")
      else
        error "Invalid local forward specification for ${tunnel_name}: ${spec}"
        return 1
      fi
      ;;
    D)
      # D:localport
      if [[ "${rest}" =~ ^([0-9]+)$ ]]; then
        result_array+=("-D" "${BASH_REMATCH[1]}")
      else
        error "Invalid dynamic forward specification for ${tunnel_name}: ${spec}"
        return 1
      fi
      ;;
    R)
      # R:remoteport:localhost:localport
      if [[ "${rest}" =~ ^([0-9]+):([^:]+):([0-9]+)$ ]]; then
        result_array+=("-R" "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}")
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
build_ssh_command() {
  local -n cmd_array=$1
  local tunnel_name="$2"
  local tunnel_specs="$3"

  local -a forward_args=()

  # Parse each tunnel specification
  for spec in ${tunnel_specs}; do
    parse_tunnel_spec forward_args "${spec}" "${tunnel_name}" || return 1
  done

  if [[ ${#forward_args[@]} -eq 0 ]]; then
    error "No valid forwarding specifications for tunnel: ${tunnel_name}"
    return 1
  fi

  # shellcheck disable=SC2034
  cmd_array=(
    "ssh"
    "-v" "-N" "-T"
    "-p" "${ssh_config[port]}"
    "-o" "SetEnv=TERM=${ssh_config[term]}"
    "-o" "SessionType=none"
    "-o" "ExitOnForwardFailure=yes"
    "-o" "ServerAliveInterval=60"
    "-o" "ServerAliveCountMax=3"
    "${forward_args[@]}"
    "${ssh_config[user]}@${ssh_config[host]}"
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
  for tunnel in "${!tunnel_spec[@]}"; do
    echo "  ${tunnel}:"
    for spec in ${tunnel_spec[${tunnel}]}; do
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
  for tunnel in "${!tunnel_spec[@]}"; do
    echo "  ${tunnel}: ${tunnel_spec[${tunnel}]}"
  done
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

  # Create a pane for each tunnel
  for tunnel_name in "${!tunnel_spec[@]}"; do
    local -a ssh_cmd=()

    if ! build_ssh_command ssh_cmd "${tunnel_name}" "${tunnel_spec[${tunnel_name}]}"; then
      error "Skipping tunnel ${tunnel_name} due to configuration error"
      continue
    fi

    if [[ ${first_pane} -eq 1 ]]; then
      # First pane: create session
      tmux_cmd+=("${ssh_cmd[@]}" ";")
      first_pane=0
    else
      # Subsequent panes: split window
      tmux_cmd+=("split-window" "-c" "${HOME}" "${ssh_cmd[@]}" ";")
    fi

    # Use prefix-increment to prevent evaluating to error (0), which would exit
    # the script due to shopt errexit (-e).
    ((++pane_count))
    info "Added tunnel: ${tunnel_name}"
  done

  if [[ ${pane_count} -eq 0 ]]; then
    die "No valid tunnels configured"
  fi

  # Apply even-vertical layout for equal height horizontal panes
  if [[ ${pane_count} -gt 1 ]]; then
    tmux_cmd+=("select-layout" "even-vertical")
  fi

  debug "Executing: tmux ${tmux_cmd[*]}"

  if tmux "${tmux_cmd[@]}"; then
    info "Tunnel session started successfully with ${pane_count} tunnel(s)"
    return 0
  else
    die "Failed to start tunnel session"
  fi
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
  DEBUG=1         Enable debug logging

Configuration:
  Config files are loaded from (first found):
    - ${XDG_CONFIG_HOME:-~/.config}/${_self_id}/config
    - ~/.local/etc/${_self_id}/config
    - /usr/local/etc/${_self_id}/config
    - /etc/${_self_id}/config

  Config file can override ssh_config and tunnel_spec arrays.

  ssh_config keys:
    host    - SSH jump host (default: jumphost)
    port    - SSH port (default: 22)
    user    - SSH user (default: current user)
    term    - Terminal type (default: current TERM)

  tunnel_spec format:
    [name]="type:spec type:spec ..."

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
