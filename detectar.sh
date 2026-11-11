#!/usr/bin/env bash
# Detecta el hardware del equipo donde corre Docker y genera la configuración
# óptima de Ollama para ese equipo: .env y compose.override.yaml.
# `docker compose up -d` toma los dos archivos solo.
#
#   ./detectar.sh                 detecta y escribe los archivos
#   ./detectar.sh --dry-run       muestra el resultado sin escribir nada
#   ./detectar.sh --backend X     fuerza nvidia, rocm, vulkan o cpu
#   ./detectar.sh --probar [MOD]  mide tokens/s y uso de GPU con Ollama ya levantado
#
# Debe ejecutarse donde corre Docker (el host), no en una VM que solo consume la API.
set -euo pipefail

# Rutas sobreescribibles para poder probar otros escenarios de hardware.
SYS_DRM="${SYS_DRM:-/sys/class/drm}"
DEV_DRI="${DEV_DRI:-/dev/dri}"
DEV_KFD="${DEV_KFD:-/dev/kfd}"
PROC_MEMINFO="${PROC_MEMINFO:-/proc/meminfo}"

# Chips AMD con soporte oficial de ROCm en Ollama. El resto va por Vulkan.
ROCM_SOPORTADO='Navi (21|31|32|33)|Vega 10'

# modelo:MiB necesarios en memoria:MiB en disco, de menor a mayor.
MODELOS=(
  qwen2.5:0.5b:600:400
  qwen2.5:1.5b:1300:1000
  qwen2.5:3b:2560:1900
  qwen2.5:7b:5632:4700
  qwen2.5:14b:10752:9000
  qwen2.5:32b:23552:20000
)
DISCO_MARGEN=2048

salida_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dry_run=0
backend_forzado=""
avisos=()

morir() { echo "Error: $*" >&2; exit 1; }
avisar() { avisos+=("$*"); }

docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

nvidia_runtime() {
  docker_ok && docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'
}

detectar_gpu() {
  gpu_tipo=ninguna gpu_nombre="" vram_total=0 vram_libre=0

  local datos linea
  if command -v nvidia-smi >/dev/null 2>&1 &&
     datos=$(nvidia-smi --query-gpu=memory.total,memory.free,name \
             --format=csv,noheader,nounits 2>/dev/null) && [[ -n $datos ]]; then
    linea=$(sort -t, -k1,1nr <<<"$datos" | sed -n 1p)
    IFS=, read -r vram_total vram_libre gpu_nombre <<<"$linea"
    vram_total=${vram_total// /} vram_libre=${vram_libre// /}
    gpu_nombre=${gpu_nombre# }
    gpu_tipo=nvidia
    return
  fi

  local card vendor total usada slot
  for card in "$SYS_DRM"/card*; do
    [[ $(basename "$card") =~ ^card[0-9]+$ && -r $card/device/vendor ]] || continue
    vendor=$(<"$card/device/vendor")
    case $vendor in
      0x1002)
        total=0 usada=0
        [[ -r $card/device/mem_info_vram_total ]] &&
          total=$(( $(<"$card/device/mem_info_vram_total") / 1048576 ))
        [[ -r $card/device/mem_info_vram_used ]] &&
          usada=$(( $(<"$card/device/mem_info_vram_used") / 1048576 ))
        # Menos de 1 GiB dedicado: es una APU, que Ollama ignora por defecto.
        if (( total >= 1024 && total > vram_total )); then
          gpu_tipo=amd vram_total=$total vram_libre=$(( total - usada ))
        else
          continue
        fi
        ;;
      0x8086)
        [[ $gpu_tipo == ninguna ]] && gpu_tipo=intel || continue
        ;;
      *) continue ;;
    esac
    if command -v lspci >/dev/null 2>&1; then
      slot=$(basename "$(readlink -f "$card/device")")
      gpu_nombre=$(lspci -s "$slot" 2>/dev/null | sed 's/^[^ ]* [^:]*: //') || true
    fi
  done
}

elegir_backend() {
  if [[ -n $backend_forzado ]]; then
    backend=$backend_forzado
    case $backend in
      nvidia) nvidia_runtime || morir "Docker no tiene el runtime de NVIDIA (nvidia-container-toolkit)." ;;
      rocm)   [[ -e $DEV_KFD ]] || morir "no existe $DEV_KFD, ROCm no puede funcionar." ;;
      vulkan) [[ -d $DEV_DRI ]] || morir "no existe $DEV_DRI, Vulkan no puede funcionar." ;;
      cpu)    ;;
      *)      morir "backend desconocido: $backend (usá nvidia, rocm, vulkan o cpu)." ;;
    esac
    return
  fi

  case $gpu_tipo in
    nvidia)
      if nvidia_runtime; then
        backend=nvidia
      else
        backend=cpu
        avisar "Hay GPU NVIDIA pero Docker no tiene su runtime: instalá nvidia-container-toolkit y volvé a correr esto."
      fi
      ;;
    amd)
      if [[ -e $DEV_KFD && $gpu_nombre =~ $ROCM_SOPORTADO ]]; then
        backend=rocm
      else
        backend=vulkan
      fi
      ;;
    intel)
      backend=cpu
      avisar "GPU Intel detectada: queda en CPU porque su aceleración no es confiable. Para intentarlo: --backend vulkan."
      ;;
    *) backend=cpu ;;
  esac
}

leer_sistema() {
  ram_total=$(awk '/^MemTotal:/ {print int($2/1024)}' "$PROC_MEMINFO")
  ram_libre=$(awk '/^MemAvailable:/ {print int($2/1024)}' "$PROC_MEMINFO")
  hilos=$(nproc)

  local raiz=/
  if docker_ok; then
    raiz=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)
  else
    avisar "No pude consultar Docker: revisá que esté instalado y que tu usuario tenga permisos."
  fi
  [[ -e $raiz ]] || raiz=/
  disco_libre=$(df -BM --output=avail "$raiz" 2>/dev/null | sed -n 2p | tr -dc 0-9)
  disco_libre=${disco_libre:-0}

  if grep -qs '^flags.* hypervisor' /proc/cpuinfo; then
    avisar "Este equipo es una máquina virtual: si Docker corre en el host, ejecutá este script allá."
  fi
}

calcular() {
  # La configuración se basa en la capacidad total, que no cambia. La memoria
  # libre fluctúa con lo que esté abierto, y solo se usa para avisar.
  local porcentaje=40
  [[ $backend == cpu ]] && porcentaje=60
  local limite=$(( ram_total * porcentaje / 100 ))
  (( limite < 2048 )) && limite=2048
  mem_limit="$(( limite / 1024 ))g"
  limite=$(( limite / 1024 * 1024 ))

  if [[ $backend == cpu ]]; then
    capacidad=$limite
  elif (( vram_total > 0 )); then
    capacidad=$(( vram_total * 75 / 100 ))
  else
    capacidad=3072
    avisar "No pude leer la VRAM de esta GPU: asumo 3 GB utilizables."
  fi

  tag=latest
  [[ $backend == rocm ]] && tag=rocm

  num_parallel=1 max_loaded=1
  if [[ $backend != cpu ]]; then
    (( capacidad >= 16384 )) && num_parallel=2
    (( capacidad >= 32768 )) && num_parallel=4
    (( capacidad >= 24576 )) && max_loaded=2
  fi

  if [[ $backend == cpu ]]; then
    contexto=4096
    (( capacidad >= 8192 )) && contexto=8192
  elif (( capacidad < 3072 )); then
    contexto=4096
  elif (( capacidad < 8192 )); then
    contexto=8192
  elif (( capacidad < 16384 )); then
    contexto=16384
  else
    contexto=32768
  fi

  flash=false kv_cache=""
  if [[ $backend != cpu ]] && (( vram_total > 0 && vram_total <= 8192 )); then
    flash=true kv_cache=q8_0
  fi

  # En CPU el límite real es la velocidad: con pocos hilos un modelo grande es inutilizable.
  local tope_cpu=$capacidad
  if [[ $backend == cpu ]]; then
    if (( hilos <= 4 )); then
      tope_cpu=2560
    elif (( hilos <= 8 )); then
      tope_cpu=5632
    else
      tope_cpu=10752
    fi
  fi

  modelo="" modelo_alt="" modelo_mem=0
  local m nombre tam resto mem disco
  for m in "${MODELOS[@]}"; do
    nombre=${m%%:*}; resto=${m#*:}
    tam=${resto%%:*}; resto=${resto#*:}
    mem=${resto%%:*}; disco=${resto#*:}
    nombre="$nombre:$tam"
    (( mem <= capacidad && mem <= tope_cpu && disco + DISCO_MARGEN <= disco_libre )) || continue
    modelo_alt=$modelo
    modelo=$nombre modelo_mem=$mem
  done

  if [[ -z $modelo ]]; then
    avisar "Ningún modelo de la lista entra en este equipo (memoria o disco insuficientes)."
    modelo=ninguno
  fi
  if [[ $backend != cpu ]] && (( vram_total > 0 && vram_libre < modelo_mem )); then
    avisar "Ahora hay solo $vram_libre MiB de VRAM libres y $modelo necesita ~$modelo_mem MiB: si no cerrás programas, parte del modelo irá a CPU y será más lento."
  fi
  if (( ram_libre < limite )); then
    avisar "Hay $ram_libre MiB de RAM disponibles, menos que el tope del contenedor ($mem_limit)."
  fi
  if (( disco_libre < 10240 )); then
    avisar "Queda poco disco para Docker: $(( disco_libre / 1024 )) GB libres."
  fi
}

gids_dispositivos() {
  local d
  { for d in "$DEV_DRI"/card* "$DEV_DRI"/renderD* ${1:+"$1"}; do
      [[ -e $d ]] && stat -c %g "$d"
    done; } | sort -un | grep -vx 0 || true
}

generar_env() {
  cat <<EOF
# Generado por detectar.sh el $(date +%F). Volvé a correrlo si cambia el hardware.
OLLAMA_TAG=$tag
OLLAMA_MEM_LIMIT=$mem_limit
OLLAMA_NUM_PARALLEL=$num_parallel
OLLAMA_MAX_LOADED_MODELS=$max_loaded
OLLAMA_CONTEXT_LENGTH=$contexto
OLLAMA_FLASH_ATTENTION=$flash
OLLAMA_KV_CACHE_TYPE=$kv_cache
MODELO_RECOMENDADO=$modelo
EOF
}

generar_override() {
  echo "# Generado por detectar.sh el $(date +%F). Backend: $backend."
  echo "services:"
  local g
  case $backend in
    nvidia)
      cat <<'EOF'
  ollama:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
EOF
      ;;
    vulkan)
      cat <<EOF
  ollama:
    devices:
      - $DEV_DRI:/dev/dri
    environment:
      OLLAMA_VULKAN: "1"
    group_add:
EOF
      for g in $(gids_dispositivos); do echo "      - \"$g\""; done
      ;;
    rocm)
      cat <<EOF
  ollama:
    devices:
      - $DEV_KFD:/dev/kfd
      - $DEV_DRI:/dev/dri
    group_add:
EOF
      for g in $(gids_dispositivos "$DEV_KFD"); do echo "      - \"$g\""; done
      ;;
    cpu)
      echo "  ollama: {}"
      ;;
  esac
}

escribir() {
  local f
  for f in .env compose.override.yaml; do
    [[ -e $salida_dir/$f ]] && cp -p "$salida_dir/$f" "$salida_dir/$f.bak"
  done
  generar_env > "$salida_dir/.env"
  generar_override > "$salida_dir/compose.override.yaml"
}

resumen() {
  echo "== Hardware"
  echo "GPU:   ${gpu_nombre:-ninguna} ($gpu_tipo)"
  (( vram_total > 0 )) && echo "VRAM:  $vram_total MiB en total, $vram_libre MiB libres ahora"
  echo "RAM:   $ram_total MiB en total, $ram_libre MiB disponibles ahora"
  echo "CPU:   $hilos hilos"
  echo "Disco: $(( disco_libre / 1024 )) GB libres para Docker"
  echo
  echo "== Configuración"
  echo "Backend:      $backend (imagen ollama/ollama:$tag)"
  echo "Tope de RAM:  $mem_limit"
  echo "Contexto:     $contexto tokens"
  echo "Paralelismo:  $num_parallel petición(es), $max_loaded modelo(s) cargado(s)"
  echo "Compresión:   flash attention=$flash, KV cache=${kv_cache:-por defecto}"
  echo
  echo "== Modelo sugerido"
  echo "$modelo${modelo_alt:+ (alternativa más liviana: $modelo_alt)}"
  if (( ${#avisos[@]} > 0 )); then
    echo
    echo "== Avisos"
    printf -- '- %s\n' "${avisos[@]}"
  fi
}

probar() {
  local modelo_prueba=${1:-} url=http://localhost:11434
  if [[ -z $modelo_prueba && -r $salida_dir/.env ]]; then
    modelo_prueba=$(sed -n 's/^MODELO_RECOMENDADO=//p' "$salida_dir/.env")
  fi
  [[ -n $modelo_prueba && $modelo_prueba != ninguno ]] ||
    morir "indicá un modelo: --probar MODELO"
  curl -fsS -m 5 "$url/api/version" >/dev/null ||
    morir "Ollama no responde en $url. Levantalo con: docker compose up -d"
  curl -fsS -m 5 "$url/api/tags" | grep -qF "\"name\":\"$modelo_prueba\"" ||
    morir "$modelo_prueba no está descargado. Bajalo con: docker exec ollama ollama pull $modelo_prueba"

  echo "Generando con $modelo_prueba..."
  local r n d ps fila size vram
  r=$(curl -fsS "$url/api/generate" -d "{\"model\":\"$modelo_prueba\",\"prompt\":\"Contá en detalle qué es un contenedor.\",\"stream\":false,\"options\":{\"num_predict\":128}}")
  n=$(grep -o '"eval_count":[0-9]*' <<<"$r" | cut -d: -f2)
  d=$(grep -o '"eval_duration":[0-9]*' <<<"$r" | cut -d: -f2)
  ps=$(curl -fsS "$url/api/ps")
  fila=$(sed 's/{"name"/\n&/g' <<<"$ps" | grep -F "\"name\":\"$modelo_prueba\"" | sed -n 1p)
  size=$(grep -o '"size":[0-9]*' <<<"$fila" | cut -d: -f2)
  vram=$(grep -o '"size_vram":[0-9]*' <<<"$fila" | cut -d: -f2 || true)
  vram=${vram:-0}

  awk -v n="$n" -v d="$d" 'BEGIN { printf "Velocidad: %.1f tokens/s\n", n / (d / 1e9) }'
  awk -v s="$size" -v v="$vram" 'BEGIN { printf "En GPU:    %.0f%% de %.1f GB\n", 100 * v / s, s / 1073741824 }'
  if (( vram < size )); then
    echo "El modelo no entró completo en GPU: cerrá programas que usen VRAM o probá uno más chico."
  fi
}

modo_probar=0 modelo_arg=""
while (( $# > 0 )); do
  case $1 in
    --dry-run) dry_run=1 ;;
    --backend) (( $# >= 2 )) || morir "--backend necesita un valor"; backend_forzado=$2; shift ;;
    --salida)  (( $# >= 2 )) || morir "--salida necesita un valor"; salida_dir=$2; shift ;;
    --probar)
      modo_probar=1
      if (( $# >= 2 )) && [[ $2 != --* ]]; then modelo_arg=$2; shift; fi
      ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) morir "opción desconocida: $1" ;;
  esac
  shift
done

if (( modo_probar )); then
  probar "$modelo_arg"
  exit 0
fi

detectar_gpu
elegir_backend
leer_sistema
calcular
resumen

if (( dry_run )); then
  echo; echo "--- .env"; generar_env
  echo; echo "--- compose.override.yaml"; generar_override
else
  escribir
  echo
  echo "Listo: se escribieron .env y compose.override.yaml en $salida_dir."
  echo "Aplicar:     docker compose up -d"
  [[ $modelo != ninguno ]] && echo "Bajar modelo: docker exec ollama ollama pull $modelo"
  echo "Medir:       ./detectar.sh --probar"
fi
