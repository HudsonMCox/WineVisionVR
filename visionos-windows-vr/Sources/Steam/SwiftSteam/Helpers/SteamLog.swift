// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Logging for Steam sign-in.
///
/// `event` lines are the always-on, low-volume record ([steam-signin]). They
/// never contain tokens, passwords, Steam Guard codes, account names, Steam
/// IDs or message payloads.
///
/// `trace` lines are protocol-level detail, off by default. Enable with
/// `env.MADEIRA_STEAM_TRACE = 1` in madeira.cfg. They are still written
/// without credentials or payload bytes.
enum SteamLog {
    static let tracing = ProcessInfo.processInfo.environment["AVPPLAY_STEAM_TRACE"] == "1"

    static func trace(_ message: @autoclosure () -> String) {
        guard tracing else { return }
        NSLog("[AVPPlay Steam] %@", message())
    }

    static func event(_ message: String) {
        NSLog("[AVPPlay Steam] %@", message)
    }
}
