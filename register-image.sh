#!/bin/bash
# ============================================================
# 自定义沙盒镜像 - 注册到沙盒服务
# 推送镜像后, 需要调用此脚本将镜像注册到沙盒平台数据库
# ============================================================
set -e

# ----------------------------------------------------------
# 配置区 (请修改为你的实际值)
# ----------------------------------------------------------
SANDBOX_API_URL="https://sandbox.cn-sh-04.sensecoreapi.dev"
API_KEY=""        # 沙盒平台的 API Key

# 镜像全名 (与 build-and-push.sh 中推送的一致)
IMAGE_NAME="${1:-}"

# ----------------------------------------------------------
# 参数检查
# ----------------------------------------------------------
if [ -z "${IMAGE_NAME}" ]; then
    echo "用法: ./register-image.sh <镜像全名>"
    echo ""
    echo "示例:"
    echo "  ./register-image.sh registry.cn-sh-01.sensecore.cn/your-ns/custom-sandbox:v1.0"
    echo ""
    echo "说明: 镜像全名需要和推送到 registry 的完整名称一致"
    exit 1
fi

# ----------------------------------------------------------
# 注册镜像
# ----------------------------------------------------------
echo "============================================================"
echo "  注册镜像到沙盒服务"
echo "============================================================"
echo ""
echo "API:    ${SANDBOX_API_URL}/studio/sandbox/v1/builtinimages"
echo "镜像:   ${IMAGE_NAME}"
echo ""

RESPONSE=$(curl --silent --location \
    "${SANDBOX_API_URL}/studio/sandbox/v1/builtinimages" \
    --header "Authorization: ${API_KEY}" \
    --header "Content-Type: application/json" \
    --data "{
        \"name\": \"${IMAGE_NAME}\",
        \"type\": 1
    }" \
    --write-out "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

echo "响应状态: ${HTTP_CODE}"
echo "响应内容: ${BODY}"
echo ""

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "============================================================"
    echo "  注册成功!"
    echo ""
    echo "  现在可以通过 SDK 使用此镜像:"
    echo "    sbx = Sandbox.create(template=\"${IMAGE_NAME}\")"
    echo "============================================================"
else
    echo "[错误] 注册失败, 请检查:"
    echo "  1. API_KEY 是否正确"
    echo "  2. 镜像名称是否与推送的一致"
    echo "  3. 网络是否可达 ${SANDBOX_API_URL}"
    exit 1
fi
