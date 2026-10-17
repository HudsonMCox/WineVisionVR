#!/usr/bin/env bash
# Wine loads these bootstrap files relative to the app, not WINEDLLPATH.
set -euo pipefail
APP="${1:?Usage: verify_wine_bundle.sh APP_PATH}"
ARCHES=(aarch64-windows arm64ec-windows)
if [[ "${AVPPLAY_ENABLE_X86:-0}" == 1 ]]; then
  ARCHES+=(i386-windows)
elif [[ -e "$APP/Runtime/i386-windows" || -e "$APP/WindowsVR/Guest/x86" ]]; then
  echo "error: x86 resource trees require AVPPLAY_ENABLE_X86=1 for validation" >&2
  exit 1
fi
for ARCH in "${ARCHES[@]}"; do
  for FILE in ntdll.dll apisetschema.dll; do
    LOADER="$APP/$ARCH/$FILE"
    RUNTIME="$APP/Runtime/$ARCH/$FILE"
    if [[ ! -s "$LOADER" || ! -s "$RUNTIME" ]]; then
      echo "error: Missing Wine bootstrap file: $LOADER (runtime source: $RUNTIME)" >&2
      exit 1
    fi
    if ! cmp -s "$LOADER" "$RUNTIME"; then
      echo "error: Wine bootstrap file differs from packaged runtime: $LOADER" >&2
      exit 1
    fi
  done
done

# Native ntdll's data_dir is the executable directory. Missing locale/case
# tables cause a null-table read during environment initialization, before the
# guest can create a window. Verify all packaged tables at that actual path.
for FILE in normnfc.nls locale.nls l_intl.nls; do
  if [[ ! -s "$APP/Runtime/nls/$FILE" ]]; then
    echo "error: Missing required runtime NLS table: $FILE" >&2
    exit 1
  fi
done
for RUNTIME in "$APP"/Runtime/nls/*.nls; do
  LOADER="$APP/nls/$(basename "$RUNTIME")"
  if [[ ! -s "$LOADER" ]] || ! cmp -s "$LOADER" "$RUNTIME"; then
    echo "error: Missing or mismatched Wine loader NLS table: $LOADER" >&2
    exit 1
  fi
done
for FILE in tahoma.ttf tahomabd.ttf ms_sans_serif.ttf system.ttf; do
  if [[ ! -s "$APP/fonts/$FILE" ]]; then
    echo "error: Missing Wine UI font at loader data path: $APP/fonts/$FILE" >&2
    exit 1
  fi
done
for FILE in crypt32.dll cryptbase.dll rsaenh.dll psapi.dll imm32.dll; do
  if [[ ! -s "$APP/Runtime/arm64ec-windows/$FILE" ]]; then
    echo "error: Missing Wine CryptoAPI provider dependency: $FILE" >&2
    exit 1
  fi
done
echo "Wine bootstrap bundle verified (selected architectures, matching NLS and required UI fonts)."
if [[ -f "$APP/Runtime/AVPPLAY_GUEST_BUILD_RECEIPT.json" ]]; then
  python3 "$(dirname "$0")/verify_wine_imports.py" "$APP/Runtime/arm64ec-windows"
fi

# Modern DXMT shares its validated DLL closure across D3D11 and D3D12.
if [[ -f "$APP/WindowsVR/GraphicsCapabilities.json" || -f "$APP/WindowsVR/D3D12Experimental/AVPPLAY_DXMT_D3D12_PROFILE.json" ]]; then
  python3 "$(dirname "$0")/verify_dxmt_bundle.py" "$APP"
fi

if [[ -d "$APP/WindowsVR/Guest/x64/OpenComposite" ]]; then
  python3 "$(dirname "$0")/verify_openvr_bundle.py" "$APP/WindowsVR/Guest/x64/OpenComposite/bin/vrclient_x64.dll"
fi

if [[ -d "$APP/WindowsVR/Guest/x64" ]]; then
  python3 "$(dirname "$0")/verify_openvr_bundle.py" "$APP/WindowsVR/Guest/x64/wvr_openxr.dll"
fi

if [[ "${AVPPLAY_ENABLE_X86:-0}" == 1 ]]; then
  python3 - "$APP" <<'PYX86'
import json
from pathlib import Path
import sys
app = Path(sys.argv[1])
receipt = json.loads((app / "Runtime/AVPPLAY_GUEST_BUILD_RECEIPT.json").read_text())
translator = receipt.get("guest", {}).get("x86", {}).get("fexWow64Translator", {})
if receipt.get("guest", {}).get("x86", {}).get("enabled") is not True or translator.get("guestResource") != "aarch64-windows/xtajit.dll":
    raise SystemExit("error: x86 bundle lacks its receipt-bound WOW64 FEX translator")
import hashlib
backend = app / "Runtime" / translator["guestResource"]
if backend.is_symlink() or not backend.is_file() or hashlib.sha256(backend.read_bytes()).hexdigest() != translator.get("sha256"):
    raise SystemExit("error: packaged WOW64 FEX translator differs from its receipt")
PYX86
  python3 "$(dirname "$0")/verify_wine_imports.py" "$APP/Runtime/aarch64-windows" --machine arm64
  python3 "$(dirname "$0")/verify_wine_imports.py" "$APP/Runtime/i386-windows" --machine i386 --reject-shared-cxx \
    --extra-file "$APP/WindowsVR/Guest/x86/OpenComposite/bin/vrclient.dll" \
    --extra-file "$APP/WindowsVR/Guest/x86/wvr_openxr.dll"
fi

if [[ -d "$APP/WindowsVR/Guest/arm64ec" ]]; then
  python3 "$(dirname "$0")/stage_arm64ec_guest.py" --output "$APP/WindowsVR/Guest/arm64ec" --verify
fi

if [[ -d "$APP/WindowsVR/CacheTools" ]]; then
  python3 "$(dirname "$0")/stage_fex_cache.py" --verify --output "$APP/WindowsVR/CacheTools" --runtime "$APP/Runtime"
fi
