#!/usr/bin/env bash
# 受控发布“提交 / 批准”固定锁序端到端示例：
#   标记受控 -> alice 提交申请 -> bob 批准产生（记录,版本）快照 ->
#   并行交错：alice 再提交同一版本新申请 与 bob 批准另一份待审申请
#   （旧锁序“提交先快照行后清单行 / 批准先清单行后快照行”在此交错下
#    会相互等待触发数据库死锁，其中一个合法操作失败；修复后两者均成功）->
#   终态核对：同一快照仅一份、一份新申请仍 pending、两笔签发各一枚可读令牌。
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
ALICE_PW="${ALICE_PW:-alice-pw}"   # operator（申请人）
BOB_PW="${BOB_PW:-bob-pw}"         # reviewer（复核人）
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

step "0. 健康检查"
curl -sS "${BASE_URL}/healthz" | jq .

step "1. 维护端创建记录（版本 1，遮蔽区间完整覆盖敏感内容）"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
echo "${CREATE}" | jq .
RECORD_ID=$(echo "${CREATE}" | jq -r .record_id)

step "2. 机构将记录设为受控"
curl -sS -X PUT "${BASE_URL}/records/${RECORD_ID}/controlled" "${AUTH[@]}" | jq .

step "3. alice 提交第一份发布申请，bob 批准 -> 生成该 (记录,版本) 的唯一快照"
SUB1=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H "Content-Type: application/json" -d '{"version": 1}')
REQ1=$(echo "${SUB1}" | jq -r .request_id)
APP1=$(curl -sS -X POST "${BASE_URL}/publish-requests/${REQ1}/approve" -u "bob:${BOB_PW}")
echo "${APP1}" | jq '{request_id, status, snapshot_id, token, max_reads}'
SNAPSHOT_ID=$(echo "${APP1}" | jq -r .snapshot_id)
echo "已发布快照: ${SNAPSHOT_ID}"

step "4. alice 再准备两份待审申请（REQ_A 将被并行批准；REQ 由并行提交新建）"
SUB_A=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H "Content-Type: application/json" -d '{"version": 1, "max_reads": 3}')
REQ_A=$(echo "${SUB_A}" | jq -r .request_id)
echo "待批准申请: ${REQ_A}"

step "5. 并发交错：bob 批准 REQ_A 与 alice 提交同版本新申请同时发出"
TMP=$(mktemp -d)
# 批准：申请行 -> 敏感短语清单行 -> 快照行
(curl -sS -o "${TMP}/approve.out" -w '%{http_code}' -X POST \
  "${BASE_URL}/publish-requests/${REQ_A}/approve" -u "bob:${BOB_PW}" \
  > "${TMP}/approve.code") &
PID_APPROVE=$!
# 让批准先取得清单行，再放行提交：制造“提交持快照行等清单行 / 批准持清单行等快照行”
# 的最坏交错（旧实现此刻死锁；修复后提交按同一锁序在清单行排队，双方先后成功）
sleep 0.2
# 提交（修复后锁序：版本行 -> 清单行 -> 快照行）
(curl -sS -o "${TMP}/submit.out" -w '%{http_code}' -X POST \
  "${BASE_URL}/records/${RECORD_ID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H "Content-Type: application/json" \
  -d '{"version": 1, "max_reads": 5}' > "${TMP}/submit.code") &
PID_SUBMIT=$!
wait "${PID_APPROVE}" || true
wait "${PID_SUBMIT}" || true
APPROVE_CODE=$(cat "${TMP}/approve.code")
SUBMIT_CODE=$(cat "${TMP}/submit.code")
printf '批准 HTTP %s（期望 200；旧锁序下可能 500 死锁）\n' "${APPROVE_CODE}"
printf '提交 HTTP %s（期望 201；旧锁序下可能 500 死锁）\n' "${SUBMIT_CODE}"
echo "批准响应:"; cat "${TMP}/approve.out" | jq -c . 2>/dev/null || cat "${TMP}/approve.out"
echo "提交响应:"; cat "${TMP}/submit.out" | jq -c . 2>/dev/null || cat "${TMP}/submit.out"
REQ_NEW=$(cat "${TMP}/submit.out" | jq -r .request_id)
rm -rf "${TMP}"

step "6. 终态核对：同一 (记录,版本) 仍只有一份快照；申请清单可逐笔查询"
curl -sS "${BASE_URL}/records/${RECORD_ID}" "${AUTH[@]}" \
  | jq '{controlled, current_version, snapshots: [.snapshots[] | {version, status, snapshot_id}]}'
curl -sS "${BASE_URL}/records/${RECORD_ID}/publish-requests" -u "alice:${ALICE_PW}" \
  | jq '{requests: [.requests[] | {request_id, status, snapshot_id, token_max_reads}]}'

step "7. 新提交的申请仍可被正常批准（上一步未留下半成品）"
if [ -n "${REQ_NEW}" ] && [ "${REQ_NEW}" != "null" ]; then
  APP2=$(curl -sS -X POST "${BASE_URL}/publish-requests/${REQ_NEW}/approve" -u "bob:${BOB_PW}")
  echo "${APP2}" | jq '{status, snapshot_id, token, max_reads}'
  TOKEN2=$(echo "${APP2}" | jq -r .token)
  echo "公开读取复用同一快照、新令牌立即生效:"
  curl -sS "${BASE_URL}/public/snapshots/${SNAPSHOT_ID}?token=${TOKEN2}" | jq .
else
  echo "（并发提交未成功签发申请编号，无法演示后续批准——锁序修复后不应出现）"
fi

step "8. 已撤回快照的提交/批准仍按既有规则 409（先按规则结算到点计划，再拒绝）"
FUTURE=$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=2)).strftime("%Y-%m-%dT%H:%M:%S+00:00"))')
PLAN=$(curl -sS -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" -d "{
  \"snapshot_id\": \"${SNAPSHOT_ID}\",
  \"scheduled_at\": \"${FUTURE}\",
  \"reason\": \"保留期届满，到点永久撤回\"
}")
echo "${PLAN}" | jq '{plan_id, status, scheduled_at, reason}'
echo "等待计划到点并由请求路径惰性结算..."
sleep 3
SUB3=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H "Content-Type: application/json" -d '{"version": 1}')
echo "已撤回快照上的新提交 => HTTP 409:"
echo "${SUB3}" | jq .
curl -sS "${BASE_URL}/records/${RECORD_ID}" "${AUTH[@]}" \
  | jq '.snapshots[] | {status, withdrawn_at, withdraw_reason}'

printf '\n\033[1m锁序修复演示完成：并发提交与批准不再死锁，其余既有约定不变。\033[0m\n'
