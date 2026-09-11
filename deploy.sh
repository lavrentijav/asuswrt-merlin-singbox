#!/bin/sh
# Push the addon tree to the test router. sftp-server is absent on the firmware,
# so files go over a plain `ssh cat` pipe instead of scp.
R="${SBM_ROUTER:-admin@192.168.2.1}"
set -e
ssh -o BatchMode=yes "$R" 'mkdir -p /jffs/addons/sbmerlin/lib /jffs/addons/sbmerlin/www /jffs/addons/sbmerlin/templates'
for f in $(cd sbmerlin && find . -type f | sed 's|^\./||'); do
	ssh -o BatchMode=yes "$R" "cat > /jffs/addons/sbmerlin/$f" < "sbmerlin/$f"
	echo "  -> $f"
done
ssh -o BatchMode=yes "$R" 'chmod 755 /jffs/addons/sbmerlin/sbmerlin.sh 2>/dev/null; chmod 644 /jffs/addons/sbmerlin/lib/*.sh'
echo "deployed to $R"
