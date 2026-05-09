# ============================================================
# 自定义沙盒镜像 Dockerfile
# 基于 code-interpreter 基镜像 + envd + Claude Code + CCR
# ============================================================
#
# 构建方法:
#   docker build --provenance=false --sbom=false -t <your-registry>/<your-image>:<tag> .
#
# 已占用端口 (请勿冲突):
#   - 5758  : task-executor (任务管理)
#   - 44772 : execd (流式代码/命令执行, SSE)
#   - 44771 : jupyter (内核管理)
#   - 49983 : envd (SDK command 通道)
#   - 3000  : ccr (Claude Code Router, API 代理)
# ============================================================

FROM registry.example.com/ccr-sandbox/code-interpreter:v1.0.1-mixed

# ----------------------------------------------------------
# 1. 安装 envd (SDK command 支持)
#    envd 是 E2B 协议的 daemon, 使 SDK 的 sandbox.commands.run()
#    能够在容器内执行 shell 命令
# ----------------------------------------------------------
COPY envd /usr/bin/envd
RUN chmod +x /usr/bin/envd && \
    mkdir -p /run/e2b && chown -R root:root /run/e2b

# ----------------------------------------------------------
# 2. 安装 Claude Code + CCR (Claude Code Router)
#    CCR 作为 API 代理, 让 Claude Code 通过本地 3000 端口
#    路由到你配置的模型 Provider
# ----------------------------------------------------------
RUN /opt/node/v22.2.0/bin/npm install -g @wangjibins/claude-code-router @anthropic-ai/claude-code

COPY ccr-config.json /root/.claude-code-router/config.json
RUN mkdir -p /root/.claude-code-router/logs

ENV ANTHROPIC_API_KEY=test
ENV ANTHROPIC_BASE_URL=http://127.0.0.1:3000

# ----------------------------------------------------------
# 3. 将 envd + ccr 注册到 supervisord
# ----------------------------------------------------------
RUN cat >> /opt/opensandbox/supervisor/supervisord.conf <<'EOF'

; ========== envd (SDK command 通道, 端口 49983) ==========
[program:envd]
command=/usr/bin/envd -isnotfc
stdout_logfile=/var/log/supervisor/envd.log
stderr_logfile=/var/log/supervisor/envd.err
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
autostart=true
autorestart=true
priority=80
startsecs=3
startretries=3

; ========== CCR (Claude Code Router, 端口 3000) ==========
[program:ccr]
command=/opt/node/v22.2.0/bin/ccr start
stdout_logfile=/var/log/supervisor/ccr.log
stderr_logfile=/var/log/supervisor/ccr.err
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
autostart=true
autorestart=true
priority=200
startsecs=10
startretries=3
environment=HOME="/root",PATH="/opt/node/v22.2.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF

# ----------------------------------------------------------
# 4. [用户自定义区] 安装你的依赖和服务
#    在此处添加你需要的软件包、二进制文件等
# ----------------------------------------------------------
# 示例: 安装 Python 包
# RUN pip install flask redis

# 示例: 复制你的服务二进制/代码
# COPY my-service /opt/my-service/

# ----------------------------------------------------------
# 5. [用户自定义区] 注册你的服务到 supervisord
#    所有长驻服务必须通过 supervisord 管理
#    priority 数值越小越先启动, 建议自定义服务用 300+
# ----------------------------------------------------------
# RUN cat >> /opt/opensandbox/supervisor/supervisord.conf <<'EOF'
#
# ; ========== 你的自定义服务 ==========
# [program:my-service]
# command=/opt/my-service/run.sh
# directory=/opt/my-service
# stdout_logfile=/var/log/supervisor/my-service.log
# stderr_logfile=/var/log/supervisor/my-service.err
# stdout_logfile_maxbytes=10MB
# stderr_logfile_maxbytes=10MB
# autostart=true
# autorestart=true
# priority=300
# startsecs=5
# startretries=3
# EOF

# ----------------------------------------------------------
# 6. 暴露端口 (基础端口 + 你的自定义端口)
# ----------------------------------------------------------
EXPOSE 5758 44772 44771 49983 3000
# EXPOSE <你的服务端口>

WORKDIR /workspace

# 入口点保持不变: supervisord 统一管理所有进程
# 不要修改 CMD, 否则基础服务无法启动
