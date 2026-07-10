curl -H "Content-Type: application/json" https://qwen3.llm.bearingpoint.com/openai/v1/chat/completions -d @./chat-input.json

curl -H "Content-Type: application/json" https://inference.llm.bearingpoint.com/kserve-qwen3coder/qwen3coder/v1/chat/completions -d @./chat-input.json
