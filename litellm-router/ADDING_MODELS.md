# Adding a new model to litellm:

# 1. Create model directory (if not exists)
#    cd to your model directory (e.g., gemma/)
#    Ensure you have: namespace.yaml, LLMInferenceService, LocalModelCache

# 2. Update litellm-config.yaml
#    Add a new entry to model_list:
#
#    - model_name: gemma
#      litellm_params:
#        model: openai/gemma
#        api_base: http://gemma-kserve-workload-svc.kserve-gemma.svc.cluster.local:8000/v1
#        api_key: dummy

# 3. Apply the updated config
#    kubectl apply -f litellm-router/litellm-config.yaml
#    kubectl rollout restart deployment/litellm -n kserve-litellm-router

# 4. Test the new model
#    curl -H "Content-Type: application/json" \
#      https://inference.llm.bearingpoint.com/v1/chat/completions \
#      -d '{"model":"gemma","messages":[{"role":"user","content":"Hello!"}]}'

# Current available models:
# - qwen3coder (routes when model="qwen3coder" or model="qwen")
# - deepseek (routes when model="deepseek")