if not CLIENT then return end

-- tab mode -> Ace mode. "lua" uses the GLua mode built in the page (GLua operators/comments, no luaparse worker)
CNSX.Modes = {
    lua = "glua",
    glua = "glua",
    js = "ace/mode/javascript",
    html = "ace/mode/html",
    css = "ace/mode/css",
    json = "ace/mode/json",
    xml = "ace/mode/xml",
    txt = "ace/mode/text",
    md = "ace/mode/markdown",
    cfg = "ace/mode/text"
}

CNSX.Themes = { "twilight", "monokai", "tomorrow_night", "dracula", "one_dark", "github_dark", "nord_dark", "gruvbox" }

function CNSX.GuessMode( path )
    path = string.lower( tostring( path or "" ) )
    -- saved .lua files come back as name.lua.txt; keep Lua highlighting for them
    path = string.gsub( path, "%.lua%.txt$", ".lua" )
    local ext = string.GetExtensionFromFilename( path ) or ""
    if ext == "lua" then
        return "lua"
    end

    return CNSX.Modes[ext] and ext or "txt"
end

function CNSX.AceMode( mode )
    return CNSX.Modes[mode or "lua"] or "ace/mode/text"
end

local function editorPrefs( prefs )
    prefs = prefs or CNSX.Prefs or {}
    local theme = "twilight"
    for _, name in ipairs( CNSX.Themes ) do
        if prefs.theme == name then
            theme = name
        end
    end

    return {
        fontSize = math.Clamp( math.floor( tonumber( prefs.fontSize ) or 13 ), 9, 28 ),
        wrap = prefs.wrap ~= false,
        theme = theme
    }
end
CNSX.EditorPrefs = editorPrefs

-- The page talks to Lua only through the `cnsx` object that cl_ui.lua registers in OnDocumentReady:
-- cnsx.code(all, selection), cnsx.changed(), cnsx.cursor(line, col), cnsx.hotkey(name, arg), cnsx.info(text)
function CNSX.EditorHTML( prefs )
    local boot = CNSX.Encode( editorPrefs( prefs ) )

    return [==[<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
html,body{margin:0;height:100%;background:#0c0c0e;color:#eee;overflow:hidden;}
#ed{position:absolute;top:0;left:0;right:0;bottom:0;}
#fb{position:absolute;top:0;left:0;width:100%;height:100%;box-sizing:border-box;margin:0;border:0;padding:6px;background:#0c0c0e;color:#e6e6e6;font:13px Consolas,monospace;resize:none;outline:none;tab-size:4;-moz-tab-size:4;white-space:pre;overflow:auto;}
.ace_editor.ace_autocomplete{background:#161b28;border:1px solid #3a6ad4;color:#dce8ff;}
.ace_doc-tooltip{background:#161b28;color:#9ab4e0;border:1px solid #3a6ad4;padding:4px 6px;}
</style>
</head><body>
<div id="ed"></div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/ace/1.32.6/ace.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/ace/1.32.6/ext-language_tools.js"></script>
<script>
(function(){
var W = window;
var PREFS = ]==] .. boot .. [==[;
var MODES = {glua:1,"ace/mode/lua":1,"ace/mode/javascript":1,"ace/mode/html":1,"ace/mode/css":1,"ace/mode/json":1,"ace/mode/xml":1,"ace/mode/text":1,"ace/mode/markdown":1};

function call(name, a, b, c){ try { if (W.cnsx && cnsx[name]) { cnsx[name](a === undefined ? "" : a, b === undefined ? "" : b, c === undefined ? "" : c); } } catch (e) {} }
// messages raised before Lua has registered the bridge wait for cnsxReady()
var early = [];
function info(msg){ if (W.cnsx && cnsx.info) call("info", String(msg)); else early.push(String(msg)); }
W.cnsxReady = function(){ var q = early; early = []; q.forEach(info); };

var GMOD = [
  ["print","SH","Prints values to the console"],["MsgN","SH","Prints a line to the console"],["MsgC","SH","Colored console print"],
  ["PrintTable","SH","Recursively prints a table"],["ErrorNoHalt","SH","Prints an error without halting"],
  ["IsValid","SH","True if the object exists and is valid"],["CurTime","SH","Synced game time"],["RealTime","SH","Real uptime"],
  ["FrameTime","SH","Last frame delta"],["SysTime","SH","High precision timer"],["LocalPlayer","CL","The local player"],
  ["Entity","SH","Entity by index"],["Player","SH","Player by UserID"],["Vector","SH","Vector(x, y, z)"],["Angle","SH","Angle(p, y, r)"],
  ["Color","SH","Color(r, g, b, a)"],["CompileString","SH","Compile Lua; returns fn or error"],["RunString","SH","Compile and run a string"],
  ["include","SH","Run a Lua file"],["AddCSLuaFile","SH","Send a file to clients"],["FindMetaTable","SH","Metatable by class name"],
  ["player.GetAll","SH","All players"],["player.GetHumans","SH","All human players"],["player.GetBySteamID64","SH","Player from SteamID64"],
  ["ents.GetAll","SH","All entities"],["ents.FindInSphere","SH","Entities in a radius"],["ents.FindByClass","SH","Entities by class"],["ents.Create","SV","Create an entity"],
  ["hook.Add","SH","hook.Add(event, id, fn)"],["hook.Remove","SH","Remove a named hook"],["hook.Run","SH","Call a hook"],["hook.GetTable","SH","All hooks"],
  ["timer.Simple","SH","Run once after a delay"],["timer.Create","SH","Named repeating timer"],["timer.Remove","SH","Remove a named timer"],["timer.Exists","SH","Timer exists?"],
  ["net.Start","SH","Begin a net message"],["net.Send","SV","Send to player(s)"],["net.Broadcast","SV","Send to every client"],["net.SendToServer","CL","Client to server"],
  ["net.Receive","SH","Handle a net message"],["net.WriteString","SH","Write a string"],["net.ReadString","SH","Read a string"],["util.AddNetworkString","SV","Pool a net message name"],
  ["file.Find","SH","file.Find(glob, path)"],["file.Read","SH","Read a file"],["file.Write","SH","Write a DATA file"],["file.Exists","SH","File exists?"],["file.CreateDir","SH","Create a DATA folder"],
  ["util.TableToJSON","SH","Encode a table"],["util.JSONToTable","SH","Decode JSON"],["util.TraceLine","SH","Line trace"],["util.Compress","SH","LZMA compress"],
  ["concommand.Add","SH","Add a console command"],["CreateConVar","SH","Create a convar"],["GetConVar","SH","Get a convar object"],
  ["vgui.Create","CL","Create a panel"],["vgui.Register","CL","Register a panel class"],["surface.SetDrawColor","CL","2D draw color"],
  ["draw.SimpleText","CL","Draw aligned text"],["draw.RoundedBox","CL","Rounded rectangle"],["input.IsKeyDown","CL","Key currently down"],
  ["chat.AddText","CL","Colored chat line"],["team.GetName","SH","Team display name"],["game.GetMap","SH","Current map"],["engine.ActiveGamemode","SH","Gamemode name"]
];
var SNIPS = [
  {name:"hook.Add", tabTrigger:"hook", content:'hook.Add( "${1:Think}", "${2:MyHook}", function( ${3} )\n\t${0}\nend )'},
  {name:"net.Receive", tabTrigger:"netr", content:'net.Receive( "${1:MyMessage}", function( len, ply )\n\t${0}\nend )'},
  {name:"net send (server)", tabTrigger:"nets", content:'net.Start( "${1:MyMessage}" )\n\t${0}\nnet.Send( ${2:ply} )'},
  {name:"timer.Create", tabTrigger:"timer", content:'timer.Create( "${1:MyTimer}", ${2:1}, ${3:0}, function()\n\t${0}\nend )'},
  {name:"timer.Simple", tabTrigger:"after", content:'timer.Simple( ${1:1}, function()\n\t${0}\nend )'},
  {name:"concommand.Add", tabTrigger:"ccmd", content:'concommand.Add( "${1:my_command}", function( ply, cmd, args )\n\t${0}\nend )'},
  {name:"for players", tabTrigger:"forp", content:'for _, ply in ipairs( player.GetAll() ) do\n\t${0}\nend'},
  {name:"for ipairs", tabTrigger:"fori", content:'for ${1:i}, ${2:v} in ipairs( ${3:tbl} ) do\n\t${0}\nend'},
  {name:"for pairs", tabTrigger:"forpa", content:'for ${1:k}, ${2:v} in pairs( ${3:tbl} ) do\n\t${0}\nend'},
  {name:"local function", tabTrigger:"lfn", content:'local function ${1:name}( ${2} )\n\t${0}\nend'},
  {name:"if IsValid", tabTrigger:"iv", content:'if not IsValid( ${1:ent} ) then\n\treturn\nend\n${0}'},
  {name:"vgui frame", tabTrigger:"frame", content:'local frame = vgui.Create( "DFrame" )\nframe:SetSize( ${1:400}, ${2:300} )\nframe:Center()\nframe:SetTitle( "${3:Title}" )\nframe:MakePopup()\n${0}'},
  {name:"trace from eyes", tabTrigger:"trace", content:'local tr = util.TraceLine( {\n\tstart = ${1:ply}:EyePos(),\n\tendpos = ${1:ply}:EyePos() + ${1:ply}:GetAimVector() * ${2:1000},\n\tfilter = ${1:ply}\n} )\n${0}'}
];

var API = {globals:{}, libs:{}, methods:{}};
var DOCS = {};
function realmOf(r){ return r.sv && r.cl ? "SH" : (r.sv ? "SV" : (r.cl ? "CL" : "")); }
function mark(map, key, realm){ var r = map[key] || (map[key] = {}); r[realm] = true; return r; }
function addName(n, realm){
  var i = n.indexOf(".");
  if (i > 0) { var lib = n.slice(0, i); mark(API.libs[lib] || (API.libs[lib] = {}), n.slice(i + 1), realm); }
  else mark(API.globals, n, realm);
}
GMOD.forEach(function(g){
  DOCS[g[0]] = g[2];
  if (g[1] !== "CL") addName(g[0], "sv");
  if (g[1] !== "SV") addName(g[0], "cl");
});
W.cnsxApi = function(realm, data){
  try {
    if (realm !== "sv" && realm !== "cl") return;
    data = data || {};
    String(data.globals || "").split("\n").forEach(function(n){ if (/^[A-Za-z_]\w*$/.test(n)) mark(API.globals, n, realm); });
    String(data.libs || "").split("\n").forEach(function(n){ if (/^[A-Za-z_]\w*\.[A-Za-z_]\w*$/.test(n)) addName(n, realm); });
    String(data.methods || "").split("\n").forEach(function(n){
      var m = /^([A-Za-z_]\w*):([A-Za-z_]\w*)$/.exec(n);
      if (!m) return;
      var M = API.methods[m[2]] || (API.methods[m[2]] = {classes:{}});
      M.classes[m[1]] = true; M[realm] = true;
    });
  } catch (e) {}
};
function esc(s){ return String(s).replace(/[&<>"']/g, function(c){ return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]; }); }
function docFor(name, realm){
  var d = DOCS[name];
  return "<b>" + esc(name) + "</b>" + (realm ? " <i>[" + esc(realm) + "]</i>" : "") + (d ? "<br>" + esc(d) : "");
}
function prefixMatch(n, lp){ return !lp || n.toLowerCase().indexOf(lp) === 0; }
var gluaCompleter = {
  identifierRegexps: [/[A-Za-z_0-9]/],
  triggerCharacters: [".", ":"],
  getCompletions: function(editor, session, pos, prefix, cb){
    var out = [];
    var lp = (prefix || "").toLowerCase();
    var before = session.getLine(pos.row).slice(0, pos.column - (prefix || "").length);
    var q = /([A-Za-z_]\w*)\s*([.:])$/.exec(before);
    var k;
    if (q && q[2] === ".") {
      var lib = API.libs[q[1]];
      if (lib) for (k in lib) if (prefixMatch(k, lp)) {
        var r = realmOf(lib[k]);
        out.push({caption:k, value:k, meta:r, score:1000, docHTML:docFor(q[1] + "." + k, r)});
      }
      return cb(null, out);
    }
    if (q && q[2] === ":") {
      for (k in API.methods) if (prefixMatch(k, lp)) {
        var M = API.methods[k], cls = Object.keys(M.classes);
        out.push({caption:k, value:k, meta:cls.length === 1 ? cls[0] : cls.length + " classes", score:900,
          docHTML:"<b>" + esc(k) + "</b> <i>[" + esc(realmOf(M)) + "]</i><br>" + esc(cls.slice(0, 8).join(", ")) + (cls.length > 8 ? "..." : "")});
      }
      return cb(null, out);
    }
    if (!lp) return cb(null, out);
    for (k in API.libs) if (prefixMatch(k, lp)) out.push({caption:k, value:k, meta:"library", score:850});
    for (k in API.globals) if (prefixMatch(k, lp)) { var g = realmOf(API.globals[k]); out.push({caption:k, value:k, meta:g, score:800, docHTML:docFor(k, g)}); }
    cb(null, out);
  },
  getDocTooltip: function(item){ return item.docHTML ? {docHTML:item.docHTML} : null; }
};

var ed = null, fb = null, loading = false, changeTimer = null, cursorTimer = null;
var sessions = {}, current = null, fbText = {}, gluaMode = null, wantMode = {}, readOnly = {};

function notifyChange(){
  if (loading || changeTimer) return;
  changeTimer = setTimeout(function(){ changeTimer = null; call("changed"); }, 300);
}
function notifyCursor(){
  if (cursorTimer) return;
  cursorTimer = setTimeout(function(){
    cursorTimer = null;
    if (!ed) return;
    var p = ed.getCursorPosition();
    call("cursor", p.row + 1, p.column + 1);
  }, 150);
}

function setupAce(){
  ed = ace.edit("ed");
  ed.setShowPrintMargin(false);
  ed.$blockScrolling = Infinity;
  var lt = null;
  try { lt = ace.require("ace/ext/language_tools"); } catch (e) {}
  var opts = {tabSize:4, useSoftTabs:true, showFoldWidgets:true, highlightActiveLine:true, behavioursEnabled:true};
  if (lt) { opts.enableBasicAutocompletion = true; opts.enableLiveAutocompletion = true; opts.enableSnippets = false; }
  ed.setOptions(opts);
  if (lt) {
    try { var sm = ace.require("ace/snippets").snippetManager; sm.register(SNIPS, "glua"); sm.register(SNIPS, "lua"); } catch (e) {}
    ed.completers = [gluaCompleter, lt.snippetCompleter, lt.textCompleter, lt.keyWordCompleter].filter(function(c){ return !!c; });
  }
  ed.on("change", function(delta){
    notifyChange();
    // after "lib." or "obj:" start a fresh completion; an already-open popup would keep filtering its old list
    if (!lt || loading || delta.action !== "insert" || delta.lines.length !== 1) return;
    var ch = delta.lines[0];
    if (ch !== "." && ch !== ":") return;
    var before = ed.session.getLine(delta.start.row).slice(0, delta.start.column);
    if (!/[A-Za-z_]\w*$/.test(before)) return;
    setTimeout(function(){
      var c = ed.completer;
      if (c && c.activated) c.detach();
      ed.execCommand("startAutocomplete");
    }, 0);
  });
  ed.selection.on("changeCursor", notifyCursor);
  var keys = [
    ["cnsxFind", "Ctrl-F|Ctrl-H", "Command-F|Command-H", "find"],
    ["cnsxLine", "Ctrl-G", "Command-G", "line"],
    ["cnsxEsc", "Esc", "Esc", "esc"],
    ["cnsxSave", "Ctrl-S", "Command-S", "save"],
    ["cnsxSaveAs", "Ctrl-Shift-S", "Command-Shift-S", "saveas"],
    ["cnsxRunSv", "Ctrl-Enter", "Command-Enter", "run_sv"],
    ["cnsxRunMe", "Ctrl-Shift-Enter", "Command-Shift-Enter", "run_me"],
    ["cnsxNewTab", "Ctrl-T", "Command-T", "newtab"],
    ["cnsxCloseTab", "Ctrl-W", "Command-W", "closetab"],
    ["cnsxNextTab", "Ctrl-Tab", "Ctrl-Tab", "nexttab"],
    ["cnsxPrevTab", "Ctrl-Shift-Tab", "Ctrl-Shift-Tab", "prevtab"]
  ];
  keys.forEach(function(k){
    ed.commands.addCommand({name:k[0], bindKey:{win:k[1], mac:k[2]}, exec:function(){ call("hotkey", k[3]); }});
  });
  ed.commands.addCommand({name:"cnsxWiki", bindKey:{win:"F1", mac:"F1"}, exec:function(){ call("hotkey", "wiki", qualifiedWord()); }});
  applyPrefs(PREFS);
  try {
    ace.config.loadModule("ace/mode/lua", function(m){
      try {
        var oop = ace.require("ace/lib/oop");
        var LuaRules = ace.require("ace/mode/lua_highlight_rules").LuaHighlightRules;
        var GluaRules = function(){
          LuaRules.call(this);
          this.$rules.start.unshift(
            {token:"comment", regex:"\\/\\/.*$"},
            {token:"comment", regex:"\\/\\*", next:"gluaBlockComment"},
            {token:"keyword.control", regex:"\\bcontinue\\b"},
            {token:"keyword.operator", regex:"!=|&&|\\|\\||!"}
          );
          this.$rules.gluaBlockComment = [{token:"comment", regex:"\\*\\/", next:"start"}, {defaultToken:"comment"}];
        };
        oop.inherits(GluaRules, LuaRules);
        var GluaMode = function(){ m.Mode.call(this); this.HighlightRules = GluaRules; };
        oop.inherits(GluaMode, m.Mode);
        GluaMode.prototype.$id = "ace/mode/glua";
        GluaMode.prototype.createWorker = function(){ return null; };
        gluaMode = new GluaMode();
        for (var id in sessions) if (wantMode[id] === "glua") sessions[id].setMode(gluaMode);
      } catch (e) { info("GLua highlighting unavailable: " + e); }
    });
  } catch (e) {}
}

function makeSession(text, mode){
  var s = ace.createEditSession(text || "");
  s.setUseWorker(false);
  s.setTabSize(4);
  s.setUseSoftTabs(true);
  s.setUseWrapMode(PREFS.wrap !== false);
  setSessionMode(s, mode);
  return s;
}
function setSessionMode(s, mode){
  if (mode === "glua") s.setMode(gluaMode || "ace/mode/lua");
  else s.setMode(MODES[mode] ? mode : "ace/mode/text");
}

function applyPrefs(p){
  PREFS = p || PREFS;
  if (ed) {
    ed.setFontSize(PREFS.fontSize || 13);
    ed.setTheme("ace/theme/" + (PREFS.theme || "twilight"));
    for (var id in sessions) sessions[id].setUseWrapMode(PREFS.wrap !== false);
  } else if (fb) {
    fb.style.fontSize = (PREFS.fontSize || 13) + "px";
    fb.style.whiteSpace = PREFS.wrap !== false ? "pre-wrap" : "pre";
  }
}

function qualifiedWord(){
  if (!ed) return "";
  var pos = ed.getCursorPosition(), line = ed.session.getLine(pos.row), s = pos.column, e = pos.column;
  while (s > 0 && /[\w.:]/.test(line.charAt(s - 1))) s--;
  while (e < line.length && /\w/.test(line.charAt(e))) e++;
  return line.slice(s, e).replace(/^[.:]+/, "");
}

function setupFallback(){
  var host = document.getElementById("ed");
  fb = document.createElement("textarea");
  fb.id = "fb";
  fb.spellcheck = false;
  host.appendChild(fb);
  fb.addEventListener("input", notifyChange);
  fb.addEventListener("keydown", function(ev){
    var k = ev.key, c = ev.ctrlKey || ev.metaKey, hk = null;
    if (k === "Tab" && !c) { ev.preventDefault(); var a = fb.selectionStart; fb.setRangeText("    ", a, fb.selectionEnd, "end"); notifyChange(); return; }
    if (c && (k === "f" || k === "F" || k === "h" || k === "H")) hk = "find";
    else if (c && (k === "g" || k === "G")) hk = "line";
    else if (c && ev.shiftKey && (k === "s" || k === "S")) hk = "saveas";
    else if (c && (k === "s" || k === "S")) hk = "save";
    else if (c && ev.shiftKey && k === "Enter") hk = "run_me";
    else if (c && k === "Enter") hk = "run_sv";
    else if (k === "Escape") hk = "esc";
    if (hk) { ev.preventDefault(); call("hotkey", hk); }
  });
  applyPrefs(PREFS);
  info("Ace editor could not load (no internet or cdnjs blocked); using the plain editor");
}

function fbFind(q, back, cs){
  var hay = cs ? fb.value : fb.value.toLowerCase(), n = cs ? q : q.toLowerCase(), i;
  if (back) { i = hay.lastIndexOf(n, Math.max(0, fb.selectionStart - 1)); if (i < 0) i = hay.lastIndexOf(n); }
  else { i = hay.indexOf(n, fb.selectionEnd); if (i < 0) i = hay.indexOf(n); }
  if (i < 0) { info("no match"); return false; }
  fb.focus(); fb.setSelectionRange(i, i + q.length);
  return true;
}
function fbLineStart(n){
  var lines = fb.value.split("\n"), off = 0;
  for (var i = 0; i < Math.min(n - 1, lines.length - 1); i++) off += lines[i].length + 1;
  return off;
}

if (typeof ace === "undefined") setupFallback(); else setupAce();

// ---- API used by Lua ----
W.cnsxOpen = function(id, text, mode, force, ro){
  id = String(id);
  wantMode[id] = mode;
  readOnly[id] = !!ro;
  if (ed) {
    var s = sessions[id];
    loading = true;
    if (!s) { s = sessions[id] = makeSession(text, mode); }
    else { if (force) { s.setValue(text || ""); s.getUndoManager().reset(); } setSessionMode(s, mode); }
    ed.setSession(s);
    ed.setReadOnly(!!ro);
    loading = false;
    current = id;
    ed.focus();
    notifyCursor();
  } else if (fb) {
    if (current !== null) fbText[current] = fb.value;
    if (fbText[id] === undefined || force) fbText[id] = text || "";
    loading = true; fb.value = fbText[id]; fb.readOnly = !!ro; loading = false;
    current = id;
  }
};
W.cnsxDrop = function(id){
  id = String(id);
  if (sessions[id]) { try { sessions[id].destroy(); } catch (e) {} delete sessions[id]; }
  delete fbText[id]; delete wantMode[id]; delete readOnly[id];
};
W.cnsxDropAll = function(){ for (var id in sessions) W.cnsxDrop(id); fbText = {}; };
// seq is echoed so Lua can drop a reply that arrives after it gave up waiting
W.cnsxCode = function(seq){
  seq = parseInt(seq, 10) || 0;
  if (ed) call("code", ed.getValue(), ed.getSelectedText(), seq);
  else if (fb) call("code", fb.value, fb.value.substring(fb.selectionStart, fb.selectionEnd), seq);
  else call("code", "", "", seq);
};
W.cnsxMode = function(mode){ if (ed && current !== null && sessions[current]) { wantMode[current] = mode; setSessionMode(sessions[current], mode); } };
W.cnsxPrefs = function(p){ applyPrefs(p); };
W.cnsxApiReady = function(){ return true; };
W.cnsxInsert = function(v){ if (ed) { ed.insert(v); ed.focus(); } else if (fb) { fb.setRangeText(v, fb.selectionStart, fb.selectionEnd, "end"); notifyChange(); } };
W.cnsxFind = function(q, back, cs, re, ww){
  if (!q) return;
  if (ed) {
    var r = ed.find(q, {wrap:true, backwards:!!back, caseSensitive:!!cs, regExp:!!re, wholeWord:!!ww});
    if (!r) info("no match: " + q);
  } else if (fb) fbFind(q, back, cs);
};
W.cnsxReplace = function(q, r, cs, re, ww){
  if (!q) return;
  if (ed) { ed.replace(r || "", {needle:q, caseSensitive:!!cs, regExp:!!re, wholeWord:!!ww}); }
  else if (fb) {
    var sel = fb.value.substring(fb.selectionStart, fb.selectionEnd);
    if ((cs ? sel : sel.toLowerCase()) === (cs ? q : q.toLowerCase())) { fb.setRangeText(r || "", fb.selectionStart, fb.selectionEnd, "end"); notifyChange(); }
    fbFind(q, false, cs);
  }
};
W.cnsxReplaceAll = function(q, r, cs, re, ww){
  if (!q) return;
  var n = 0;
  if (ed) { ed.find(q, {wrap:true, caseSensitive:!!cs, regExp:!!re, wholeWord:!!ww}); n = ed.replaceAll(r || "", {needle:q, caseSensitive:!!cs, regExp:!!re, wholeWord:!!ww}) || 0; }
  else if (fb) {
    var parts = cs ? fb.value.split(q) : fb.value.split(new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i"));
    n = parts.length - 1; fb.value = parts.join(r || ""); notifyChange();
  }
  info(n + " replaced");
};
W.cnsxGoto = function(n){
  n = parseInt(n, 10) || 1;
  if (ed) { ed.gotoLine(n, 0, true); ed.scrollToLine(Math.max(n - 1, 0), true, true, function(){}); ed.focus(); }
  else if (fb) { var o = fbLineStart(n); fb.focus(); fb.setSelectionRange(o, o); }
};
var lintMarks = [], runMarks = [];
function pushAnnotations(){ if (ed) ed.session.setAnnotations(lintMarks.concat(runMarks)); }
W.cnsxLint = function(n, msg){
  n = parseInt(n, 10) || 0;
  lintMarks = n > 0 ? [{row:n - 1, column:0, text:String(msg || "syntax error"), type:"error"}] : [];
  pushAnnotations();
};
W.cnsxMark = function(n, msg){
  n = parseInt(n, 10) || 1;
  runMarks = [{row:n - 1, column:0, text:String(msg || "error"), type:"error"}];
  pushAnnotations();
  W.cnsxGoto(n);
};
W.cnsxClearMarks = function(){ runMarks = []; pushAnnotations(); };
W.cnsxFocus = function(){ if (ed) ed.focus(); else if (fb) fb.focus(); };
W.cnsxIsAce = function(){ return !!ed; };
})();
</script></body></html>]==]
end

function CNSX.EditorJS( html, code )
    if not IsValid( html ) then
        return
    end
    html:RunJavascript( code )
end

-- "CNSX:Admin:3: boom", "[string \"x\"]:3: boom", "... line 3"
function CNSX.ParseErrLine( msg )
    msg = tostring( msg or "" )
    local n = tonumber( string.match( msg, "^[^\n]-:(%d+):" ) )
    if n then
        return n
    end
    n = tonumber( string.match( msg, ":(%d+):" ) )
    if n then
        return n
    end

    return tonumber( string.match( msg, "line%s+(%d+)" ) )
end

-- wiki page for "hook.Add", "print", "ply:Nick" (resolved against the client's metatables)
function CNSX.WikiURL( word )
    word = tostring( word or "" )
    if not string.match( word, "^[%w_%.:]+$" ) then
        return nil
    end
    local base = "https://wiki.facepunch.com/gmod/"
    local lib, fn = string.match( word, "^([%a_][%w_]*)%.([%a_][%w_]*)$" )
    if lib then
        return base .. lib .. "." .. fn
    end
    local method = string.match( word, ":([%a_][%w_]*)$" )
    if method then
        for _, class in ipairs( CNSX.MetaClasses or {} ) do
            local meta = FindMetaTable( class )
            if istable( meta ) and isfunction( rawget( meta, method ) ) then
                return base .. class .. ":" .. method
            end
        end

        return base .. "~search?q=" .. method
    end
    word = string.match( word, "([%a_][%w_]*)$" ) or word
    if isfunction( _G[word] ) then
        return base .. "Global." .. word
    end
    if istable( _G[word] ) then
        return base .. word
    end

    return base .. "~search?q=" .. word
end

-- GLua syntax check without running anything; returns line, message or nil
function CNSX.LintLua( code )
    local fn = CompileString( tostring( code or "" ), "lint", false )
    if isfunction( fn ) then
        return nil
    end
    local msg = tostring( fn )

    return CNSX.ParseErrLine( msg ) or 1, string.gsub( msg, "^lint:%d+:%s*", "" )
end
