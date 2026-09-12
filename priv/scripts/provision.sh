#!/bin/bash
set -euo pipefail

name=$1
session=$2
script=$3
archive=$4
data_dir=${5:-}
data_volume=0
tart_options=(--no-graphics)
if [ -n "$data_dir" ]; then
  test -d "$data_dir"
  tart_options+=(--dir="nerves-data:$data_dir")
  data_volume=1
fi
control_dir=$(mktemp -d /tmp/nerves-ssh.XXXXXX)
ssh_options=(-F /dev/null -o UseKeychain=no -o IdentityAgent=none
  -o IdentityFile=none -o GlobalKnownHostsFile=/dev/null
  -o ControlMaster=auto -o ControlPersist=60 -o "ControlPath=$control_dir/socket"
  -o PubkeyAuthentication=no -o PreferredAuthentications=password
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$session/known_hosts"
  -o ConnectTimeout=3 -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

tart run "$name" "${tart_options[@]}" >"$session/tart.log" 2>&1 &
vm_pid=$!
cleanup() {
  if [ -n "${ip:-}" ]; then ssh "${ssh_options[@]}" -O exit "$GUEST_USERNAME@$ip" >/dev/null 2>&1 || true; fi
  rm -rf "$control_dir"
  tart stop "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
deadline=$((SECONDS + 180))
ready=false
: > "$session/ssh.log"
while [ "$SECONDS" -lt "$deadline" ]; do
  if ! kill -0 "$vm_pid" 2>/dev/null; then
    cat "$session/tart.log" >&2
    exit 1
  fi
  ip=$(tart ip "$name" 2>/dev/null || true)
  if [ -n "$ip" ] && sshpass -e ssh "${ssh_options[@]}" "$GUEST_USERNAME@$ip" true 2>"$session/ssh.log"; then
    ready=true
    break
  fi
  sleep 2
done
if [ "$ready" != true ]; then
  cat "$session/ssh.log" >&2
  echo 'Guest SSH readiness exceeded 180 seconds' >&2
  exit 1
fi
printf 'Connected to %s at %s\n' "$name" "$ip"
if [ -n "$archive" ]; then
  sshpass -e scp "${ssh_options[@]}" "$archive" "$GUEST_USERNAME@$ip:/tmp/nerves-release.tar.gz"
fi
sshpass -e ssh "${ssh_options[@]}" "$GUEST_USERNAME@$ip" \
  "env EXPECTED_VERSION=$EXPECTED_VERSION EXPECTED_BUILD=$EXPECTED_BUILD GUEST_USERNAME=$GUEST_USERNAME NERVES_DATA_VOLUME=$data_volume /bin/bash -s" <"$script"
sshpass -e ssh "${ssh_options[@]}" "$GUEST_USERNAME@$ip" 'sudo -n shutdown -h now' || test "$?" = 255
deadline=$((SECONDS + 60))
while kill -0 "$vm_pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 1; done
if kill -0 "$vm_pid" 2>/dev/null; then
  echo 'Guest shutdown exceeded 60 seconds' >&2
  exit 1
fi
wait "$vm_pid"
rm -rf "$control_dir"
trap - EXIT
echo 'Guest shut down cleanly'
