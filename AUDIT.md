# ConsoleX (CNSX) audit: 1.5.1 → 1.5.2

ConsoleX is a Garry's Mod addon that gives superadmins an in-game Lua IDE. They unlock it with a master password and can then run code on the server or on clients and browse and edit files.

The upload is in the first commit, unchanged. Each later commit is one audit round, so `git diff <first commit>` shows everything the audits changed.

**How it was checked:** I read every file by hand. I ran every file through LuaJIT (`luajit -bl`), which is the Lua runtime GMod uses, to check that it compiles. I ran a GMod API checker over all the code to catch misspelled or nonexistent functions. Finally, I ran a smoke test of the server logic in plain LuaJIT, with fake versions of the GMod functions. It covered first-time setup, a wrong password, unlocking, session expiry, upgrading an old password hash, the `cnsx_setpass` fix, `run_sv`, refusals for non-superadmin targets, and refusals for non-admin senders. Nothing was tested on a live server.

**Round 3 (full functional audit):** I read every line of the client UI against the base-game Derma source (`DFrame`, `DComboBox`, `DHTML`, `DHorizontalScroller`, `DListView`) and the wiki. I then wrote `tests/cnsx_e2e.lua`. It loads the real server files and the real client files into two separate simulated GMod environments, connects them with a fake network, and clicks through the IDE. It has 40 checks: unlock, run, save, list, open, Cmd, client pushes, Inc, the log click, tabs, close and reopen, expiry, minimize and maximize, and the password commands. Run it with `luajit tests/cnsx_e2e.lua` from the repo root. Against the code from before round 3, it fails at the first unlock step, because the password prompt never appeared.

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
| 13 | **High** | **Changing the root or player dropdown threw a Lua error** (`attempt to index global 'listBtn'`). The dropdown handlers were created before `local listBtn` was declared, so they looked up a global that doesn't exist. This was already in 1.5.1. | `listBtn` is now declared before the handlers that use it. A scan of every global the addon reads found no other cases. |

### Round 3: does each feature actually work?

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 14 | **Critical** | **Nobody could unlock the IDE.** `consolex` opened the window *before* authenticating. The client then ignored every "please unlock" reply because a window was already open. The password prompt was only ever shown to players who were *denied*. | `consolex` now only asks the server. The server answers with the IDE (when already unlocked) or the prompt. "Deny" just prints the chat message. An expired session brings the prompt back over the IDE. |
| 15 | **Critical** | **Run and Save sent stale text.** The JS bridge that reads the editor (`cnsx.code`) was registered before the page loaded, and the wiki says that doesn't work. After 0.25 s, `pullBody` fell back to the tab's last *stored* body, not what you had typed. Tab bodies were also pushed into the editor before it loaded, so they were lost. | The bridge is registered in `OnDocumentReady`, which then loads the active tab. Editor JS isn't sent before the page is ready. |
| 16 | **High** | **Saving `.lua` always failed.** `file.Write` refuses `.lua` (and the default save path was `consolex/scratch.lua`). The server reported success based on whether the file *already existed*. | Added the shared `CNSX.WriteData`: unsupported extensions get `.txt` appended (`test.lua` becomes `test.lua.txt`), and the real result and final path are reported. The default path is now `scratch.txt`. Saving while browsing GAME or LUA says it writes a copy to DATA. |
| 17 | **High** | **The Cmd button ran the file path as a console command.** It used the path box, which nearly always holds a file path. | It runs the first non-empty, non-comment line in the editor. |
| 18 | Medium | **Ctrl+F, Ctrl+G and Esc never worked.** `PlayerButtonDown` doesn't fire while a panel has keyboard focus, which is always the case in the IDE. | Ace key bindings forward these to Lua through `cnsx.hotkey`. The dead hook is removed. |
| 19 | Medium | **The window couldn't be resized.** `CNSXFrame` replaced `DFrame`'s mouse handlers, so the resize corner showed the resize cursor but did nothing. | Presses on the bottom-right corner are passed to `DFrame`. |
| 20 | Medium | **The minimized bar hijacked the mouse.** It kept the mouse captured, and every frame it forced the screen cursor off (`gui.EnableScreenClicker`). That fought the context menu, scoreboard and other addons. Clicking Maximize while minimized left it half-minimized. Re-running `!cnsx` didn't restore it. | The bar only accepts clicks while the C menu is open. It never touches the screen cursor. Maximize and `!cnsx` restore it properly. |
| 21 | Medium | **Clicking an error in the log jumped to the wrong line.** Every log line starts with `HH:MM:SS`, so the error-line parser read the minutes as the line number. | The timestamp is stripped before parsing. |
| 22 | Medium | **Password typed in plain sight** (on screen or on stream). | The lock dialog draws `*` instead of the text. |
| 23 | Low | **Dropdowns drew their text twice** (the built-in label plus a custom `Paint`, in different fonts) and showed two arrows. | `Paint` now only draws the background. |
| 24 | Low | **Typing in the first second after opening could be overwritten.** A redundant `loadtabs` request replaced tabs that had already arrived with `CNSX_Open`. | Removed it. |
| 25 | Low | Clicking the "(empty)" row navigated up a folder. Inc accepted the My DATA and Player DATA roots, which don't exist on the server. Refresh reset the chosen player. Successful remote saves were never reported. The log grew without limit. Closing the window right after reopening could close the new one. Clients that received code from "CL All" got no notice. | Each one is fixed. The log is capped at 24 KB, and receiving clients print a console line. |

## Risks you accept by design (not changed)

- **An unlocked session controls the whole server.** It can run any server Lua and any console command, and read `GAME` files such as `cfg/server.cfg`, which includes `rcon_password`. Per-file protection would be cosmetic, so the defenses are the superadmin gate, the master password, and now the audit log.
- **The first superadmin to open CNSX sets the master password.** Set it from the server console with `cnsx_setpass` before giving anyone superadmin.
- **The password crosses the network in plain text** (GMod network messages are not encrypted). Typing `cnsx_setpass` in-game also leaves it in your console history. Prefer the server console.
- **Logins are limited to one attempt per 0.5 s per player.** Extra requests are silently ignored.
- **The editor loads Ace from cdnjs.** It needs internet access, and that CDN is trusted. Lua access is turned off inside the HTML panel (`SetAllowLua( false )`).
- **Anyone with Lua access can edit or delete the audit log.** It catches mistakes and careless misuse; it does not stop a determined admin.

## Not changed / notes

- The checker found no unknown APIs, realm mismatches or unregistered network messages.
- Style was left as written. Changes were kept to the fixes above.
- Version bumped to 1.5.2 in `addon.txt` and `sh_core.lua`.
- **Not verified:** these need a real client to confirm. The cdnjs Ace file names (`ace.js`, `ext-language_tools.min.js` at 1.32.6; the CDN was blocked from where I tested). The Ace key bindings. How anything actually looks on screen. The simulated environment checks the logic and the network flow, not Derma rendering or the browser.
