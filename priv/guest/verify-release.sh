set -euo pipefail

root=/opt/nerves/app
name=$(plutil -extract name raw -o - "$root/nerves-release.json")
erts=$(plutil -extract system.erts_version raw -o - "$root/nerves-release.json")
test -x "$root/erts-$erts/bin/beam.smp"
export RELEASE_DISTRIBUTION=name RELEASE_NODE=nerves@127.0.0.1 ERL_EPMD_ADDRESS=127.0.0.1
export ERL_FLAGS='+S 2:2 -kernel inet_dist_use_interface {127,0,0,1}'
deadline=$((SECONDS + 90))
pid=''
healthy=false
: > /tmp/nerves-health.log
while [ "$SECONDS" -lt "$deadline" ]; do
  state=$(sudo -n launchctl print system/org.nerves.application)
  pid=$(printf '%s\n' "$state" | awk '/^[[:space:]]*pid = / {print $3; exit}')
  if [ -n "$pid" ] && "$root/bin/$name" rpc \
    '{:ok, [apps]} = :file.consult(~c"/opt/nerves/app/nerves-applications.config"); started = Application.started_applications(); Enum.each(apps, fn app -> true = List.keymember?(started, app, 0) end); IO.puts("All release applications are running")' > /tmp/nerves-health.log 2>&1; then
    healthy=true
    break
  fi
  sleep 2
done
cat /tmp/nerves-health.log
rm /tmp/nerves-health.log
if [ "$healthy" != true ]; then tail -30 /var/log/nerves/application.log >&2; exit 1; fi
sleep 3
test "$(sudo -n launchctl print system/org.nerves.application | awk '/^[[:space:]]*pid = / {print $3; exit}')" = "$pid"
ps -p "$pid" -o comm= | grep -F "$root/erts-$erts/bin/beam.smp"
cd /var/lib/nerves
"$root/bin/$name" rpc \
  '{:ok, _} = Application.ensure_all_started(:ssl); 32 = byte_size(:crypto.strong_rand_bytes(32)); IO.inspect({:runtime, :erlang.system_info(:version), :crypto.info_lib()})'
tail -10 /var/log/nerves/application.log
sysctl -n kern.boottime
printf 'Verified %s under launchd as PID %s\n' "$name" "$pid"
