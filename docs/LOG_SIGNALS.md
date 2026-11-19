# What the Roblox client log tells SiverSol

The macOS Roblox client writes a plain-text log for every launch in `~/Library/Logs/Roblox/`. Reading it needs no permission. This file lists every line SiverSol uses, the exact pattern, how often it appears, and what is done with it.

Measured on one Apple Silicon Mac on 2026-11-18: 9 game logs, about 8,500 lines, client 0.745 and 0.748, Sol's RNG v5.065.

> **Privacy.** The log also contains the Roblox username, user ids, join tickets, private-server access codes and server IP addresses. SiverSol never shows or sends a raw line. Each signal below is parsed into named fields, and only those fields are shown, stored or sent. `siversolctl sanitize` turns a raw log into a commit-safe fixture by keeping only whitelisted lines and replacing ids and addresses with placeholders.

## Files

| Pattern | Meaning |
|---|---|
| `<version>_<yyyymmddThhmmssZ>_Player_<hex>_last.log` | One game client launch. `<version>` is the client version (for example `0.745.100.7450979`), the stamp is the launch time in UTC. |
| `…_Player_<hex>_CrashHandler_last.log`, `RobloxPlayerInstaller_*.log`, `crashes/` | Not game logs. Ignored. |

- Pick the current log by the **launch stamp in the name**, not by modification time: an old log can still be written after a newer one exists.
- Quitting Roblox makes its menu bar helper relaunch the player as a windowless background process. That launch gets its own log with **no join line**.
- Every line starts with `2026-11-18T12:13:19.517Z,<seconds since launch>,<thread>,<level>[,Info] [<channel>] <text>`. The leading ISO time (UTC) is the event time SiverSol uses.

## Signals in use

### 1. Biome and equipped aura: Rich Presence
```
[FLog::CreatorOutput] [BloxstrapRPC] {"command":"SetRichPresence","data":{"state":"Equipped \"Symphony\"","smallImage":{"hoverText":"Sol's RNG","assetId":…},"largeImage":{"hoverText":"WINDY","assetId":…}}}
```
- Match `[BloxstrapRPC]` anywhere in the line and decode the first balanced JSON object after it. Do not depend on the channel tag (macOS writes `FLog::CreatorOutput`; Windows tools match `FLog::Output`).
- **Biome** = `data.largeImage.hoverText`. Normalize (trim, uppercase, collapse spaces) for the key, keep the original text for display.
- **`data.state`** has three shapes (266 lines seen):

  | `state` | Count | Meaning |
  |---|---|---|
  | `Equipped "<InternalName>"` | 220 | in the world; the name is the aura's internal name (`SeekerOfTheCrimsonMoon`, `:Flushed:_Pumpkinity`, `Snowy Egg`) |
  | `Equipped _None_` | 23 | in the world, no aura (briefly, right after joining) |
  | `In Main Menu` | 23 | on the title screen, **not in the game yet** |

- The game repeats identical lines, often 2 to 4 in the same millisecond. Dedupe on content.
- A line with a new biome is a biome change. The first biome after joining was already running, so its start time is unknown.
- **Used for:** Biome Radar, Aura Watch, the Main-Menu Sentinel.

### 2. A real aura roll: game event
```
[FLog::CreatorOutput] [_MAPIEvent][v1/event/invoke] <base64>
```
The base64 text decodes to JSON:
```json
{"gameEvent":{"eventId":"aura_rolled","eventName":"Aura Rolled: \"Symphony\"","triggerActions":["SaveClip"],"clipOptions":{"captureDelayMs":15000,"duration":34.23}},"universeId":5361032378}
```
- `eventName` carries the aura's **display name** in quotes. `clipOptions.captureDelayMs` is when the game itself saves its clip (the cutscene's best moment) and `duration` is the cutscene length in seconds.
- Seen **once** in a day of logs, for a roll that plays a cutscene. Ordinary rolls did not produce it, so this is "a roll worth a clip", not "every roll". The equip line for the new aura follows after the cutscene.
- Decode defensively: tolerate missing padding, unknown `eventId`s and missing `clipOptions`.
- **Used for:** the Aura Roll Feed (announcement plus a screenshot taken at `captureDelayMs`), and the Cutscene Lock (no synthetic input for `duration` seconds).

### 3. Heartbeat
```
[FLog::Output] Settings Date timestamp is 1795004117
```
- Written every **120 s** while the client is alive (176 gaps measured: minimum 120.1 s, maximum 124.2 s). A companion line `Settings Date header was <date> GMT` comes with it.
- **Used for:** the Freeze Watchdog. No new log line for 6 minutes (three missed heartbeats) while a game window exists means the client is frozen.

### 4. Joining a server
```
[FLog::GameJoinUtil] GameJoinUtil::joinGamePostPrivateServer: URL: https://gamejoin.roblox.com/v1/join-private-game BODY: {…}
[FLog::Output] ! Joining game '<jobId>' place 15532962292 at <ip>
[FLog::Network] serverId: <ip>|<port>
[FLog::GameJoinLoadTime] Report game_join_loadtime: … join_time:1.42, referral_page:RequestPrivateGame, …
```
- `join-private-game` in a `GameJoinUtil` line means a **private server** join. `join-reserved-game` (below) is a teleport. Neither present means a public join.
- `! Joining game '<jobId>' place <placeId>`: the server instance and the place. Place **15532962292** is Sol's RNG; Rich Presence from any other place is ignored.
- The `BODY` contains the private server's access code and the other lines contain an IP address and the user id. **Only** the join kind, the first 8 characters of the job id and the port-free "server changed" fact are kept.
- **Used for:** the Session Inspector (private or public, short job id, joined-at time), and rejoin verification.

### 5. Session state and teleports
```
[FLog::SessionTransitionFSM] Entered play session.
[FLog::SessionTransitionFSM] Teleported.
[FLog::SessionTransitionFSM] Tearing down.
[FLog::GameJoinUtil] GameJoinUtil::initiateTeleportToReservedServer: URL: https://gamejoin.roblox.com/v1/join-reserved-game …
[FLog::SingleSurfaceApp] setStage: (stage:UGCGame)      (or stage:Native for the Roblox home app)
```
- Sol's RNG moves the player to a fresh reserved server on a timer (the on-screen "left until rejoin" countdown). In the log that is a `join-reserved-game` request, `Teleported.`, and a new `! Joining game` line **inside the same log file**. It is normal and is not a disconnect.
- `Tearing down.` ends a play session (leaving, teleporting or quitting).
- **Used for:** the Session Inspector's teleport and rejoin counters; a teleport ends the current biome as "lost track" without raising an incident.

### 6. Daily reset
```
[FLog::CreatorOutput] daily reset time 1795046400
```
- A Unix time printed by the game after joining: the next daily reset (00:00 UTC).
- **Used for:** the Daily Reset Countdown.

### 7. Client version and updates
```
[FLog::UpdateController] version response: {"version":"0.745.100.7450979","clientVersionUpload":"version-…","bootstrapperVersion":""}
[FLog::UpdateController] Update check thread: updateRequired FALSE
[FLog::ClientRunInfo] The channel is <channel>
```
- The running version is the prefix of the log file name; `version response` is what the update server offers. `updateRequired TRUE` means an update is pending and the next launch will install it.
- **Used for:** Client Update Watch ("Roblox updated to X", "update pending").

### 8. Window size
```
[FLog::Graphics] SceneManager: resizing main targets to 960x921
```
- The size of the render area in pixels, written at start and on every resize.
- **Used for:** Window Guard (too small for reliable OCR), together with the window bounds from the window server.

### 9. Disconnects
```
[FLog::Network] Disconnect reason received: <N>
[FLog::Network] Disconnection Notification. Reason: <N>
[FLog::Network] Sending disconnect with reason: <N>
Connection lost
```
- These are the patterns other macros use. **None appeared** in a day of logs here (no real network loss happened), so their wording on macOS is unconfirmed.
- These lines are **not** disconnects and are ignored: `[DFLog::SignalRCoreError] ID: 1 Disconnected - stop() called` (every healthy launch), `[DFLog::NetworkClient] Client:Disconnect` and `Time to disconnect replication data` (normal leave or teleport), `[FaceAnimatorService] … disconnecting video stream`.
- **Used for:** the health monitor, with a 20 s grace period for the game's own teleport.

### 10. Merchants
- The arrival notice (`[Merchant]: Mari has arrived on the island...`) is shown in the game chat. It was **not** written to the log when a merchant came. SiverSol reads it from the chat area of the window instead, and also accepts the line in the log should a future version write it.

## Seen, not used yet

| Line | Count | Notes |
|---|---|---|
| `[FLog::RBThermalStateLogger] Thermal state: Nominal` | 5 | The client's own view of thermal pressure. SiverSol reads the system's thermal state directly. |
| `[FLog::Graphics] Metal renderer: <chip>` / `Apple ProMotion is: disabled` | 5 each | Hardware facts. |
| `[FLog::Output] Server RobloxGitHash: …`, `[FLog::ClientRunInfo] RobloxGitHash: …` | 7 / 9 | Server and client build hashes. |
| `[FLog::Output] AnalyticsSessionId is <uuid>.` | 7 | One per play session. An identifier; never shown. |
| `[FLog::SessionTransitionFSM] Session history: IASPT` | 13 | A letter per state: I initialized, A app, S success, P play, T teleport. |
| `[DFLog::DMNotificationMonitor] DM notification received. Type 10` (also Type 28) | 18 | Unknown notification types. |
| `[FLog::AppMemUsageStatus] <number>` | 29 | Fixed values (for example 923286370), not megabytes. Not a memory reading; SiverSol measures the process itself. |
| `[DFLog::PerformanceControlMemoryBudget] Harmony memory (MB): freeOs=… used=…` | 4 | The engine's memory budget, written rarely. |
| `[FLog::CreatorWarning] Warning: [ReplicaIY] …PrivateServerUI:121` | 923 | Game script noise; the most common line of all. |
| `[FLog::CreatorOutput] Effects active!`, `updated`, `packet sent`, `Hello World! CLI-…` | many | Game and engine debug prints. |
| `[FLog::CreatorError] Error: Failed to load sound …` | 42 | Asset moderation noise. |
| Other `_MAPIEvent` event ids | 0 | Only `aura_rolled` has been seen. Unknown ids are recorded by the Log Lab, not acted on. |
| Other `state` values in Rich Presence | 0 | Anything that is not one of the three known shapes is recorded by the Log Lab. |

## Adding a signal

1. Add the pattern here, with a redacted example and what it is for.
2. Add it to `LogLineParser` and to `LogSanitizer`'s whitelist, with placeholders for anything personal.
3. Add a sanitized line to a fixture and a parser test.
