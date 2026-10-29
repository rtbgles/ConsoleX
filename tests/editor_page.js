// Drives the real editor page (CNSX.EditorHTML) in headless Chromium against a local copy of Ace 1.32.6.
//   luajit tests/dump_editor_html.lua /tmp/editor.html
//   npm pack ace-builds@1.32.6 && tar xzf ace-builds-1.32.6.tgz      (gives package/src-min-noconflict)
//   node tests/editor_page.js /tmp/editor.html package/src-min-noconflict
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const [htmlPath, aceDir] = process.argv.slice(2);
const CDN = "https://cdnjs.cloudflare.com/ajax/libs/ace/1.32.6/";
const html = fs.readFileSync(htmlPath, "utf8");

let pass = 0, fail = 0;
function check(name, cond) {
  if (cond) { pass++; console.log("PASS  " + name); } else { fail++; console.log("FAIL  " + name); }
}

// stands in for DHTML:AddFunction("cnsx", ...): records every call
const BRIDGE = `window.cnsx = {}; window.calls = [];
["code","changed","cursor","hotkey","info"].forEach(function(n){ cnsx[n] = function(a, b){ calls.push([n, a, b]); }; });`;

async function load(browser, base) {
  const dir = fs.mkdtempSync(path.join(path.dirname(htmlPath), "page-"));
  const file = path.join(dir, "editor.html");
  fs.writeFileSync(file, html.split(CDN).join(base));
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto("file://" + file);
  await page.evaluate(BRIDGE);
  await page.evaluate(() => window.cnsxReady && cnsxReady());
  return { page, errors };
}

(async () => {
  const browser = await chromium.launch();

  // ---------- Ace build ----------
  const { page, errors } = await load(browser, "file://" + path.resolve(aceDir) + "/");
  check("Ace loads from the CDN file names used by the page", await page.evaluate(() => window.cnsxIsAce && cnsxIsAce()));
  check("boot prefs applied (font size, theme)", await page.evaluate(() => {
    const ed = ace.edit("ed");
    return ed.getFontSize() === 14 && /monokai/.test(ed.getTheme());
  }));

  const glua = "local x = 1 // note\nif a != b && !c then continue end\n/* block\ncomment */ print(x)";
  await page.evaluate((t) => cnsxOpen("t1", t, "glua", false), glua);
  await page.waitForFunction(() => ace.edit("ed").session.getMode().$id === "ace/mode/glua", null, { timeout: 5000 });
  const tokens = await page.evaluate(() => {
    const s = ace.edit("ed").session;
    const all = [];
    for (let r = 0; r < s.getLength(); r++) s.getTokens(r).forEach((t) => all.push([t.type, t.value.trim()]));
    return all;
  });
  const typeOf = (v) => (tokens.find((t) => t[1] === v) || [])[0];
  check("GLua mode: // is a comment", /comment/.test(typeOf("// note") || ""));
  check("GLua mode: != && ! are operators", /operator/.test(typeOf("!=") || "") && /operator/.test(typeOf("&&") || ""));
  check("GLua mode: continue is a keyword", /keyword/.test(typeOf("continue") || ""));
  check("GLua mode: /* */ spans lines as a comment", tokens.some((t) => /comment/.test(t[0]) && t[1] === "comment */"));
  check("Lua keywords still highlighted", /keyword/.test(typeOf("local") || "") && /keyword/.test(typeOf("then") || ""));
  check("no luaparse worker (it would flag GLua syntax as errors)", await page.evaluate(() => !ace.edit("ed").session.$worker && ace.edit("ed").session.getAnnotations().length === 0));

  await page.evaluate(() => { calls.length = 0; });
  await page.evaluate(() => cnsxOpen("t2", "second tab", "ace/mode/json", false));
  await page.waitForTimeout(400);
  check("opening a tab does not report an edit", await page.evaluate(() => !calls.some((c) => c[0] === "changed")));
  await page.evaluate(() => cnsxOpen("t1", "IGNORED", "glua", false));
  check("switching back keeps the tab's live text (separate sessions)", await page.evaluate((t) => ace.edit("ed").getValue() === t, glua));
  await page.evaluate(() => { const ed = ace.edit("ed"); ed.session.getUndoManager().reset(); ed.navigateFileEnd(); ed.insert("\n-- typed"); });
  await page.evaluate(() => cnsxOpen("t2", "", "ace/mode/json", false));
  await page.evaluate(() => cnsxOpen("t1", "", "glua", false));
  check("undo history survives tab switches", await page.evaluate(() => ace.edit("ed").session.getUndoManager().hasUndo()));
  await page.waitForTimeout(400);
  check("typing reports a (throttled) change", await page.evaluate(() => calls.filter((c) => c[0] === "changed").length === 1));

  await page.evaluate(() => { calls.length = 0; const ed = ace.edit("ed"); ed.selection.setRange(new (ace.require("ace/range").Range)(0, 0, 0, 11)); cnsxCode(); });
  const code = await page.evaluate(() => calls.find((c) => c[0] === "code"));
  check("cnsxCode returns the full text and the selection", code && code[1].startsWith("local x = 1 // note") && code[2] === "local x = 1");

  // autocomplete
  await page.evaluate(() => cnsxApi("cl", { globals: "print\nLocalPlayer", libs: "hook.Add\nhook.Remove\nnet.SendToServer", methods: "Player:Nick\nEntity:GetPos" }));
  await page.evaluate(() => cnsxApi("sv", { globals: "print", libs: "hook.Add\nhook.Remove\nnet.Send", methods: "Player:Nick" }));
  const complete = (line) => page.evaluate((line) => new Promise((res) => {
    const ed = ace.edit("ed");
    ed.setValue(line, 1);
    const pos = ed.getCursorPosition();
    const m = /\w*$/.exec(line)[0];
    ed.completers[0].getCompletions(ed, ed.session, pos, m, (e, list) => res(list.map((x) => x.caption + "|" + x.meta)));
  }), line);
  const lib = await complete("hook.");
  check("'hook.' offers only hook members", lib.includes("Add|SH") && lib.includes("Remove|SH") && !lib.some((x) => x.startsWith("hook")));
  const net = await complete("net.S");
  check("realm tags: net.Send is SV, net.SendToServer is CL", net.includes("Send|SV") && net.includes("SendToServer|CL"));
  const meth = await complete("ply:N");
  check("':' offers methods with their class", meth.includes("Nick|Player"));
  const glob = await complete("Loc");
  check("bare prefix offers globals", glob.includes("LocalPlayer|CL"));
  check("completer advertises . and : as triggers", await page.evaluate(() => ace.edit("ed").completers[0].triggerCharacters.join("") === ".:"));
  check("snippet + local-word + keyword completers enabled", await page.evaluate(() => ace.edit("ed").completers.length === 4));
  const snips = await page.evaluate(() => new Promise((res) => {
    const ed = ace.edit("ed"); ed.setValue("hoo", 1);
    ed.completers[1].getCompletions(ed, ed.session, ed.getCursorPosition(), "hoo", (e, l) => res(l.map((x) => x.caption)));
  }));
  check("GLua snippets offered (hook.Add)", snips.some((s) => /hook/.test(s)));
  check("completion docs are escaped HTML", await page.evaluate(() => {
    cnsxApi("cl", { globals: "x<img>" });
    return !Object.prototype.hasOwnProperty.call(window, "x<img>");
  }));

  await page.evaluate(() => { cnsxOpen("live", "", "glua", false); ace.edit("ed").focus(); });
  await page.keyboard.type("hook.");
  await page.waitForTimeout(600);
  const popup = await page.evaluate(() => {
    const ed = ace.edit("ed");
    const c = ed.completer;
    return c && c.popup && c.popup.isOpen ? c.completions.filtered.map((x) => x.caption) : [];
  });
  check("typing 'hook.' opens the popup with hook members", popup.includes("Add") && popup.includes("Remove"));
  await page.keyboard.press("Escape");

  // shortcuts
  const key = async (combo, expect) => {
    await page.evaluate(() => { calls.length = 0; ace.edit("ed").focus(); });
    await page.keyboard.press(combo);
    return page.evaluate((e) => calls.some((c) => c[0] === "hotkey" && c[1] === e), expect);
  };
  check("Ctrl+Enter -> run_sv", await key("Control+Enter", "run_sv"));
  check("Ctrl+Shift+Enter -> run_me", await key("Control+Shift+Enter", "run_me"));
  check("Ctrl+S -> save", await key("Control+s", "save"));
  check("Ctrl+Shift+S -> saveas", await key("Control+Shift+S", "saveas"));
  check("Ctrl+F -> find", await key("Control+f", "find"));
  check("Ctrl+G -> line", await key("Control+g", "line"));
  check("Ctrl+W -> closetab", await key("Control+w", "closetab"));
  await page.evaluate(() => { const ed = ace.edit("ed"); ed.setValue("hook.Add( x )", -1); ed.moveCursorTo(0, 7); });
  await page.evaluate(() => { calls.length = 0; ace.edit("ed").focus(); });
  await page.keyboard.press("F1");
  check("F1 sends the qualified word for the wiki", await page.evaluate(() => calls.some((c) => c[0] === "hotkey" && c[1] === "wiki" && c[2] === "hook.Add")));
  check("Ctrl+/ toggles a -- comment", await page.evaluate(() => {
    cnsxOpen("t3", "print(1)", "glua", false);
    const ed = ace.edit("ed"); ed.execCommand("togglecomment"); return ed.getValue().startsWith("-- ") || ed.getValue().startsWith("--");
  }));

  // find / replace / lint / marks / prefs
  check("replace all reports the count", await page.evaluate(() => {
    cnsxOpen("t4", "a a a b", "ace/mode/text", false); calls.length = 0;
    cnsxReplaceAll("a", "z", false, false, false);
    return ace.edit("ed").getValue() === "z z z b" && calls.some((c) => c[0] === "info" && c[1] === "3 replaced");
  }));
  check("find miss is reported", await page.evaluate(() => { calls.length = 0; cnsxFind("nope", false, false, false, false); return calls.some((c) => c[0] === "info" && /no match/.test(c[1])); }));
  check("lint and run marks become annotations", await page.evaluate(() => {
    cnsxLint(1, "syntax"); cnsxMark(1, "boom");
    const a = ace.edit("ed").session.getAnnotations(); cnsxLint(0); cnsxClearMarks();
    return a.length === 2 && ace.edit("ed").session.getAnnotations().length === 0;
  }));
  check("prefs apply live", await page.evaluate(() => { cnsxPrefs({ fontSize: 20, theme: "dracula", wrap: false }); const ed = ace.edit("ed"); return ed.getFontSize() === 20 && !ed.session.getUseWrapMode(); }));
  check("dropping a session frees it", await page.evaluate(() => { cnsxDrop("t4"); cnsxOpen("t4", "fresh", "ace/mode/text", false); return ace.edit("ed").getValue() === "fresh"; }));
  check("forced reload replaces the text", await page.evaluate(() => { cnsxOpen("t4", "reloaded", "ace/mode/text", true); return ace.edit("ed").getValue() === "reloaded"; }));
  check("no page errors with Ace", errors.length === 0);
  if (errors.length) console.log(errors.join("\n"));
  await page.close();

  // ---------- fallback (CDN unreachable) ----------
  const fbLoad = await load(browser, "file:///nonexistent/ace/");
  const fb = fbLoad.page;
  check("fallback editor appears when Ace can't load", await fb.evaluate(() => !!document.getElementById("fb") && !cnsxIsAce()));
  check("the user is told Ace failed (queued until the bridge is ready)", await fb.evaluate(() => calls.some((c) => c[0] === "info" && /could not load/.test(c[1]))));
  await fb.evaluate(() => { cnsxOpen("a", "alpha text", "glua", false); cnsxOpen("b", "beta", "glua", false); });
  check("fallback keeps per-tab text", await fb.evaluate(() => { cnsxOpen("a", "", "glua", false); return document.getElementById("fb").value === "alpha text"; }));
  check("fallback cnsxCode works", await fb.evaluate(() => { calls.length = 0; cnsxCode(); return calls[0] && calls[0][0] === "code" && calls[0][1] === "alpha text"; }));
  check("fallback find selects the match", await fb.evaluate(() => { cnsxFind("text", false, false); const t = document.getElementById("fb"); return t.value.substring(t.selectionStart, t.selectionEnd) === "text"; }));
  check("fallback replace all", await fb.evaluate(() => { cnsxReplaceAll("a", "o", false); return document.getElementById("fb").value === "olpho text"; }));
  await fb.focus("#fb");
  await fb.evaluate(() => { calls.length = 0; });
  await fb.keyboard.press("Control+Enter");
  check("fallback Ctrl+Enter -> run_sv", await fb.evaluate(() => calls.some((c) => c[0] === "hotkey" && c[1] === "run_sv")));
  await fb.keyboard.type("x");
  await fb.waitForTimeout(400);
  check("fallback typing reports a change", await fb.evaluate(() => calls.some((c) => c[0] === "changed")));
  check("no page errors in fallback", fbLoad.errors.length === 0);
  if (fbLoad.errors.length) console.log(fbLoad.errors.join("\n"));

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
