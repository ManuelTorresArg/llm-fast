# Ollama en Docker para pruebas desde una VM de VirtualBox

## Levantar
Correr esto en el equipo donde está Docker (el host, no la VM que consume la API):
```bash
./detectar.sh                 # detecta el hardware y genera .env y compose.override.yaml
docker compose up -d          # toma los dos archivos automáticamente
docker exec ollama ollama pull qwen2.5:3b   # o el modelo que haya sugerido detectar.sh
./detectar.sh --probar        # mide tokens/s y cuánto del modelo entró en GPU
```
Sin correr `detectar.sh`, `docker compose up -d` levanta una configuración básica solo con CPU.

### Qué ajusta `detectar.sh`
| Detecta | Ajusta |
|---|---|
| GPU NVIDIA, AMD, Intel o ninguna | Backend (`nvidia`, `rocm`, `vulkan` o `cpu`), imagen y dispositivos |
| Grupos de `/dev/dri` y `/dev/kfd` | `group_add` del contenedor |
| VRAM y RAM totales | Tope de memoria, contexto, paralelismo y compresión de la caché de contexto |
| Memoria, hilos de CPU y disco | Modelo sugerido |
| VRAM y RAM libres en ese momento | Solo avisos: no cambian la configuración |

Opciones: `--dry-run` muestra el resultado sin escribir nada y `--backend X` fuerza un backend. Si ya existen, `.env` y `compose.override.yaml` se guardan antes como `.bak`.

NVIDIA requiere `nvidia-container-toolkit` en el host. Las GPU Intel quedan en CPU salvo que se fuerce `--backend vulkan`.

`compose.vulkan.yaml` es la versión manual anterior: tiene fijos los grupos del host original, así que en otro equipo conviene usar `detectar.sh`.

## Modelos
```bash
docker exec ollama ollama pull qwen2.5:3b     # ya descargado
docker exec ollama ollama pull llama3.2:3b
docker exec ollama ollama pull qwen2.5:7b     # entra justo en los ~4.6 GB libres de VRAM
docker exec ollama ollama list
docker exec ollama ollama ps                  # muestra si corre en GPU o CPU
```

## Desde la VM
| Red de la VM en VirtualBox | URL de Ollama                  |
|----------------------------|--------------------------------|
| NAT (por defecto)          | http://10.0.2.2:11434          |
| Adaptador puente           | http://192.168.10.250:11434    |

```bash
./probar.sh 10.0.2.2 qwen2.5:3b
```
Clientes compatibles con OpenAI: `base_url=http://10.0.2.2:11434/v1`, `api_key=ollama` (cualquier valor).

## Notas
- El puerto 11434 queda abierto en todas las interfaces y **sin autenticación**. Docker se salta ufw.
  Para limitarlo, cambiá `0.0.0.0:11434` por la IP de una interfaz concreta en `compose.yaml`.
- Los modelos se guardan en el volumen `ollama_ollama-data` (`docker volume rm` para liberar espacio).
- Apagar: `docker compose down`
