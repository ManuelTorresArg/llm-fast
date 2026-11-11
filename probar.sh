#!/usr/bin/env bash
# Prueba rápida de la API de Ollama. Ejecutar desde la VM (o el host).
#   ./probar.sh [HOST] [MODELO]
# VM con red NAT     -> HOST=10.0.2.2
# VM en modo puente  -> HOST=192.168.10.250
set -euo pipefail
HOST="${1:-10.0.2.2}"
MODEL="${2:-qwen2.5:3b}"
URL="http://$HOST:11434"

echo "== Versión"; curl -fsS "$URL/api/version"; echo
echo "== Modelos instalados"; curl -fsS "$URL/api/tags"; echo
echo "== Generación con $MODEL"
curl -fsS "$URL/api/generate" -d "{\"model\":\"$MODEL\",\"prompt\":\"Explica qué es Docker en una frase.\",\"stream\":false}"
echo
echo "== Endpoint compatible con OpenAI"
curl -fsS "$URL/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Decí hola\"}]}"
echo
