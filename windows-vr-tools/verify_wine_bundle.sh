#!/usr/bin/env bash
# Wine loads these bootstrap files relative to the app, not WINEDLLPATH.
set -euo pipefail
APP="${1:?Usage: verify_wine_bundle.sh APP_PATH}"
for ARCH in aarch64-windows arm64ec-windows; do
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
echo "Wine bootstrap bundle verified (both architectures, matching runtime files)."

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

if [[ -d "$APP/WindowsVR/Guest/arm64ec" ]]; then
  python3 "$(dirname "$0")/stage_arm64ec_guest.py" --output "$APP/WindowsVR/Guest/arm64ec" --verify
fi

if [[ -d "$APP/WindowsVR/CacheTools" ]]; then
  python3 "$(dirname "$0")/stage_fex_cache.py" --verify --output "$APP/WindowsVR/CacheTools" --runtime "$APP/Runtime"
fi
