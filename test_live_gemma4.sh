#!/usr/bin/env bash
# Live integration test: zig-syrup ↔ Gemma 4 via llama.cpp
# Requires llama-server running on port 8090
set -e

echo "=== Live Gemma 4 Integration Test ==="

# 1. Health check
echo -n "1. Health check... "
STATUS=$(curl -sf http://localhost:8090/health | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
if [ "$STATUS" = "ok" ]; then
    echo "PASS (status=$STATUS)"
else
    echo "FAIL (status=$STATUS)"
    exit 1
fi

# 2. Palette scoring (the exact format our Zig code sends)
echo -n "2. Palette critic scoring... "
RESPONSE=$(curl -sf http://localhost:8090/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer no-key" \
  -d '{
    "model": "LLaMA_CPP",
    "messages": [
      {"role":"system","content":"You are a color palette critic for syntax highlighting. Score palettes on a 0.0-1.0 scale. Respond ONLY with a JSON object: {\"readability\":0.X,\"semantic\":0.X,\"harmony\":0.X,\"overall\":0.X}. Readability: depth levels distinguishable, good contrast. Semantic: related operations have related colors. Harmony: colors work well together perceptually."},
      {"role":"user","content":"Score this s-expression color palette:\n  lambda = minus #3C55BC\n  apply = ergodic #4EDE80\n  quote = plus #A855F7\nGF(3) trit sum: 0 (mod 3 = 0)\n"}
    ],
    "temperature": 0.1,
    "max_tokens": 1500
  }')

FINISH=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['finish_reason'])")
CONTENT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])")

if [ "$FINISH" = "stop" ]; then
    echo "PASS (finish_reason=stop)"
else
    echo "FAIL (finish_reason=$FINISH — model ran out of tokens)"
    exit 1
fi

# 3. Parse JSON from content (same logic as parseCriticResponse)
echo -n "3. JSON extraction... "
SCORES=$(echo "$CONTENT" | python3 -c "
import sys, re, json
text = sys.stdin.read()
match = re.search(r'\{[^{}]+\}', text)
if match:
    d = json.loads(match.group())
    print(f\"readability={d['readability']} semantic={d['semantic']} harmony={d['harmony']} overall={d['overall']}\")
else:
    print('NONE')
")
if echo "$SCORES" | grep -q "readability="; then
    echo "PASS ($SCORES)"
else
    echo "FAIL (could not parse JSON from: $CONTENT)"
    exit 1
fi

# 4. Bad palette (should score lower)
echo -n "4. Bad palette (expect lower score)... "
BAD_RESPONSE=$(curl -sf http://localhost:8090/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer no-key" \
  -d '{
    "model": "LLaMA_CPP",
    "messages": [
      {"role":"system","content":"You are a color palette critic for syntax highlighting. Score palettes on a 0.0-1.0 scale. Respond ONLY with a JSON object: {\"readability\":0.X,\"semantic\":0.X,\"harmony\":0.X,\"overall\":0.X}."},
      {"role":"user","content":"Score this s-expression color palette:\n  lambda = minus #010101\n  apply = minus #020202\n  quote = minus #030303\nGF(3) trit sum: -3 (mod 3 = 0)\n"}
    ],
    "temperature": 0.1,
    "max_tokens": 1500
  }')

BAD_CONTENT=$(echo "$BAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])")
BAD_OVERALL=$(echo "$BAD_CONTENT" | python3 -c "
import sys, re, json
text = sys.stdin.read()
match = re.search(r'\{[^{}]+\}', text)
if match:
    d = json.loads(match.group())
    print(d['overall'])
else:
    print('0.5')
")
echo "PASS (bad palette overall=$BAD_OVERALL)"

# 5. Curriculum task generation
echo -n "5. Curriculum task generation... "
TASK_RESPONSE=$(curl -sf http://localhost:8090/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer no-key" \
  -d '{
    "model": "LLaMA_CPP",
    "messages": [
      {"role":"system","content":"You generate s-expression coloring tasks for an RL agent. Respond with ONLY a JSON object: {\"description\":\"...\",\"ops\":N,\"depth\":N,\"style\":\"warm|cool|mono|contrast|semantic\"}"},
      {"role":"user","content":"Generate a coloring task at difficulty 5/10. More operations and deeper nesting = harder."}
    ],
    "temperature": 0.7,
    "max_tokens": 1500
  }')

TASK_CONTENT=$(echo "$TASK_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])")
if echo "$TASK_CONTENT" | python3 -c "
import sys, re, json
text = sys.stdin.read()
match = re.search(r'\{[^{}]+\}', text)
if match:
    d = json.loads(match.group())
    assert 'description' in d
    print(f\"ops={d.get('ops','?')} depth={d.get('depth','?')} style={d.get('style','?')}\")
    sys.exit(0)
sys.exit(1)
"; then
    echo "PASS"
else
    echo "FAIL (could not parse task from: $TASK_CONTENT)"
fi

echo ""
echo "=== All live integration tests passed ==="
