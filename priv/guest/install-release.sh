set -euo pipefail

release_root=/opt/nerves/app
test ! -e /opt/nerves
sudo -n mkdir -p "$release_root" /var/lib/nerves /var/log/nerves
sudo -n tar -xzf /tmp/nerves-release.tar.gz -C "$release_root"
rm /tmp/nerves-release.tar.gz
release_name=$(/usr/bin/plutil -extract name raw -o - "$release_root/nerves-release.json")
case "$release_name" in
  ''|*[!a-z0-9_]*) exit 1 ;;
esac
test -x "$release_root/bin/$release_name"
sudo -n chown -R "$GUEST_USERNAME":staff /opt/nerves /var/lib/nerves /var/log/nerves
label=org.nerves.application
plist="/Library/LaunchDaemons/$label.plist"
persistent_environment=''
if [ "${NERVES_DATA_VOLUME:-0}" = 1 ]; then
  persistent_environment='<key>NERVES_DATA_DIR</key><string>/Volumes/My Shared Files/nerves-data</string>'
fi
sudo -n tee "$plist" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>UserName</key><string>$GUEST_USERNAME</string>
<key>ProgramArguments</key><array><string>$release_root/bin/$release_name</string><string>start</string></array>
<key>WorkingDirectory</key><string>/var/lib/nerves</string>
<key>EnvironmentVariables</key><dict>
$persistent_environment
<key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
<key>HOME</key><string>/Users/$GUEST_USERNAME</string>
<key>LANG</key><string>en_US.UTF-8</string>
<key>RELEASE_DISTRIBUTION</key><string>name</string>
<key>RELEASE_NODE</key><string>nerves@127.0.0.1</string>
<key>ERL_EPMD_ADDRESS</key><string>127.0.0.1</string>
<key>RELEASE_TMP</key><string>/var/lib/nerves/tmp</string>
<key>ERL_FLAGS</key><string>+S 2:2 -kernel inet_dist_use_interface {127,0,0,1}</string>
</dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>/var/log/nerves/application.log</string>
<key>StandardErrorPath</key><string>/var/log/nerves/application.log</string>
</dict></plist>
PLIST
sudo -n chmod 644 "$plist"
sudo -n chown root:wheel "$plist"
/usr/bin/plutil -lint "$plist"
"$release_root/bin/$release_name" eval ':erlang.display({:otp, :erlang.system_info(:otp_release)}); {:ok, _} = Application.ensure_all_started(:crypto); 32 = byte_size(:crypto.strong_rand_bytes(32))'
sudo -n launchctl bootstrap system "$plist"
printf 'Installed and started %s\n' "$release_name"
