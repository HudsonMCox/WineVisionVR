# Steam on the research headset app

The native **Steam library** sheet signs in to Steam, lists owned games, and
downloads their Windows depots directly into the headset's private Steam
library. It does not download a second copy to the Mac. Sign-in supports
password/Steam Guard and QR approval. Tokens use the device-only Keychain;
passwords, codes and tokens are excluded from diagnostic messages.

In the library menu choose **Prepare Valve client** before selecting a game
to play. This downloads the exact client packages supported by Madeira Dock
from Valve's CDN and verifies their sizes and SHA-256 hashes. Other client
versions are rejected. No Valve client binaries are distributed with the app.

Choose a game's artwork card to open its square download panel. **Close** is
always available in both the panel and library, including after network errors.
The panel shows artwork, progress, transferred bytes, speed and a per-game error.
Choose **Download**, **Pause**, **Resume** or **Retry download** there. Completed
chunks are verified and journaled; retries resume those chunks, and the Steam
install record is written after completion. Downloads need sufficient headset
storage and an active app. This port does not promise background downloads.

After installation, choose a game's **Play** menu and the desired Windows/VR
launch option. This selects the game in the research launcher; then press
**Launch game** there. The launch prepares the debugger/JIT and immersive
compositor first. Native downloads pause and their Steam connection logs off
before Valve's Windows client takes the account. Dock receives its token in a
protected, single-use file, outside Documents, rather than the manifest or argv.
The runtime still has one session per app process; restart after session exit.

Dock is a headless Windows host for Valve's own client libraries. It performs
Steam launch and license handling, while OpenComposite and the project-owned
OpenXR bridge provide the intended VR transport. This does not run the complete
Windows SteamVR desktop runtime, and it does not establish compatibility with
every SteamVR game. D3D11 is the initial Steam launch profile. Games requiring
additional launchers, one-time redistributable installers, anti-cheat or other
unsupported platform services may fail. Steam Cloud synchronization and
Madeira's one-time installer orchestration have not been ported.

The shared Steam prefix is
`Documents/WindowsVR/Prefixes/<SHA256("steam.shared")>/`; downloads live under
its `drive_c/Program Files (x86)/Steam/steamapps`. Different Steam games share
this prefix so the client can resolve their install records.

## Source and build

Steam sources are adapted from Madeira revision
`48f976429c189f8396e23d251d8a82f43c705922`. Their GPL notices, converter exception,
and provenance are in `third-party/steam-native`. Madeira Dock is built from
revision `72558e416a390f3669457930f09a389e54f49556`; its source, license and
cross-compiler runtime notices are preserved in the generated `dock-notices.txt`.

The normal assembler builds Dock automatically from the original pinned Git
checkout, whose submodule metadata is retained. For that source checkout:

```sh
AVPPLAY_MADEIRA_STEAM_SOURCE=/absolute/path/to/pinned/Madeira \
AVPPLAY_LLVM_MINGW_ROOT=/absolute/path/to/llvm-mingw \
bash windows-vr-tools/build_steam_dock.sh
```

Generated Dock binaries and receipts are excluded from Git. The app embeds
`Resources/arm64ec-windows` for Madeira's resource lookup; despite the folder
name, this Dock executable is x86-64 PE and runs through FEX.

Compilation and installation are separate from live Steam verification. No
Steam sign-in, client launch, game download or game execution was performed
during this implementation. Game rendering, licensing, child-process behavior
and sustained performance remain unverified on Vision Pro.
