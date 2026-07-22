# litellm-router/README.md
# litellm-based Single /v1/ Endpoint with Body-Based Model Selection
# 
# This directory contains the configuration for a single OpenAI-compatible
# API endpoint at https://inference.llm.bearingpoint.com/v1/chat/completions
#
# Model selection is done via the JSON request body, NOT the URL path.
#
# Usage:
#   POST /v1/chat/completions
#   Body: {"model": "qwen3coder", "messages": [...]}  -> routes to qwen3coder
#   Body: {"model": "deepseek", "messages": [...]}     -> routes to deepseek
#
# Architecture:
#   1. HTTPRoute exposes /v1/ to inference.llm.bearingpoint.com
#   2. litellm receives OpenAI-compatible request
#   3. litellm reads model from request body and routes to appropriate backend
#   4. litellm proxies the request to the correct LLM service
#
# Why litellm?
#   - Purpose-built for OpenAI-compatible routing
#   - Handles model mapping natively
#   - Production-ready proxy solution
#   - Easy to add new models via config
#
# Adding a new model:
#   1. Create namespace.yaml for the model (if not exists)
#   2. Create LLMInferenceService for the model
#   3. Update litellm-config.yaml: Add new model entry to model_list
#   4. Apply: kubectl apply -f litellm-router/litellm-config.yaml
#   5. litellm will auto-reload the config (no restart needed in most cases)
#
# Current models:
#   - qwen3coder (routes when model="qwen3coder")
#   - qwen (routes when model="qwen")
#   - deepseek (routes when model="deepseek")