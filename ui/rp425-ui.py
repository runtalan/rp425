#!/usr/bin/env python3
"""Local web UI for the RP425 driver: change every print option and run printer actions.

    python3 ui/rp425-ui.py [--printer RP425] [--port 8425] [--no-open]

Options are read live from CUPS (`lpoptions -l`) and saved as your own defaults for the
queue (`lpoptions -o`, stored in ~/.cups/lpoptions; no root needed). Labels for each
choice come from ppd/RP425.ppd. Only listens on 127.0.0.1.
"""
import argparse
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import webbrowser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PPD = os.path.join(ROOT, "ppd", "RP425.ppd")
RP425 = shutil.which("rp425") or os.path.join(ROOT, "build", "rp425")

# Which card each option lives on, in display order. Unknown options go to "Other".
GROUPS = [
    ("Label", ["PageSize", "MediaTracking"]),
    ("Print quality", ["Darkness", "PrintSpeed", "Dither", "Threshold"]),
    ("Position", ["TopOffset", "LeftOffset", "Rotate180"]),
    ("Advanced", ["Compression"]),
]
HINTS = {
    "MediaTracking": "How the printer finds the start of each label. Stays in effect until power-cycled.",
    "Darkness": "Printer's ~SD value. “Printer Setting” leaves the printer's own value alone.",
    "PrintSpeed": "Inches per second. Slower is usually crisper on small barcodes.",
    "Dither": "Sharp for text and barcodes; dithered for photos and logos.",
    "Threshold": "Cutoff for black vs. white when halftoning is Sharp.",
    "TopOffset": "Shift the image up or down in 1 mm steps.",
    "LeftOffset": "Shift the image left or right in 1 mm steps.",
    "Rotate180": "Print upside-down, for stock that feeds the other way.",
    "Compression": "ZPL run-length shrinks the data sent over USB; turn off only to debug.",
}
SKIP = {"ColorModel", "Resolution"}  # single-choice, nothing to change


def sh(*cmd, input=None, timeout=60):
    p = subprocess.run(cmd, input=input, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


def ppd_labels():
    """{option: (label, {choice: label})} from the PPD."""
    opts, cur = {}, None
    try:
        text = open(PPD, encoding="utf-8").read()
    except OSError:
        return opts
    for line in text.splitlines():
        m = re.match(r"\*OpenUI \*(\w+)/([^:]*):", line)
        if m:
            cur = m[1]
            opts[cur] = (m[2], {})
            continue
        if line.startswith("*CloseUI"):
            cur = None
        elif cur and (m := re.match(r"\*%s ([^/:\s]+)/([^:]*):" % cur, line)):
            opts[cur][1][m[1]] = m[2]
    return opts


def read_options(printer):
    rc, out = sh("lpoptions", "-p", printer, "-l")
    if rc != 0:
        raise RuntimeError(out or "lpoptions failed")
    labels = ppd_labels()
    # `-l` only shows the placeholder "Custom.WIDTHxHEIGHT"; the real custom value is in plain `-p` output.
    saved = dict(re.findall(r"(\w+)=(\S+)", sh("lpoptions", "-p", printer)[1]))
    result = {}
    for line in out.splitlines():
        m = re.match(r"(\w+)/([^:]*):\s*(.*)", line)
        if not m or m[1] in SKIP:
            continue
        key, text, rest = m[1], m[2], m[3]
        choices, current = [], None
        for tok in rest.split():
            sel = tok.startswith("*")
            tok = tok.lstrip("*")
            if tok.startswith("Custom."):
                if sel:
                    current = saved.get(key, tok) if saved.get(key, "").startswith("Custom.") else tok
                continue
            choices.append(tok)
            if sel:
                current = tok
        names = labels.get(key, (text, {}))[1]
        result[key] = {
            "key": key,
            "label": labels.get(key, (text, {}))[0] or text,
            "choices": [{"value": c, "label": names.get(c, c)} for c in choices],
            "current": current,
            "custom": rest.find("Custom.") >= 0,
            "hint": HINTS.get(key, ""),
        }
    groups, seen = [], set()
    for title, keys in GROUPS:
        items = [result[k] for k in keys if k in result]
        seen.update(k for k in keys if k in result)
        if items:
            groups.append({"title": title, "options": items})
    other = [v for k, v in result.items() if k not in seen]
    if other:
        groups.append({"title": "Other", "options": other})
    return groups


def valid_value(printer, key, value):
    for g in read_options(printer):
        for o in g["options"]:
            if o["key"] == key:
                if o["custom"] and re.fullmatch(r"Custom\.\d+(\.\d+)?x\d+(\.\d+)?(in|mm|cm|pt)?", value):
                    return True
                return value in [c["value"] for c in o["choices"]]
    return False


def printer_state(printer):
    rc, out = sh("lpstat", "-p", printer)
    queue = sh("lpstat", "-o", printer)[1]
    # 0FE6:8800 = 4054:34816
    usb = bool(re.search(r'"idVendor" = 4054\b[\s\S]{0,400}?"idProduct" = 34816\b|"idProduct" = 34816\b[\s\S]{0,400}?"idVendor" = 4054\b',
                         sh("ioreg", "-p", "IOUSB", "-l", "-w0")[1]))
    return {"queue": out if rc == 0 else f"queue {printer} not found", "jobs": queue, "usb": usb}


def action(printer, name, body):
    if name in ("info", "calibrate", "feed", "config", "cancel"):
        rc, out = sh(RP425, name)
        return rc == 0, out or f"{name}: done"
    if name == "send":
        zpl = body.get("zpl", "")
        if not zpl.strip():
            return False, "nothing to send"
        rc, out = sh("lp", "-d", printer, "-o", "raw", "-t", "rp425-ui", input=zpl)
        return rc == 0, out
    if name == "testprint":
        mkpdf = os.path.join(ROOT, "build", "mkpdf")
        if not os.path.exists(mkpdf):
            return False, "build/mkpdf missing — run `make` first"
        with tempfile.TemporaryDirectory() as d:
            pdf = os.path.join(d, "test.pdf")
            rc, out = sh(mkpdf, pdf)
            if rc != 0:
                return False, out
            rc, out = sh("lp", "-d", printer, pdf)
        return rc == 0, out
    if name == "clearqueue":
        rc, out = sh("cancel", "-a", printer)
        return rc == 0, out or "queue cleared"
    return False, f"unknown action {name}"


class Handler(http.server.BaseHTTPRequestHandler):
    printer = "RP425"
    port = 8425

    def log_message(self, *a):
        pass

    def reply(self, code, payload, ctype="application/json"):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def host_ok(self):
        # Blocks DNS-rebinding: this server runs shell commands, so only answer to localhost.
        return self.headers.get("Host", "") in (f"127.0.0.1:{self.port}", f"localhost:{self.port}")

    def do_GET(self):
        if not self.host_ok():
            return self.reply(403, {"error": "bad host"})
        try:
            if self.path == "/":
                return self.reply(200, PAGE.encode(), "text/html; charset=utf-8")
            if self.path == "/api/state":
                return self.reply(200, {"printer": self.printer, "groups": read_options(self.printer),
                                        **printer_state(self.printer)})
            self.reply(404, {"error": "not found"})
        except Exception as e:
            self.reply(500, {"error": str(e)})

    def do_POST(self):
        if not self.host_ok() or self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            return self.reply(403, {"error": "forbidden"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            if self.path == "/api/option":
                key, value = str(body.get("key", "")), str(body.get("value", ""))
                if not valid_value(self.printer, key, value):
                    return self.reply(400, {"error": f"{value!r} is not valid for {key}"})
                rc, out = sh("lpoptions", "-p", self.printer, "-o", f"{key}={value}")
                return self.reply(200 if rc == 0 else 500, {"ok": rc == 0, "message": out or f"{key} = {value}"})
            if self.path == "/api/quit":
                self.reply(200, {"ok": True, "message": "server stopped"})
                return threading.Thread(target=self.server.shutdown).start()
            if self.path == "/api/reset":
                rc, out = sh("lpoptions", "-x", self.printer)
                return self.reply(200, {"ok": rc == 0, "message": out or "reset to queue defaults"})
            if self.path.startswith("/api/action/"):
                ok, msg = action(self.printer, self.path.rsplit("/", 1)[1], body)
                return self.reply(200, {"ok": ok, "message": msg})
            self.reply(404, {"error": "not found"})
        except Exception as e:
            self.reply(500, {"error": str(e)})


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RP425 Settings</title>
<style>
:root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--fg:#1d1d1f;--mute:#6e6e73;--line:#d2d2d7;--accent:#0071e3;--ok:#1a7f37;--err:#c62828}
@media(prefers-color-scheme:dark){:root{--bg:#1c1c1e;--card:#2c2c2e;--fg:#f5f5f7;--mute:#98989d;--line:#48484a;--accent:#2f8cff;--ok:#4cc26b;--err:#ff6b6b}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}
main{max-width:760px;margin:0 auto;padding:24px 16px 80px}
header{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:16px}
h1{font-size:22px;margin:0}
.status{color:var(--mute);font-size:13px}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;background:var(--err)}
.dot.on{background:var(--ok)}
section{background:var(--card);border-radius:12px;padding:4px 16px;margin-bottom:16px;box-shadow:0 1px 2px #0001}
section>h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--mute);margin:12px 0 0}
.row{display:flex;justify-content:space-between;align-items:center;gap:16px;padding:12px 0;border-bottom:1px solid var(--line)}
.row:last-child{border-bottom:0}
.row .name{font-weight:500}.row .hint{color:var(--mute);font-size:12px;margin-top:2px;max-width:420px}
select,input,textarea,button{font:inherit;color:inherit}
select,input[type=number],textarea{background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:6px 10px}
select{min-width:190px}
button{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:7px 14px;cursor:pointer}
button:hover{border-color:var(--accent)}button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
button:disabled{opacity:.5;cursor:default}
.switch{position:relative;width:44px;height:26px;flex:none}
.switch input{opacity:0;position:absolute;inset:0;margin:0;cursor:pointer;z-index:1}
.switch i{position:absolute;inset:0;background:var(--line);border-radius:13px;transition:.15s}
.switch i:after{content:"";position:absolute;top:3px;left:3px;width:20px;height:20px;border-radius:50%;background:#fff;transition:.15s}
.switch input:checked+i{background:var(--accent)}.switch input:checked+i:after{left:21px}
.custom{display:flex;gap:6px;align-items:center;justify-content:flex-end;margin-top:8px}
.custom input{width:78px}
.actions{display:flex;flex-wrap:wrap;gap:8px;padding:12px 0}
textarea{width:100%;height:120px;font:12px ui-monospace,Menlo,monospace;margin-top:12px;resize:vertical}
pre{margin:0 0 12px;white-space:pre-wrap;font:12px ui-monospace,Menlo,monospace;color:var(--mute)}
#toast{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);background:var(--fg);color:var(--bg);padding:9px 16px;border-radius:20px;opacity:0;transition:.2s;pointer-events:none;max-width:90vw}
#toast.show{opacity:1}#toast.bad{background:var(--err);color:#fff}
</style></head><body><main>
<header><div><h1>RP425 Settings</h1><div class="status"><span class="dot" id="dot"></span><span id="queue">…</span></div></div>
<div style="display:flex;gap:8px"><button id="quit" title="Stop the settings server">Quit</button><button id="reset" title="Remove your saved overrides and go back to the queue's defaults">Reset to defaults</button></div></header>
<div id="groups"></div>
<section><h2>Printer</h2>
 <div class="actions">
  <button data-act="testprint" class="primary">Print test label</button>
  <button data-act="feed">Feed one label</button>
  <button data-act="calibrate">Calibrate</button>
  <button data-act="config">Print config label</button>
  <button data-act="info">Device info</button>
  <button data-act="cancel">Flush printer buffer</button>
  <button data-act="clearqueue">Clear CUPS queue</button>
 </div>
 <pre id="out"></pre>
</section>
<section><h2>Raw ZPL</h2>
 <textarea id="zpl" spellcheck="false" placeholder="^XA^FO50,50^A0N,50,50^FDHello^FS^XZ"></textarea>
 <div class="actions"><button id="send">Send to printer</button></div>
</section>
</main><div id="toast"></div>
<script>
const $=s=>document.querySelector(s);
let toastTimer;
function toast(msg,bad){const t=$('#toast');t.textContent=msg;t.className='show'+(bad?' bad':'');clearTimeout(toastTimer);toastTimer=setTimeout(()=>t.className='',2600)}
async function api(path,body){
  const r=await fetch(path,body===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const j=await r.json();if(!r.ok&&!j.message)throw new Error(j.error||r.statusText);return j}
async function setOption(key,value){
  try{const j=await api('/api/option',{key,value});toast(j.ok?`${key} = ${value}`:j.message,!j.ok)}
  catch(e){toast(e.message,true)}
}
function row(o){
  const el=document.createElement('div');el.className='row';
  const left=document.createElement('div');
  left.innerHTML=`<div class="name"></div><div class="hint"></div>`;
  left.querySelector('.name').textContent=o.label;left.querySelector('.hint').textContent=o.hint;
  const right=document.createElement('div');right.style.textAlign='right';
  const vals=o.choices.map(c=>c.value);
  if(vals.length===2&&vals.includes('True')&&vals.includes('False')){
    const sw=document.createElement('label');sw.className='switch';
    sw.innerHTML='<input type="checkbox"><i></i>';const cb=sw.firstChild;cb.checked=o.current==='True';
    cb.onchange=()=>setOption(o.key,cb.checked?'True':'False');right.append(sw);
  }else{
    const sel=document.createElement('select');
    for(const c of o.choices){const op=new Option(c.label,c.value);sel.add(op)}
    const isCustom=o.current&&o.current.startsWith('Custom.');
    if(o.custom)sel.add(new Option('Custom size…','__custom'));
    sel.value=isCustom?'__custom':o.current;
    right.append(sel);
    if(o.custom){
      const m=isCustom&&o.current.match(/^Custom\.([\d.]+)x([\d.]+)(\w*)$/);
      const box=document.createElement('div');box.className='custom';
      box.innerHTML='<input type="number" step="0.01" min="0.5" max="4.1" placeholder="width"> × <input type="number" step="0.01" min="0.5" max="100" placeholder="height"> <select style="min-width:0"><option value="in">in</option><option value="mm">mm</option></select> <button>Set</button>';
      const [w,h]=box.querySelectorAll('input'),u=box.querySelector('select');
      if(m){w.value=m[1];h.value=m[2];u.value=m[3]==='mm'?'mm':'in'}
      box.hidden=!isCustom;right.append(box);
      box.querySelector('button').onclick=()=>{
        if(!(+w.value>0&&+h.value>0))return toast('Enter width and height',true);
        setOption(o.key,`Custom.${w.value}x${h.value}${u.value}`)};
      sel.onchange=()=>{if(sel.value==='__custom'){box.hidden=false;w.focus()}else{box.hidden=true;setOption(o.key,sel.value)}};
    }else sel.onchange=()=>setOption(o.key,sel.value);
  }
  el.append(left,right);return el;
}
async function load(){
  const s=await api('/api/state');
  $('#queue').textContent=s.queue+(s.usb?'':' — printer not seen on USB');
  $('#dot').className='dot'+(s.usb?' on':'');
  const root=$('#groups');root.replaceChildren();
  for(const g of s.groups){
    const sec=document.createElement('section');sec.innerHTML='<h2></h2>';sec.firstChild.textContent=g.title;
    g.options.forEach(o=>sec.append(row(o)));root.append(sec);
  }
}
document.querySelectorAll('[data-act]').forEach(b=>b.onclick=async()=>{
  b.disabled=true;$('#out').textContent='';
  try{const j=await api('/api/action/'+b.dataset.act,{});$('#out').textContent=j.message;toast(j.ok?b.textContent+' ✓':'Failed — see output',!j.ok)}
  catch(e){toast(e.message,true)}finally{b.disabled=false}
});
$('#send').onclick=async()=>{
  try{const j=await api('/api/action/send',{zpl:$('#zpl').value});$('#out').textContent=j.message;toast(j.ok?'Sent':'Failed',!j.ok)}catch(e){toast(e.message,true)}};
$('#reset').onclick=async()=>{if(!confirm('Discard your saved option overrides for this printer?'))return;
  const j=await api('/api/reset',{});toast(j.message,!j.ok);load()};
$('#quit').onclick=async()=>{await api('/api/quit',{}).catch(()=>{});document.body.innerHTML='<p style="padding:40px;font:16px sans-serif">Settings server stopped. You can close this tab.</p>'};
load().catch(e=>{$('#queue').textContent=e.message});
</script></body></html>
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--printer", default="RP425")
    ap.add_argument("--port", type=int, default=8425)
    ap.add_argument("--no-open", action="store_true")
    args = ap.parse_args()
    Handler.printer, Handler.port = args.printer, args.port
    try:
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as e:
        sys.exit(f"rp425-ui: cannot listen on 127.0.0.1:{args.port}: {e}")
    url = f"http://127.0.0.1:{args.port}/"
    print(f"RP425 settings UI at {url}  (Ctrl-C to quit)")
    if not args.no_open:
        threading.Timer(0.3, webbrowser.open, [url]).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
