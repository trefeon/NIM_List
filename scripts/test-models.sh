#!/bin/bash

# NVIDIA NIM Model Benchmark Script
# Tests latest code generation models from build.nvidia.com
# Supports parallel execution via MODEL_GROUP environment variable

set -u
set -o pipefail

API_KEY="${NIM_API_KEY:-}"
API_BASE="https://integrate.api.nvidia.com/v1"
MODEL_GROUP="${MODEL_GROUP:-all}"
OUTPUT_FILE="results.json"
HISTORY_FILE="../history.json"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-300}"

PROMPT="Write a Python function that checks if a number is prime and returns True or False"

# All models grouped for parallel execution
ALL_MODELS=(
    "deepseek-ai/deepseek-v4-flash"
    "deepseek-ai/deepseek-v4-pro"
    "deepseek-ai/deepseek-v3.2"
    "z-ai/glm-5.1"
    "z-ai/glm-4.7"
    "minimax/minimax-m2.7"
    "minimax/minimax-m2.5"
    "nvidia/nemotron-3-super-120b-a12b"
    "nvidia/nemotron-4-340b-instruct"
    "nvidia/llama-3.1-nemotron-ultra-253b-v1"
    "moonshotai/kimi-k2.5"
    "moonshotai/kimi-k2-instruct"
    "gpt-oss/gpt-oss-120b"
    "google/gemma-4-31b-it"
    "qwen/qwen3-coder-480b-a35b-instruct"
    "qwen/qwen2.5-coder-32b-instruct"
    "qwen/qwen3.5-397b-a17b"
    "mistralai/devstral-2-123b-instruct-2512"
    "mistralai/mistral-large-3-675b-instruct-2512"
    "meta/llama-3.1-405b-instruct"
)

# Split models into groups for parallel execution
GROUP1_MODELS=(
    "deepseek-ai/deepseek-v4-flash"
    "deepseek-ai/deepseek-v4-pro"
    "deepseek-ai/deepseek-v3.2"
    "z-ai/glm-5.1"
    "z-ai/glm-4.7"
    "minimax/minimax-m2.7"
    "minimax/minimax-m2.5"
    "nvidia/nemotron-3-super-120b-a12b"
    "nvidia/nemotron-4-340b-instruct"
    "nvidia/llama-3.1-nemotron-ultra-253b-v1"
)

GROUP2_MODELS=(
    "moonshotai/kimi-k2.5"
    "moonshotai/kimi-k2-instruct"
    "gpt-oss/gpt-oss-120b"
    "google/gemma-4-31b-it"
    "qwen/qwen3-coder-480b-a35b-instruct"
    "qwen/qwen2.5-coder-32b-instruct"
    "qwen/qwen3.5-397b-a17b"
    "mistralai/devstral-2-123b-instruct-2512"
    "mistralai/mistral-large-3-675b-instruct-2512"
    "meta/llama-3.1-405b-instruct"
)

# Select models based on group
if [ "$MODEL_GROUP" = "group1" ]; then
    MODELS=("${GROUP1_MODELS[@]}")
elif [ "$MODEL_GROUP" = "group2" ]; then
    MODELS=("${GROUP2_MODELS[@]}")
else
    MODELS=("${ALL_MODELS[@]}")
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP_FILES=()

register_tmp_file() {
    TMP_FILES+=("$1")
}

cleanup_tmp_files() {
    for file in "${TMP_FILES[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file"
        fi
    done
}

create_failure_result() {
    local model="$1"
    local error_message="$2"
    python3 - "$model" "$error_message" <<'PY'
import json
import sys

model = sys.argv[1]
error_message = sys.argv[2]

result = {
    "model": model,
    "success": False,
    "error": error_message,
    "responseTime": None,
    "tokensGenerated": None,
    "totalTokens": None,
    "response": None,
}

print(json.dumps(result, separators=(",", ":")))
PY
}

trap cleanup_tmp_files EXIT

echo -e "${YELLOW}Starting NVIDIA NIM Model Benchmarks${MODEL_GROUP:+ (Group: $MODEL_GROUP)}...${NC}"
echo "Timestamp: $TIMESTAMP"
echo "Testing ${#MODELS[@]} models..."
echo ""

if [ -z "$API_KEY" ]; then
    echo -e "${RED}Error: NIM_API_KEY environment variable not set${NC}"
    exit 1
fi

RESULTS_FILE=$(mktemp)
register_tmp_file "$RESULTS_FILE"

for model in "${MODELS[@]}"; do
    echo -e "${YELLOW}Testing: $model${NC}"

    REQUEST_PAYLOAD=$(python3 - "$model" "$PROMPT" <<'PY'
import json
import sys

payload = {
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "temperature": 0.7,
    "top_p": 0.9,
    "max_tokens": 500,
    "stream": False,
}

print(json.dumps(payload))
PY
)

    if [ -z "$REQUEST_PAYLOAD" ]; then
        ERROR="Failed to build request payload"
        echo -e "${RED}  ✗ Failed: $ERROR${NC}"
        MODEL_RESULT="$(create_failure_result "$model" "$ERROR")"
        echo "$MODEL_RESULT" >> "$RESULTS_FILE"
        sleep 0.5
        continue
    fi

    RESPONSE_BODY_FILE=$(mktemp)
    CURL_ERROR_FILE=$(mktemp)
    register_tmp_file "$RESPONSE_BODY_FILE"
    register_tmp_file "$CURL_ERROR_FILE"

    START_TIME=$(date +%s%N)
    HTTP_CODE=$(curl \
        --silent \
        --show-error \
        --max-time "$REQUEST_TIMEOUT_SECONDS" \
        --output "$RESPONSE_BODY_FILE" \
        --write-out "%{http_code}" \
        --request POST \
        "$API_BASE/chat/completions" \
        --header "Authorization: Bearer $API_KEY" \
        --header "Content-Type: application/json" \
        --data "$REQUEST_PAYLOAD" \
        2>"$CURL_ERROR_FILE")
    CURL_EXIT=$?
    END_TIME=$(date +%s%N)
    RESPONSE_TIME=$(( (END_TIME - START_TIME) / 1000000 ))

    if [ "$CURL_EXIT" -ne 0 ]; then
        CURL_MESSAGE=$(head -n 1 "$CURL_ERROR_FILE")
        if [ "$CURL_EXIT" -eq 28 ]; then
            ERROR="Request timed out after ${REQUEST_TIMEOUT_SECONDS}s"
        elif [ -n "$CURL_MESSAGE" ]; then
            ERROR="Curl error (code $CURL_EXIT): $CURL_MESSAGE"
        else
            ERROR="Request failed (curl exit code $CURL_EXIT)"
        fi
        echo -e "${RED}  ✗ Failed: $ERROR${NC}"
        MODEL_RESULT="$(create_failure_result "$model" "$ERROR")"
    else
        MODEL_RESULT=$(python3 - "$model" "$RESPONSE_TIME" "$RESPONSE_BODY_FILE" "$HTTP_CODE" <<'PY'
import json
import sys

model = sys.argv[1]
response_time = int(sys.argv[2])
response_path = sys.argv[3]
http_code = int(sys.argv[4])

def failure(message):
    return {
        "model": model,
        "success": False,
        "error": message,
        "responseTime": None,
        "tokensGenerated": None,
        "totalTokens": None,
        "response": None,
    }

def to_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0

def normalize_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text")
                if isinstance(text, str):
                    parts.append(text)
        return "".join(parts)
    return ""

try:
    with open(response_path, "r", encoding="utf-8") as file:
        raw_body = file.read()
except Exception as exc:
    print(json.dumps(failure(f"Failed to read API response: {exc}"), separators=(",", ":")))
    sys.exit(0)

if not raw_body.strip():
    print(json.dumps(failure("Empty response from API"), separators=(",", ":")))
    sys.exit(0)

try:
    data = json.loads(raw_body)
except json.JSONDecodeError as exc:
    msg = f"Invalid JSON response: {exc.msg} at line {exc.lineno} column {exc.colno}"
    print(json.dumps(failure(msg), separators=(",", ":")))
    sys.exit(0)

error_obj = data.get("error")
error_message = ""
if isinstance(error_obj, dict):
    error_message = str(error_obj.get("message") or "").strip()
elif isinstance(error_obj, str):
    error_message = error_obj.strip()

if http_code >= 400:
    if not error_message:
        error_message = f"HTTP {http_code} returned by API"
    else:
        error_message = f"HTTP {http_code}: {error_message}"
    print(json.dumps(failure(error_message), separators=(",", ":")))
    sys.exit(0)

if error_message:
    print(json.dumps(failure(error_message), separators=(",", ":")))
    sys.exit(0)

choices = data.get("choices")
content = ""
if isinstance(choices, list) and choices:
    first_choice = choices[0]
    if isinstance(first_choice, dict):
        message = first_choice.get("message")
        if isinstance(message, dict):
            content = normalize_content(message.get("content"))

if not content.strip():
    print(json.dumps(failure("No content in response"), separators=(",", ":")))
    sys.exit(0)

usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
completion_tokens = to_int(usage.get("completion_tokens"))
total_tokens = to_int(usage.get("total_tokens"))

result = {
    "model": model,
    "success": True,
    "responseTime": response_time,
    "tokensGenerated": completion_tokens,
    "totalTokens": total_tokens,
    "response": content,
    "error": None,
}

print(json.dumps(result, separators=(",", ":")))
PY
)
    fi

    MODEL_SUCCESS=$(echo "$MODEL_RESULT" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("success") else "0")' 2>/dev/null || echo "0")
    if [ "$MODEL_SUCCESS" = "1" ]; then
        TOKENS_GENERATED=$(echo "$MODEL_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tokensGenerated") or 0)' 2>/dev/null || echo "0")
        echo -e "${GREEN}  ✓ Success (${RESPONSE_TIME}ms, ${TOKENS_GENERATED} tokens)${NC}"
    else
        ERROR_MESSAGE=$(echo "$MODEL_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error") or "Unknown error")' 2>/dev/null || echo "Unknown error")
        echo -e "${RED}  ✗ Failed: ${ERROR_MESSAGE}${NC}"
    fi

    echo "$MODEL_RESULT" >> "$RESULTS_FILE"
    sleep 0.5
done

echo ""
echo -e "${YELLOW}Compiling results...${NC}"

python3 - "$TIMESTAMP" "$PROMPT" "$RESULTS_FILE" > "$OUTPUT_FILE" <<'PY'
import json
import sys

timestamp = sys.argv[1]
prompt = sys.argv[2]
results_file = sys.argv[3]

models = []
with open(results_file, "r", encoding="utf-8") as file:
    for line_number, line in enumerate(file, start=1):
        line = line.strip()
        if not line:
            continue
        try:
            models.append(json.loads(line))
        except json.JSONDecodeError:
            models.append(
                {
                    "model": f"internal/parse-error-line-{line_number}",
                    "success": False,
                    "error": "Failed to parse intermediate result JSON",
                    "responseTime": None,
                    "tokensGenerated": None,
                    "totalTokens": None,
                    "response": None,
                }
            )

successful = [model for model in models if model.get("success")]
success_count = len(successful)
total_count = len(models)

if successful:
    fastest = min(
        successful,
        key=lambda item: item.get("responseTime") if isinstance(item.get("responseTime"), int) else float("inf"),
    )
    fastest_model = fastest.get("model", "N/A")
    fastest_time = fastest.get("responseTime", 0) or 0
else:
    fastest_model = "N/A"
    fastest_time = 0

final_result = {
    "timestamp": timestamp,
    "prompt": prompt,
    "models": models,
    "summary": {
        "successCount": success_count,
        "totalModels": total_count,
        "fastestModel": fastest_model,
        "fastestTime": fastest_time,
    },
}

print(json.dumps(final_result, indent=2))
PY

if [ ! -s "$OUTPUT_FILE" ]; then
    echo -e "${RED}Failed to generate ${OUTPUT_FILE}${NC}"
    exit 1
fi

echo -e "${GREEN}Results saved to $OUTPUT_FILE${NC}"
SUMMARY=$(python3 - "$OUTPUT_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as file:
        data = json.load(file)
    summary = data.get("summary", {})
    success = int(summary.get("successCount", 0))
    total = int(summary.get("totalModels", 0))
except Exception:
    success = 0
    total = 0

print(f"{success}/{total}")
PY
)
echo "Summary: ${SUMMARY} successful"

# Only update history for full runs (not parallel groups)
if [ "$MODEL_GROUP" = "all" ] || [ -z "$MODEL_GROUP" ]; then
    python3 - "$HISTORY_FILE" "$OUTPUT_FILE" <<'PY'
import json
import sys

history_path = sys.argv[1]
result_path = sys.argv[2]

with open(result_path, "r", encoding="utf-8") as file:
    new_run = json.load(file)

try:
    with open(history_path, "r", encoding="utf-8") as file:
        history = json.load(file)
except Exception:
    history = {"runs": []}

runs = history.get("runs")
if not isinstance(runs, list):
    runs = []

runs.insert(0, new_run)
history["runs"] = runs[:720]

with open(history_path, "w", encoding="utf-8") as file:
    json.dump(history, file, indent=2)
PY
    echo -e "${GREEN}History updated: $HISTORY_FILE${NC}"
fi
