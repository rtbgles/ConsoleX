if not CLIENT then return end

CNSX.Modes = {
    lua = "ace/mode/lua",
    glua = "ace/mode/lua",
    js = "ace/mode/javascript",
    html = "ace/mode/html",
    css = "ace/mode/css",
    json = "ace/mode/json",
    txt = "ace/mode/text",
    md = "ace/mode/markdown"
}

function CNSX.GuessMode( path )
    local ext = string.lower( string.GetExtensionFromFilename( path or "" ) or "" )
    if ext == "lua" then
        return "lua"
    end
    return CNSX.Modes[ext] and ext or "txt"
end

function CNSX.EditorHTML( mode )
    mode = CNSX.Modes[mode] or "ace/mode/lua"
    return [[<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
html,body,#ed{margin:0;height:100%;background:#0c0c0e;color:#eee;}
.ace_editor.ace_autocomplete{background:#161b28;border:1px solid #3a6ad4;color:#dce8ff;}
.ace_doc-tooltip{background:#161b28;color:#9ab4e0;border:1px solid #3a6ad4;}
</style>
</head><body>
<div id="ed"></div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/ace/1.32.6/ace.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/ace/1.32.6/ext-language_tools.min.js"></script>
<script>
var ed = ace.edit("ed");
ed.setTheme("ace/theme/twilight");
ed.session.setMode("]] .. mode .. [[");
ed.setShowPrintMargin(false);
ed.setFontSize(13);
try {
  ace.require("ace/ext/language_tools");
  ed.setOptions({
    tabSize:4,
    useSoftTabs:true,
    wrap:true,
    enableBasicAutocompletion:true,
    enableLiveAutocompletion:true,
    enableSnippets:false
  });
} catch (e) {
  ed.setOptions({tabSize:4,useSoftTabs:true,wrap:true});
}
var GMOD = [
  {c:"print", m:"[Shared]", d:"Prints to console"},
  {c:"MsgN", m:"[Shared]", d:"Prints a line to console"},
  {c:"ErrorNoHalt", m:"[Shared]", d:"Error without breaking Lua"},
  {c:"IsValid", m:"[Shared]", d:"True if entity/panel exists"},
  {c:"CurTime", m:"[Shared]", d:"Server/client synced time"},
  {c:"FrameTime", m:"[Shared]", d:"Last frame delta"},
  {c:"LocalPlayer", m:"[Client]", d:"The local player"},
  {c:"player.GetAll", m:"[Shared]", d:"Table of players"},
  {c:"player.GetBySteamID64", m:"[Shared]", d:"Player from SteamID64"},
  {c:"ents.GetAll", m:"[Shared]", d:"All entities"},
  {c:"ents.FindInSphere", m:"[Shared]", d:"Entities in radius"},
  {c:"hook.Add", m:"[Shared]", d:"hook.Add(event, id, fn)"},
  {c:"hook.Remove", m:"[Shared]", d:"Remove a named hook"},
  {c:"timer.Simple", m:"[Shared]", d:"Run once after delay"},
  {c:"timer.Create", m:"[Shared]", d:"Named repeating timer"},
  {c:"timer.Remove", m:"[Shared]", d:"Kill a named timer"},
  {c:"net.Start", m:"[Shared]", d:"Begin a net message"},
  {c:"net.Send", m:"[Server]", d:"Send to player(s)"},
  {c:"net.Broadcast", m:"[Server]", d:"Send to every client"},
  {c:"net.SendToServer", m:"[Client]", d:"Client to server"},
  {c:"file.Find", m:"[Shared]", d:"file.Find(glob, path)"},
  {c:"file.Read", m:"[Shared]", d:"Read a file"},
  {c:"file.Write", m:"[Shared]", d:"Write DATA file"},
  {c:"util.TableToJSON", m:"[Shared]", d:"Encode a table"},
  {c:"util.JSONToTable", m:"[Shared]", d:"Decode JSON"},
  {c:"util.TraceLine", m:"[Shared]", d:"Line trace"},
  {c:"vgui.Create", m:"[Client]", d:"Create a panel"},
  {c:"vgui.Register", m:"[Client]", d:"Register a panel class"},
  {c:"surface.SetDrawColor", m:"[Client]", d:"2D draw color"},
  {c:"draw.SimpleText", m:"[Client]", d:"Draw aligned text"},
  {c:"draw.RoundedBox", m:"[Client]", d:"Rounded rectangle"},
  {c:"input.IsKeyDown", m:"[Client]", d:"Key currently down"},
  {c:"gui.MouseX", m:"[Client]", d:"Cursor X"},
  {c:"team.GetName", m:"[Shared]", d:"Team display name"},
  {c:"team.NumPlayers", m:"[Shared]", d:"Players on a team"},
  {c:"team.GetColor", m:"[Shared]", d:"Team color"},
  {c:"team.AddScore", m:"[Shared]", d:"Add score to a team"},
  {c:"team.TotalDeaths", m:"[Shared]", d:"Deaths for a team"},
  {c:"team.Valid", m:"[Shared]", d:"True if team index exists"},
  {c:"CompileString", m:"[Shared]", d:"Compile Lua, return fn or err"},
  {c:"RunString", m:"[Shared]", d:"Compile and run a string"},
  {c:"include", m:"[Shared]", d:"Run a Lua file"},
  {c:"AddCSLuaFile", m:"[Server]", d:"Send file to clients"}
];
var gmodCompleter = {
  getCompletions: function(editor, session, pos, prefix, cb) {
    prefix = (prefix || "").toLowerCase();
    var out = [];
    for (var i = 0; i < GMOD.length; i++) {
      var it = GMOD[i];
      if (!prefix || it.c.toLowerCase().indexOf(prefix) === 0 || it.c.toLowerCase().indexOf(prefix) >= 0) {
        out.push({caption: it.c, value: it.c, meta: it.m, score: 2000 - i, docHTML: it.d});
      }
    }
    cb(null, out);
  },
  getDocTooltip: function(item) {
    if (item.docHTML) item.docHTML = item.meta + " " + item.docHTML;
  }
};
try {
  ed.completers = [gmodCompleter];
} catch (e) {}
function cnsxHotkey(k){ if (window.cnsx && cnsx.hotkey) cnsx.hotkey(k); }
ed.commands.addCommand({name:"cnsxFind", bindKey:{win:"Ctrl-F|Ctrl-H", mac:"Command-F|Command-H"}, exec:function(){ cnsxHotkey("find"); }});
ed.commands.addCommand({name:"cnsxLine", bindKey:{win:"Ctrl-G", mac:"Command-G"}, exec:function(){ cnsxHotkey("line"); }});
ed.commands.addCommand({name:"cnsxEsc", bindKey:{win:"Esc", mac:"Esc"}, exec:function(){ cnsxHotkey("esc"); }});
ed.setValue("", -1);
function cnsxSet(v){ ed.setValue(v || "", -1); }
function cnsxSetObj(o){ ed.setValue((o && o.c) || "", -1); }
function cnsxGet(){ return ed.getValue(); }
function cnsxMode(m){ ed.session.setMode(m); }
function cnsxInsert(v){ ed.insert(v); }
function cnsxFind(q, back){
  if (!q) return;
  ed.find(q, {wrap:true, backwards:!!back, caseSensitive:false, wholeWord:false, regExp:false});
}
function cnsxReplace(r){ ed.replace(r || ""); }
function cnsxReplaceAll(q, r){
  if (!q) return;
  ed.find(q, {wrap:true, caseSensitive:false, wholeWord:false, regExp:false});
  ed.replaceAll(r || "");
}
function cnsxGoto(n){
  n = parseInt(n, 10) || 1;
  ed.gotoLine(n, 0, true);
  ed.scrollToLine(Math.max(n - 1, 0), true, true, function(){});
}
function cnsxMark(n){
  n = parseInt(n, 10) || 1;
  try {
    ed.session.clearAnnotations();
    ed.session.setAnnotations([{row:n-1, column:0, text:"compile", type:"error"}]);
  } catch (e) {}
  cnsxGoto(n);
}
</script></body></html>]]
end

function CNSX.EditorJS( html, code )
    if not IsValid( html ) then
        return
    end
    html:RunJavascript( code )
end

function CNSX.ParseErrLine( msg )
    msg = tostring( msg or "" )
    local n = tonumber( string.match( msg, ":(%d+):" ) )
    if n then
        return n
    end
    return tonumber( string.match( msg, "line%s+(%d+)" ) )
end

function CNSX.AttachEditor( html )
    html._ready = false
    html:SetAllowLua( false )
    html.OnDocumentReady = function()
        html._ready = true
    end
end

function CNSX.SetCode( html, body )
    body = string.gsub( tostring( body or "" ), "\r", "" )
    html:RunJavascript( "if(window.cnsxSet)cnsxSet(" .. util.TableToJSON( { tostring( body or "" ) } ):sub( 2, -2 ) .. ")" )
end

function CNSX.AskCode( html, cb )
    html:AddFunction( "cnsx", "code", function( val )
        if isfunction( cb ) then
            cb( tostring( val or "" ) )
        end
    end )
    html:RunJavascript( "if(window.cnsx&&cnsx.code)cnsx.code(cnsxGet());" )
end
