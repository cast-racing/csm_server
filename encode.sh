AC_CFG="${AC_CFG:-$HOME/.steam/debian-installation/steamapps/common/assettocorsa/server/cfg}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/csp_extra_options.ini" "$SCRIPT_DIR/RaceFlags.lua" "$SCRIPT_DIR/SpeedLimiter.lua" "$SCRIPT_DIR/Respawn.lua" "$AC_CFG/"
cd "$AC_CFG"
python3 -c "
import zlib, base64
with open('csp_extra_options.ini') as f: content = f.read()
b64 = base64.b64encode(zlib.compress(content.encode(), 6)).decode().rstrip('=')
with open('welcome.txt', 'w') as f: f.write('\t' * 32 + '\$CSP0:' + b64)
"
cp welcome.txt "$SCRIPT_DIR/welcome.txt"