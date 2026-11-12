#!/usr/bin/env python3
"""GUI mínima para consultar Ollama desde el navegador.

Uso: ./gui.py [--ollama http://localhost:11434] [--puerto 8080]
Sirve la página y reenvía /api/* a Ollama, así no hay problemas de CORS.
Solo usa la biblioteca estándar.
"""
import argparse
import http.server
import urllib.error
import urllib.request

PAGINA = """<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ollama</title>
<style>
  :root { color-scheme: light dark; --borde: #8884; }
  body { font: 15px/1.5 system-ui, sans-serif; margin: 0; display: flex; flex-direction: column; height: 100vh; }
  header, form { display: flex; gap: .5rem; padding: .6rem 1rem; border-bottom: 1px solid var(--borde); align-items: center; }
  form { border: 0; border-top: 1px solid var(--borde); }
  #chat { flex: 1; overflow-y: auto; padding: 1rem; max-width: 50rem; width: 100%; box-sizing: border-box; margin: 0 auto; }
  .msg { white-space: pre-wrap; padding: .6rem .8rem; border-radius: 8px; margin: .5rem 0; border: 1px solid var(--borde); }
  .user { background: #4a90e222; margin-left: 15%; }
  .assistant { margin-right: 15%; }
  .info { font-size: 12px; opacity: .6; }
  textarea { flex: 1; resize: none; font: inherit; padding: .5rem; height: 3.2rem; }
  button, select { font: inherit; padding: .4rem .8rem; }
  .sp { flex: 1; }
</style></head><body>
<header>
  <strong>Ollama</strong>
  <select id="modelo"></select>
  <span class="sp"></span>
  <span id="estado" class="info"></span>
  <button id="limpiar" type="button">Nueva conversación</button>
</header>
<div id="chat"></div>
<form id="form">
  <textarea id="texto" placeholder="Escribí tu consulta (Enter envía, Shift+Enter nueva línea)" autofocus></textarea>
  <button id="enviar">Enviar</button>
</form>
<script>
const $ = (id) => document.getElementById(id);
let historial = [], control = null;

async function cargarModelos() {
  try {
    const r = await fetch("/api/tags");
    const { models } = await r.json();
    $("modelo").innerHTML = models.map(m => `<option>${m.name}</option>`).join("");
    $("estado").textContent = models.length ? "" : "No hay modelos descargados";
  } catch (e) { $("estado").textContent = "No se pudo conectar con Ollama"; }
}

function agregar(rol, texto) {
  const d = document.createElement("div");
  d.className = "msg " + rol;
  d.textContent = texto;
  $("chat").appendChild(d);
  $("chat").scrollTop = $("chat").scrollHeight;
  return d;
}

async function enviar() {
  if (control) { control.abort(); return; }
  const texto = $("texto").value.trim();
  if (!texto || !$("modelo").value) return;
  $("texto").value = "";
  historial.push({ role: "user", content: texto });
  agregar("user", texto);
  const caja = agregar("assistant", "…");
  let respuesta = "";
  control = new AbortController();
  $("enviar").textContent = "Detener";
  try {
    const r = await fetch("/api/chat", {
      method: "POST", signal: control.signal,
      body: JSON.stringify({ model: $("modelo").value, messages: historial, stream: true }),
    });
    if (!r.ok) throw new Error(await r.text());
    const lector = r.body.getReader(), dec = new TextDecoder();
    let buf = "";
    for (;;) {
      const { value, done } = await lector.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lineas = buf.split("\\n"); buf = lineas.pop();
      for (const l of lineas) {
        if (!l.trim()) continue;
        const j = JSON.parse(l);
        if (j.error) throw new Error(j.error);
        respuesta += j.message?.content || "";
        caja.textContent = respuesta;
        $("chat").scrollTop = $("chat").scrollHeight;
        if (j.done && j.eval_duration)
          $("estado").textContent = (j.eval_count / j.eval_duration * 1e9).toFixed(1) + " tokens/s";
      }
    }
  } catch (e) {
    if (e.name !== "AbortError") respuesta += "\\n[Error: " + e.message + "]";
    caja.textContent = respuesta || "[sin respuesta]";
  }
  historial.push({ role: "assistant", content: respuesta });
  control = null;
  $("enviar").textContent = "Enviar";
}

$("form").onsubmit = (e) => { e.preventDefault(); enviar(); };
$("texto").onkeydown = (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); enviar(); } };
$("limpiar").onclick = () => { if (control) control.abort(); historial = []; $("chat").innerHTML = ""; };
cargarModelos();
</script></body></html>
"""


class Manejador(http.server.BaseHTTPRequestHandler):
    ollama = "http://localhost:11434"

    def do_GET(self):
        if self.path.startswith("/api/"):
            return self.reenviar()
        cuerpo = PAGINA.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)

    def do_POST(self):
        if not self.path.startswith("/api/"):
            return self.send_error(404)
        self.reenviar()

    def reenviar(self):
        largo = int(self.headers.get("Content-Length") or 0)
        datos = self.rfile.read(largo) if largo else None
        pedido = urllib.request.Request(self.ollama + self.path, data=datos, method=self.command,
                                        headers={"Content-Type": "application/json"})
        try:
            resp = urllib.request.urlopen(pedido, timeout=600)
        except urllib.error.HTTPError as e:
            resp = e
        except OSError as e:
            return self.send_error(502, f"Ollama no responde: {e}")
        self.send_response(resp.status)
        self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
        self.end_headers()
        try:
            # Se reenvía de a líneas para que el streaming llegue en vivo.
            for linea in iter(resp.readline, b""):
                self.wfile.write(linea)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # El usuario apretó "Detener".
        finally:
            resp.close()
        self.close_connection = True

    def log_message(self, fmt, *args):
        pass


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--ollama", default="http://localhost:11434", help="URL de Ollama")
    p.add_argument("--host", default="127.0.0.1", help="interfaz donde escuchar (0.0.0.0 para todas)")
    p.add_argument("--puerto", type=int, default=8080)
    a = p.parse_args()
    Manejador.ollama = a.ollama.rstrip("/")
    servidor = http.server.ThreadingHTTPServer((a.host, a.puerto), Manejador)
    print(f"GUI en http://{a.host}:{a.puerto}  ->  Ollama en {Manejador.ollama}")
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
