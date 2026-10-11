# ConsoleX (CNSX) audit: 1.5.1 → 1.5.2

ConsoleX is a Garry's Mod addon that gives superadmins an in-game Lua IDE. They unlock it with a master password and can then run code on the server or on clients and browse and edit files.

The upload is in the first commit, unchanged. The fixes are in the second commit, so `git diff HEAD~1` shows everything this audit changed.

**How it was checked:** I read every file by hand. I ran every file through LuaJIT (`luajit -bl`), which is the Lua runtime GMod uses, to check that it compiles. I ran a GMod API checker over all the code to catch misspelled or nonexistent functions. Finally, I ran a smoke test of the server logic in plain LuaJIT, with fake versions of the GMod functions. It covered first-time setup, a wrong password, unlocking, session expiry, upgrading an old password hash, the `cnsx_setpass` fix, `run_sv`, refusals for non-superadmin targets, and refusals for non-admin senders. Nothing was tested on a live server.

## Findings

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | **Critical** | `sv_core.lua` **did not compile.** `until` is a reserved Lua keyword, so `{ until = ... }` and `row.until` are syntax errors. The whole server half of the addon never loaded. Every button timed out with "no server reply". | Renamed the field to `expires`. |
| 2 | **High** | **`cnsx_setpass` skipped the master password.** Any superadmin could type `cnsx_setpass x` in their console and replace the password without ever unlocking. `cnsx_clearpass` already required an unlock; `setpass` did not. | In-game use now requires an unlocked session. The server console still works. Changing the password also signs out every other session. |
| 3 | **High** | **Remote file access to any player's computer.** `remote_list`, `remote_read` and `remote_write` let an admin list, read and *overwrite* files in any connected player's `garrysmod/data` folder, without the player knowing. That folder holds data saved by other servers and addons. The client code also accepted a `game` root, which would expose the player's whole game install. | Targets must now be superadmins. That matches the existing rule for running code on a client (the client only runs CNSX code if it is a superadmin). The client checks this too and only serves `DATA`. |
| 4 | **Medium** | **"On Ply" reported false successes.** `run_ply` sent code to any player and replied "sent to X". The player's game silently ignored it unless they were a superadmin. | The server now refuses non-superadmin targets and says why. |
| 5 | **Medium** | **Non-admins could make the server parse large JSON.** `CNSX_Cmd` decoded up to about 62 KB of JSON before checking who sent it. Any player could repeat this every 0.05 s. `CNSX_RemoteOut` decoded first and checked afterward. `CNSX_Auth` had no rate limit. | Permissions are checked before anything is decoded. `RemoteOut` is only decoded when a matching request is waiting. Unlock attempts are limited to one per 0.5 s. |
| 6 | **Medium** | **No record of who ran what.** Nothing logged server code runs, client code pushes, console commands, file writes, unlocks or password changes. | Added `CNSX.Audit`. Each action is written to `ServerLog` and to `data/consolex/audit/YYYY-MM-DD.txt`, with the player's SteamID64 and the full code. |
| 7 | **Medium** | **Weak password storage.** The password was hashed with a single salted SHA-256. If `auth.json` leaked, the password could be guessed at high speed. | Hashes are now repeated 10,000 times (stored as version 2). Old hashes still work and are upgraded the next time someone unlocks. |
| 8 | Low | **Two copies of the unlock code** (`CNSX_Auth` and `CNSX_Cmd act=auth`) had already drifted apart. | Both now call one `handleAuth` / `sendStatus`. |
| 9 | Low | **`CNSX.SetCode` doubled every backslash.** It escaped backslashes and backticks by hand, then JSON-encoded the result. The function is currently unused, but it would corrupt files on every load and save. | Removed the manual escaping. |
| 10 | Low | **Server-console crash.** Typing `cnsx` in the server console indexed a NULL player. | Added a guard. |
| 11 | Low | **Client error on an empty player list** (`data.rows[1]` when `rows` is nil). | Added a guard. |
| 12 | Low | **Stale entries on disconnect.** The disconnect hook used a different session key than the rest of the code, and left remote requests pending. | Uses the same key everywhere and clears pending remote requests. |

## Risks you accept by design (not changed)

- **An unlocked session controls the whole server.** It can run any server Lua and any console command, and read `GAME` files such as `cfg/server.cfg`, which includes `rcon_password`. Per-file protection would be cosmetic, so the defenses are the superadmin gate, the master password, and now the audit log.
- **The first superadmin to open CNSX sets the master password.** Set it from the server console with `cnsx_setpass` before giving anyone superadmin.
- **The password crosses the network in plain text** (GMod network messages are not encrypted). Typing `cnsx_setpass` in-game also leaves it in your console history. Prefer the server console.
- **The editor loads Ace from cdnjs.** It needs internet access, and that CDN is trusted. Lua access is turned off inside the HTML panel (`SetAllowLua( false )`).
- **Anyone with Lua access can edit or delete the audit log.** It catches mistakes and careless misuse; it does not stop a determined admin.

## Not changed / notes

- The checker found no unknown APIs, realm mismatches or unregistered network messages.
- Style was left as written. Changes were kept to the fixes above.
- Version bumped to 1.5.2 in `addon.txt` and `sh_core.lua`.
