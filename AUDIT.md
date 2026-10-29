# ConsoleX (CNSX) 1.6.0 audit

ConsoleX is a Garry's Mod addon that gives superadmins an in-game Lua IDE. They unlock it with a master password. Then they can run code on the server or on clients, and browse and edit files.

This round started from the uploaded 1.5.2, which added an **autosave** feature on top of the last audited version. The upload is committed unchanged ("Import ConsoleX 1.5.2 upload"), so `git diff` from that commit shows this round's changes.

## How it was checked

- **I read every file in full**, and compared the Derma/DHTML code with the base-game source (`dhtml.lua`, `dlistview.lua`, `dtextentry.lua`, `util.lua`).
- **Compile and API checks:** every file compiles under LuaJIT, the Lua runtime GMod uses. A GMod API checker found no unknown functions, realm mistakes or unregistered network messages. I looked up every new API call against the wiki mirror.
- **`tests/cnsx_e2e.lua` (112 checks).** This test loads the real server file and the real client files into simulated GMod environments: one server and three clients (two superadmins and one ordinary player). A fake network connects them, and the test clicks through the IDE. Run it with `luajit tests/cnsx_e2e.lua`.
- **`tests/editor_page.js` (49 checks).** This test loads the real editor page in headless Chromium, using the same Ace 1.32.6 build the addon loads from cdnjs (taken from npm). It checks GLua highlighting, autocomplete, shortcuts, the Lua bridge, find/replace, prefs and the offline fallback. The steps to run it are at the top of the file.
- **An independent review pass** read the finished code from scratch. Its findings are listed below and were fixed, with a regression check for each. Where I could, I confirmed a check fails when its fix is reverted.
- **Not tested on a live server.** The harness simulates GMod. How things look on screen, and Chromium-in-GMod quirks, still need a real client.

## Bugs in the uploaded autosave

| # | Severity | Issue |
|---|----------|-------|
| A1 | **Critical** | **It broke Run and Save.** It registered `cnsx.onChange` from a `Think` hook on the first frame, before the page had loaded. The base-game `DHTML:AddFunction` marks the `cnsx` object as created on the first call. So the real bridge (`cnsx.code`) registered later in `OnDocumentReady` never got created in the page. Run, Save and Check then fell back to the tab's *last stored* text, not what you had typed. This is the same bug round 3 fixed. |
| A2 | **Critical** | **Every autosave threw a Lua error.** `doAutosave` called `comboData`, which is declared further down the file. At that point the name looks up a global that doesn't exist. |
| A3 | **High** | **Opening a file wrote files.** Loading text into the editor fires Ace's change event, so simply *viewing* a file triggered a save. Opening `cfg/server.cfg` from GAME would have written a copy to `DATA/cfg/server.cfg.txt`, including `rcon_password`. Viewing any `.lua` file would have created a `.lua.txt` copy next to it. |
| A4 | **High** | **It saved to the wrong place.** It used the Browse dropdown's *current* root, not the tab's own. A tab opened from Player DATA (another admin's PC) was written to server DATA. A server file was written to your own PC if you had switched Browse to My DATA. |
| A5 | Medium | **It cancelled clicks.** It shared the single editor-read callback slot, so an autosave firing right after you clicked SV Run silently replaced the Run's callback. Nothing ran. |
| A6 | Low | It sent every tab (up to 62 KB) to the server on every autosave, and left a `Think` hook running every frame forever. |

Autosave has been rebuilt. Every tab is kept as a **local draft** about 1.5 s after you stop typing. The drafts are backed up to the server when you close the window, and once a minute while something has changed. **Writing the actual file is opt-in** (Prefs → Autosave files, off by default). It only ever writes the tab's *own* file, in server DATA or My DATA. It never writes a GAME, LUA or player file, and it only writes when the text actually differs from the last save.

## Bugs found in the existing code

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | **High** | **Closing a tab overwrote the next tab.** `closeTab` removed the tab, then read the editor text into `tabs[active]`. After the removal, that index points at the next tab. So closing a tab replaced its neighbour's contents with the closed tab's text. | The editor text is read first, then the tab is removed and the active index adjusted. Each tab now has its own Ace session, so undo history and cursor position survive tab switches. |
| 2 | **High** | **Save wrote to whatever the Path box said.** Clicking a folder in the file list (the Path box became `consolex/sub`) and then pressing Save wrote the tab to `consolex/sub.txt` and renamed the tab. | Save writes the tab's own file. Unsaved tabs, and GAME/LUA tabs, open **Save As**, which asks for a path. The tab then follows the real saved name (e.g. `x.lua.txt`). Remote tabs remember which player they came from. |
| 3 | **High** | **Clicks were silently dropped.** The server ignored any command less than 0.05 s after the previous one. Opening the IDE sends three at once, so the player list was always dropped. Refresh sent two, so the file list was dropped. | Replaced with a token bucket: bursts of up to 40 go through, refilling at 20/s. Non-admins are still rejected before anything is read. |
| 4 | **High** | **Large code or files failed silently.** Messages were plain JSON capped at 62 KB, and JSON escaping roughly doubles code full of quotes and newlines. Anything over the cap was replaced by `{"err":...}` *without* the action name, so the server ignored it. 40 KB of code could just not run. Files over 62 KB opened truncated, and saving them truncated the file on disk. | Payloads are now compressed with LZMA (`util.Compress`; typical Lua code shrinks 4–6×). The receiver caps decompression at 2 MB (`util.Decompress` `maxSize`). Anything that still doesn't fit is **reported** ("run_sv not sent: payload too large"). Files over 512 KB open **read-only** and can't be saved back truncated. Binary files are refused. |
| 5 | Medium | **`!=`, `//`, `&&`, `continue` and other GLua syntax showed red error markers.** Ace's Lua checker only understands plain Lua 5.1. | Ace's checker is turned off. A GLua highlighting mode was added. Syntax errors now come from GMod's own `CompileString`, run locally as you type (it compiles only and never runs anything). |
| 6 | Medium | **Autocomplete inserted `player.player.GetAll`.** The completer matched the whole `player.GetAll` against the word after the dot and inserted all of it. | The completer reads what is before the cursor. `lib.` offers that library's functions and `obj:` offers methods. |
| 7 | Medium | **Inconsistent rule for receiving client code.** An `owner` or `root` group could open the IDE, but its client refused code pushed to it (the client checked only `IsSuperAdmin`). | One rule (`CNSX.Allowed`) is used everywhere: by the server's target checks, and by the client before running pushed code or serving its files. |
| 8 | Medium | **The overhead banner drew in the skybox and depth passes**, and allocated colors every frame. It also kept retrying a missing material every frame. | It skips the depth and skybox passes and dormant players. Colors and the material are cached. |
| 9 | Low | The `cnsx_session_min` convar was created on clients too, where it is meaningless. Closing the window saved the stored tab text, not the live editor text. The list silently stopped at 160 entries. | Fixed. The list now goes up to 1000 entries and says when it is cut off. |

## Independent review findings (fixed)

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| R1 | High | **A remote target could forge its reply.** The server forwarded whatever another superadmin's client sent back for a Player DATA request, and that is a client which never typed the master password. It could set `tabId` to re-point one of your tabs (for example a server file) at "remote", so your next Ctrl+S would send that file's text to them. It could also attach a `body` to a listing to open a tab of its choosing, or send malformed rows that threw errors in your client. | Each remote request has a server-side id. The server remembers the action, path and tab, and rebuilds the reply from only the fields that action allows, type-checked. The client only accepts a save result for a tab that is waiting on a save *to that player*. |
| R2 | Medium | Remote requests had one slot per admin, with no id. A save reply could be dropped while a listing was pending, and two admins using the same target could receive each other's replies. | Covered by R1's request ids. |
| R3 | Medium | Editor text was assigned to whichever tab was active *when the reply arrived*. Closing or switching tabs while a read was in flight could put one tab's text into another, and with autosave on, into another file. | Each read is bound to the tab that was showing when it was requested. The reply carries a sequence number, and stale replies are dropped. Tab selection goes by tab, not index. |
| R4 | Medium | A partial server backup (large tabs left out) could replace newer local drafts after a map change, losing the large tabs. | Backups carry the draft's own timestamp and a `partial` flag. Partial backups never replace local drafts. |
| R5 | Medium | A slow Player DATA listing could arrive after you had switched to Server DATA and repaint the list with the other player's files. Right-click Delete/Rename would then act on server paths with those names. | Listings carry a sequence number; only the newest one fills the list. |
| R6 | Low | "New file here" overwrote an existing file with an empty one. | It refuses when the file exists, both locally and on the server. |
| R7 | Low | Autosave on a `.cfg`/`.lua`/`.ini` file in DATA created `name.cfg.txt` and re-pointed the tab there. | Autosave skips files `file.Write` can't save under their own name. |
| R8 | Low | Read-only (truncated) tabs could still be typed in. | The editor itself is read-only for those tabs. |
| R9 | Low | A case-insensitive `re:` search lowercased the pattern, so `%S` became `%s`. | Pattern searches are always case-sensitive. |
| R10 | Low | The idle-lock countdown used the time left at open, not the idle window, and ignored the 12 h cap. | The server sends the idle window and the hard cap; the client counts down from its last command. |
| R11 | Low | A pending "close after save" stayed set if the save was never sent, so a later save closed the tab. | It is cleared on every path where the save doesn't go out. |

**Not changed (your call):** the reviewer suggested adding subresource-integrity hashes to the two Ace `<script>` tags. Anything running in the editor page can ask Lua to run the editor text on the server, so a tampered cdnjs file would be dangerous. I couldn't fetch the cdnjs files from here to confirm their hashes. A wrong hash would block Ace for every admin, leaving only the plain editor. Adding it is a two-line change once the hashes are taken from cdnjs.

## Security review

Users are trusted owners/superadmins, so "an unlocked admin can run any Lua" is by design. What matters is that **nobody else** can get in, and that one admin's session can't be faked by another client.

| # | Area | Change |
|---|------|--------|
| S1 | Network | Every network message is checked for permission **before** it is decompressed or decoded. Decompression is capped (2 MB), so a decompression bomb can't fill memory. Malformed packets are ignored, and the tests send garbage to prove it. |
| S2 | Client results | The new "client replies" (CL All / On Ply output coming back) are only accepted from players the server actually sent that code to, for that run id, within 30 s. Anything else is dropped: unsolicited replies, replies from non-admins, replies to old runs. |
| S3 | Passwords | A **new** master password must be 8+ characters. Old shorter passwords still unlock. Lockouts (5 bad tries → 30 s) are now written to the audit log. |
| S4 | Sessions | The fixed 45-minute unlock is now an **idle** timeout (`cnsx_session_min`, 5–240 min) with a hard 12 h cap. A **Lock** button ends your session immediately. `cnsx_lockall` (server console only) ends everyone's. |
| S5 | Remote files | When an admin lists, opens or writes another superadmin's DATA, that player gets a chat line saying who did it and what. |
| S6 | Editor page | Completion names from `_G` are filtered to plain identifiers, and completion docs are HTML-escaped. All Lua→JS values go through JSON encoding. The F1 wiki link only accepts `[A-Za-z0-9_.:]`. Lua access in the HTML panel stays off. |
| S7 | Audit log | Delete, rename and mkdir, autosaves (tagged), session lock and lockouts are now logged, in addition to everything logged before. |

**Risks you accept by design (unchanged):** an unlocked session controls the whole server. It can read `GAME/cfg/server.cfg` (`rcon_password`) and run console commands. The master password crosses the network unencrypted, because GMod net messages are not encrypted. The first superadmin to open CNSX sets the password, so set it from the server console (`cnsx_setpass`) first. The editor loads Ace from cdnjs; if that is blocked, a plain-text editor takes over. Anyone with Lua access can edit or delete the audit log.

## New IDE features

**Running code**
- `print`/`Msg`/`MsgN`/`MsgC`/`ErrorNoHalt` output is captured into the log (it still reaches the console too).
- Return values are shown, and tables are pretty-printed (3 levels, capped).
- Errors include a stack trace and mark the line in the editor.
- **Run selection:** with text selected, Run/Check use only the selection (can be turned off in Prefs).
- **CL All / On Ply / Both report back:** each client's result and output appears in your log as `client <name>`.
- **Quick Lua line** under the log: an expression shows its value, a statement just runs. SV/CL toggle, Up/Down history.
- **Run history** (Hist): the last 40 runs, saved locally; pick one to open it in a tab.
- **Live error feed:** Lua errors on the server (for example from a hook your code added) appear in open IDEs, rate-limited and de-duplicated. Turn it off with `cnsx_error_feed 0`. Client errors appear in your own log.

**Editor**
- GLua highlighting: `//` and `/* */` comments, `!=`, `&&`, `||`, `!`, `continue`.
- Live syntax check using GMod's own compiler.
- Autocomplete built from the **real** API of both realms, tagged SV/CL/SH. `lib.` lists its functions, `obj:` lists methods with their class, and local words, Lua keywords and GLua snippets (`hook`, `netr`, `nets`, `timer`, `ccmd`, `forp`, `trace`, `frame`…) are included.
- **F1** opens the wiki page for the word under the cursor (`hook.Add`, `ply:Nick` → `Player:Nick`).
- Undo history and cursor position kept per tab. Unsaved tabs show `*`, and closing one asks Save / Discard / Cancel.
- Find/replace with match-case, regex and whole-word toggles, and a match count.
- Status bar: file, Ln/Col, modified, syntax error, and the idle-lock countdown.
- Prefs: font size, theme (8 dark themes), word wrap, live syntax check, run selection, autosave files.
- If cdnjs can't be reached, a plain-text editor with the same shortcuts takes over, and the log says so.

**Keyboard shortcuts:** Ctrl+Enter run on server · Ctrl+Shift+Enter run on own client · Ctrl+S save · Ctrl+Shift+S save as · Ctrl+F find · Ctrl+G go to line · Ctrl+T new tab · Ctrl+W close tab · Ctrl+Tab / Ctrl+Shift+Tab switch tabs · Ctrl+/ comment · F1 wiki · Esc closes find.

**Files**
- Right-click the file list for Open, Run on server, Copy path, Rename/move, Delete (with confirmation), New file, New folder, and Find in files. Writing is limited to server DATA and My DATA, and the server versions are audited.
- **Find in files** (Grep button or right-click) searches server DATA, GAME or LUA, or My DATA. It runs a few milliseconds per tick, so a big search never freezes the server. It is capped at 6000 files and 300 hits. Prefix the search with `re:` for a Lua pattern or `cs:` for case-sensitive. Click a hit to open the file at that line.
- The file list shows sizes, and a file path in the Path box lists its folder.

**New console commands / convars:** `cnsx_lockall` (server console), `cnsx_error_feed` (0/1). `cnsx_session_min` is now the idle timeout.

## Known limits

- An infinite loop in server code still freezes the server. LuaJIT doesn't run debug hooks inside compiled loops, so there is no reliable way to time out a run.
- `Cmd` output goes to the server console. GMod gives Lua no way to capture it.
- Find in files skips files over 1 MB and only searches text extensions (`lua`, `txt`, `json`, `cfg`, …).
- The server backup of tabs skips any tab over 32 KB. Those stay in the local drafts on that PC, and the log says so once.

---

# Earlier rounds: 1.5.1 → 1.5.2

ConsoleX is a Garry's Mod addon that gives superadmins an in-game Lua IDE. They unlock it with a master password and can then run code on the server or on clients and browse and edit files.

The upload is in the first commit, unchanged. Each later commit is one audit round, so `git diff <first commit>` shows everything the audits changed.

**How it was checked:** I read every file by hand. I ran every file through LuaJIT (`luajit -bl`), which is the Lua runtime GMod uses, to check that it compiles. I ran a GMod API checker over all the code to catch misspelled or nonexistent functions. Finally, I ran a smoke test of the server logic in plain LuaJIT, with fake versions of the GMod functions. It covered first-time setup, a wrong password, unlocking, session expiry, upgrading an old password hash, the `cnsx_setpass` fix, `run_sv`, refusals for non-superadmin targets, and refusals for non-admin senders. Nothing was tested on a live server.

**Round 3 (full functional audit):** I read every line of the client UI against the base-game Derma source (`DFrame`, `DComboBox`, `DHTML`, `DHorizontalScroller`, `DListView`) and the wiki. I then wrote `tests/cnsx_e2e.lua`. It loads the real server files and the real client files into two separate simulated GMod environments, connects them with a fake network, and clicks through the IDE. It now has 44 checks: unlock, run, save, list, open, Cmd, client pushes, Inc, the log click, tabs, close and reopen, expiry, minimize and maximize, and the password commands. Run it with `luajit tests/cnsx_e2e.lua` from the repo root. Against the code from before round 3, it fails at the first unlock step, because the password prompt never appeared.

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

### Round 4: UI / UX

| # | Issue | Fix |
|---|-------|-----|
| 26 | **The Browse and Player dropdowns were effectively invisible until clicked.** Their background (34,34,40) was almost the same as the panel behind them (24,24,28), with no border, and the readable text depended on the skin. | They're now fully drawn by CNSX: a dark field with a border that turns blue on hover, the selected text (or a grey "pick a player..." prompt), and a chevron that flips when open. |
| 27 | Unlabelled controls: two unnamed dropdowns and a "path" box. | Added small captions: *Browse*, *Target player (Player DATA / On Ply)*, *Path (Enter to list)*. Added tooltips on every dropdown and button. |
| 28 | The Browse list was sorted alphabetically, so "My DATA" came first. | Kept in logical order: Server DATA / GAME / LUA, then My DATA, Player DATA. |
| 29 | Short labels with no explanation: "CL Me", "On Ply", "Both", "Inc", "Cmd". | Each action has a tooltip. The ones that reach other people or the console (CL All, Both, Cmd) use the darker "danger" style. |
| 30 | Clicking a file twice opened duplicate tabs. | It switches to the tab that's already open and says so in the log. |
| 31 | Closing a tab only worked with an undocumented right-click. | The tab tooltip shows its location and path and says "right-click or middle-click to close". Middle-click also works now. |
| 32 | The editor stayed in Lua highlighting for JSON, HTML and other files. | The highlighting follows the active tab's file type. |
| 33 | Errors in the log looked the same as successes (the "bad" flag was ignored). | Failure lines get a `[!]` prefix. |
| 34 | Pressing Enter in the path box did nothing. | Enter lists that folder. |
| 35 | A ".." row showed at the top level. | It's hidden when there's no parent folder. |
| 36 | A window resized by dragging went back to the old size next time. | The size is saved when you close it. |
| 37 | Every action played a click *and then* a pass/fail sound. | Only the pass/fail sound plays. |
| 38 | The header said "owner", including on the preferences window. | It shows the version, and the preferences window says "preferences". |

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
