#!/bin/bash
# litellm-router/curl.sh - Test script for the single /v1/ entrypoint with body-based routing

echo "=== Testing Qwen3Coder (model: qwen3coder) ==="
curl -H "Content-Type: application/json" \
  https://inference.llm.bearingpoint.com/v1/chat/completions \
  -d '{"model":"qwen3coder","messages":[{"role":"user","content":"Hello!"}]}'

echo ""

echo "=== Testing DeepSeek (model: deepseek) ==="
curl -H "Content-Type: application/json" \
  https://inference.llm.bearingpoint.com/v1/chat/completions \
  -d '{"model":"deepseek","messages":[{"role":"user","content":"Hello!"}]}'

echo ""