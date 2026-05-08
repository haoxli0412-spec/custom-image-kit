# 自定义沙盒镜像构建指南

本工具包帮助你基于沙盒基镜像构建自定义镜像，使其支持 SDK `command` 操作、Claude Code 智能编程，并可添加你自己的服务。

---

## 目录

1. [架构说明](#架构说明)
2. [快速开始](#快速开始)
3. [基镜像内置服务](#基镜像内置服务)
4. [SDK command 能力 (envd)](#sdk-command-能力-envd)
5. [Claude Code + CCR](#claude-code--ccr)
6. [流式输出接口](#流式输出接口)
7. [添加自定义服务](#添加自定义服务)
8. [完整工作流](#完整工作流)
9. [FAQ](#faq)

---

## 架构说明

```
┌─────────────────────────────────────────────────────────────┐
│                    自定义沙盒镜像                              │
├─────────────────────────────────────────────────────────────┤
│  supervisord (PID 1, 进程管理器)                              │
│  ├── task-executor  (端口 5758)  - 任务编排管理                │
│  ├── execd          (端口 44772) - 代码/命令执行 (SSE 流式)    │
│  ├── jupyter        (端口 44771) - Jupyter 内核               │
│  ├── envd           (端口 49983) - SDK command 通道           │
│  ├── ccr            (端口 3000)  - Claude Code Router        │
│  └── [你的服务]      (自定义端口) - 你的业务逻辑               │
├─────────────────────────────────────────────────────────────┤
│  基镜像: code-interpreter:v1.0.1-mixed                       │
└─────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   SDK commands.run()    流式 /command          Claude Code CLI
   (通过 envd)           (直接 HTTP)            (通过 ccr 代理)
```

**进程管理**: 所有服务由 `supervisord` 统一管理，容器入口点为 `/usr/bin/supervisord`。

---

## 快速开始

```bash
# 1. 准备文件 (确保 envd 二进制在当前目录)
ls
# Dockerfile  envd  ccr-config.json  build-and-push.sh  register-image.sh

# 2. 配置 ccr-config.json (填入你的模型 Provider 信息)

# 3. 编辑 Dockerfile 中的自定义区域 (可选, 添加你自己的服务)

# 4. 构建并推送
chmod +x build-and-push.sh register-image.sh
./build-and-push.sh v1.0

# 5. 注册到沙盒平台
./register-image.sh registry.cn-sh-01.sensecore.cn/your-ns/custom-sandbox:v1.0
```

---

## 基镜像内置服务

基镜像 `registry.cn-sh-01.sensecore.cn/ccr-sandbox/code-interpreter:v1.0.1-mixed` 预装了以下服务:

| 服务 | 端口 | 用途 | 协议 |
|------|------|------|------|
| task-executor | 5758 | 任务编排/管理 | HTTP REST |
| execd | 44772 | 代码执行 + Shell 命令 (流式) | HTTP + SSE |
| jupyter | 44771 | Jupyter 内核管理 | HTTP + WebSocket |

**预装语言环境**:
- Python 3.12 (默认), 3.11
- Node.js v22 (默认), v20, v18
- Go 1.24 (默认), 1.23
- Java 21 (OpenJDK)

**已占用端口**: `5758`, `44772`, `44771`。添加 envd 后还会占用 `49983`，添加 CCR 后还会占用 `3000`。

---

## SDK command 能力 (envd)

### 什么是 envd

`envd` 是 E2B 协议的进程守护程序。它使得 SDK 中的 `sandbox.commands.run()` 方法能够在容器内执行 shell 命令。

### 安装后的效果

安装 envd 后，你可以通过 SDK 执行任意命令:

```python
from e2b_code_interpreter import Sandbox
import os

os.environ['E2B_API_KEY'] = 'your-api-key'
os.environ['E2B_API_URL'] = 'https://sandbox.cn-sh-01.sensecoreapi.dev'

sbx = Sandbox.create(template="your-image-name")

# 执行 shell 命令
result = sbx.commands.run("ls -la /workspace")
print(result.stdout)

# 执行 Python
result = sbx.commands.run("python -c 'print(1+1)'")
print(result.stdout)  # "2"

sbx.kill()
```

### envd 工作原理

```
SDK (客户端)
  │ sandbox.commands.run("ls")
  ▼
沙盒平台 API
  │ 转发到容器内 envd
  ▼
envd (端口 49983, 容器内)
  │ 创建子进程执行命令
  ▼
Shell 执行 → 返回 stdout/stderr/exit_code
```

---

## Claude Code + CCR

### 什么是 CCR

CCR (Claude Code Router) 是一个 API 代理服务，运行在容器内的 3000 端口。它让 Claude Code CLI 能够通过本地代理路由到你配置的模型 Provider（如 OpenAI 兼容接口）。

### 工作原理

```
Claude Code CLI (容器内)
  │ ANTHROPIC_BASE_URL=http://127.0.0.1:3000
  ▼
CCR (端口 3000, 本地代理)
  │ 根据 config.json 路由到目标 Provider
  ▼
你的模型 API (外部或内部)
  │ /v1/chat/completions, /v1/messages 等
  ▼
模型响应 → 返回给 Claude Code
```

### 配置 CCR

编辑 `ccr-config.json`，配置你的模型 Provider：

```json
{
  "PORT": 3000,
  "HOST": "0.0.0.0",
  "APIKEY": "test",
  "API_TIMEOUT_MS": 600000,
  "Providers": [
    {
      "name": "your-provider",
      "api_base_url": "http://your-api-endpoint/v1/chat/completions",
      "api_key": "your-api-key",
      "models": ["your-model-name"],
      "transformer": {
        "use": [
          ["maxtoken", { "max_tokens": 65536 }],
          "streamoptions"
        ]
      }
    }
  ],
  "Router": {
    "default": "your-provider,your-model-name"
  }
}
```

**配置字段说明**:

| 字段 | 说明 |
|------|------|
| `Providers[].name` | Provider 标识名 |
| `Providers[].api_base_url` | 模型 API 地址 (需支持 OpenAI 兼容格式) |
| `Providers[].api_key` | API 密钥 |
| `Providers[].models` | 该 Provider 支持的模型列表 |
| `Router.default` | 默认路由: `"provider名,模型名"` |

**支持的端点**: `/v1/chat/completions`、`/v1/completions`、`/v1/responses`、`/v1/messages` (Anthropic 格式)

### 在沙盒中使用 Claude Code

通过 SDK 进入沙盒后，直接运行 `claude` 命令即可：

```python
# 启动 Claude Code 交互式会话
result = sbx.commands.run("claude")

# 或者用非交互模式执行单个任务
result = sbx.commands.run('claude -p "写一个 hello world 程序"')
print(result.stdout)
```

---

## 流式输出接口

基镜像的 `execd` 服务 (端口 44772) 提供流式代码和命令执行，可直接通过 HTTP 访问。

### POST /command — 执行 Shell 命令 (SSE 流式)

```bash
curl -X POST http://<sandbox-ip>:44772/command \
  -H "Content-Type: application/json" \
  -d '{
    "command": "echo hello && sleep 1 && echo world",
    "timeout": 30000,
    "cwd": "/workspace"
  }'
```

响应 (Server-Sent Events 流):
```json
{"type":"init","text":"session-id-xxx","timestamp":1714000000}
{"type":"stdout","text":"hello","timestamp":1714000001}
{"type":"stdout","text":"world","timestamp":1714000002}
{"type":"execution_complete","execution_time":1024,"timestamp":1714000002}
```

### POST /code — 执行代码 (SSE 流式)

```bash
curl -X POST http://<sandbox-ip>:44772/code \
  -H "Content-Type: application/json" \
  -d '{
    "code": "import time\nfor i in range(3):\n    print(i)\n    time.sleep(0.5)",
    "language": "python",
    "kernel": "python3",
    "timeout": 30000
  }'
```

### SSE 事件类型

| type | 说明 |
|------|------|
| `init` | 执行开始，text 为 session_id |
| `stdout` | 标准输出 |
| `stderr` | 标准错误 |
| `execution_complete` | 执行完成，含 execution_time (ms) |
| `error` | 执行出错，含 ename/evalue/traceback |
| `ping` | 心跳，text 固定为 "pong" |

### 文件操作接口

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/files/info?path=<path>` | 获取文件/目录信息 |
| GET | `/files/download?path=<path>` | 下载文件 |
| POST | `/files/upload` | 上传文件 (multipart) |
| POST | `/files/replace` | 替换文件内容 |

### 直接访问流式接口

如果你的应用需要直接使用流式输出（而不通过 SDK），可以直接对容器的 44772 端口发起 HTTP 请求。这适合:
- 前端直接消费 SSE 流进行实时输出展示
- 自定义客户端需要精细控制流式数据
- 不通过 SDK 而是直接集成的场景

---

## 添加自定义服务

### 标准与规范

| 项目 | 要求 |
|------|------|
| 进程管理 | **必须**使用 supervisord 管理长驻服务 |
| 端口选择 | 避开已占用端口: 5758, 44772, 44771, 49983 |
| 日志输出 | 写到 `/var/log/supervisor/` 目录 |
| 启动顺序 | 使用 `priority` 控制 (基础服务用 80-200, 建议自定义服务用 300+) |
| 工作目录 | 建议放在 `/opt/` 或 `/srv/` 下 |
| 健康检查 | 建议提供 HTTP `/health` 端点 |

### 步骤

#### 1. 安装你的服务

在 Dockerfile 中安装依赖和复制文件:

```dockerfile
# 安装系统依赖
RUN apt-get update && apt-get install -y your-package && rm -rf /var/lib/apt/lists/*

# 复制服务文件
COPY my-service/ /opt/my-service/
RUN chmod +x /opt/my-service/start.sh
```

#### 2. 注册到 supervisord

追加配置到已有的 supervisord 配置文件:

```dockerfile
RUN cat >> /opt/opensandbox/supervisor/supervisord.conf <<'EOF'

; ========== 你的服务名称 ==========
[program:my-service]
command=/opt/my-service/start.sh
directory=/opt/my-service
stdout_logfile=/var/log/supervisor/my-service.log
stderr_logfile=/var/log/supervisor/my-service.err
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
autostart=true
autorestart=true
priority=300
startsecs=5
startretries=3
environment=MY_ENV_VAR="value"
EOF
```

#### 3. 暴露端口

```dockerfile
EXPOSE 5758 44772 44771 49983 <你的端口>
```

### supervisord 配置详解

```ini
[program:my-service]
command=/opt/my-service/start.sh    ; 启动命令 (必须前台运行, 不能 daemon 化)
directory=/opt/my-service           ; 工作目录
stdout_logfile=...                  ; 标准输出日志
stderr_logfile=...                  ; 错误日志
stdout_logfile_maxbytes=10MB        ; 日志轮转大小
autostart=true                      ; 容器启动时自动启动
autorestart=true                    ; 崩溃后自动重启
priority=300                        ; 启动优先级 (数字越小越先启动)
startsecs=5                         ; 启动后持续 N 秒认为启动成功
startretries=3                      ; 启动失败最多重试次数
environment=KEY="val",KEY2="val2"   ; 环境变量
```

**重要**: `command` 指定的程序必须在**前台运行**（不能 daemonize）。如果你的程序默认 daemon 化，需要加 `--foreground` 或 `--no-daemon` 参数。

### 完整示例: 添加一个 Flask API 服务

```dockerfile
# 安装依赖
RUN pip install flask gunicorn

# 复制代码
COPY my-api/ /opt/my-api/

# 注册到 supervisord
RUN cat >> /opt/opensandbox/supervisor/supervisord.conf <<'EOF'

[program:my-api]
command=gunicorn -w 2 -b 0.0.0.0:8000 app:app
directory=/opt/my-api
stdout_logfile=/var/log/supervisor/my-api.log
stderr_logfile=/var/log/supervisor/my-api.err
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
autostart=true
autorestart=true
priority=300
startsecs=5
startretries=3
EOF

EXPOSE 5758 44772 44771 49983 8000
```

### 在 SDK 中访问你的自定义服务

自定义服务启动后，你可以通过 SDK 的命令执行来访问:

```python
# 通过 curl 访问你的服务
result = sbx.commands.run("curl -s http://localhost:8000/api/data")
print(result.stdout)

# 或者直接调用你服务的 CLI
result = sbx.commands.run("/opt/my-service/cli --action process")
print(result.stdout)
```

---

## 完整工作流

```
  ┌─────────────┐      ┌──────────────┐      ┌──────────────┐
  │ 1. 编辑      │  →   │ 2. 构建推送   │  →   │ 3. 注册      │
  │ Dockerfile   │      │ build-push.sh│      │ register.sh  │
  └─────────────┘      └──────────────┘      └──────────────┘
                                                      │
                                                      ▼
                              ┌────────────────────────────────┐
                              │ 4. 通过 SDK 使用                 │
                              │ Sandbox.create(template="...")  │
                              │ sbx.commands.run("...")         │
                              └────────────────────────────────┘
```

### Step 1: 编辑 Dockerfile

按需修改 Dockerfile 中 `[用户自定义区]` 的内容。

### Step 2: 构建并推送

```bash
# 修改 build-and-push.sh 中的 REGISTRY/NAMESPACE/IMAGE_NAME
vim build-and-push.sh

# 构建并推送
./build-and-push.sh v1.0
```

### Step 3: 注册镜像

```bash
# 修改 register-image.sh 中的 API_KEY
vim register-image.sh

# 注册
./register-image.sh registry.cn-sh-01.sensecore.cn/your-ns/custom-sandbox:v1.0
```

### Step 4: 通过 SDK 使用

```python
from e2b_code_interpreter import Sandbox
import os

os.environ['E2B_API_KEY'] = 'your-api-key'
os.environ['E2B_API_URL'] = 'https://sandbox.cn-sh-01.sensecoreapi.dev'

# 使用你的自定义镜像创建沙盒
sbx = Sandbox.create(template="registry.cn-sh-01.sensecore.cn/your-ns/custom-sandbox:v1.0")

# SDK command 操作
result = sbx.commands.run("python --version")
print(result.stdout)

# 文件操作
sbx.files.write("/workspace/hello.py", "print('Hello from custom image!')")
execution = sbx.run_code("exec(open('/workspace/hello.py').read())")
print(execution.logs.stdout)

# 访问你的自定义服务
result = sbx.commands.run("curl -s http://localhost:8000/health")
print(result.stdout)

sbx.kill()
```

---

## FAQ

### Q: 为什么需要 envd? 不能直接用 execd 吗?

`execd` 提供的是 HTTP SSE 流式接口，适合直接 HTTP 调用。而 `envd` 实现的是 E2B 协议的 gRPC/Connect RPC 接口，这是 SDK `sandbox.commands.run()` 所依赖的通信协议。两者互补:
- **envd** → SDK 的 `commands.run()` / `files.write()` / `files.read()`
- **execd** → 直接 HTTP 调用的流式 `/command` 和 `/code`

### Q: 我的服务依赖基镜像中的 Python 环境怎么办?

基镜像预装了多个 Python 版本。默认 Python 3.14 可直接使用:
```dockerfile
RUN pip install your-package
```
切换版本:
```dockerfile
RUN source /opt/opensandbox/code-interpreter-env.sh python 3.13 && pip install your-package
```

### Q: 如何调试容器内的服务?

启动容器后查看 supervisord 状态:
```bash
# 查看所有服务状态
supervisorctl status

# 查看特定服务日志
tail -f /var/log/supervisor/my-service.log

# 手动重启服务
supervisorctl restart my-service
```

### Q: 我可以修改 CMD 或 ENTRYPOINT 吗?

**不要修改**。基镜像的入口点是 `/usr/bin/supervisord`，它负责启动和管理所有服务。如果你修改了 CMD/ENTRYPOINT，基础服务（execd, jupyter 等）将不会启动，SDK 功能会失效。

### Q: 端口冲突怎么办?

以下端口已被占用，请勿使用:
- `5758` - task-executor
- `44772` - execd
- `44771` - jupyter
- `49983` - envd
- `3000` - ccr (Claude Code Router)

建议你的服务使用 8000-9000 范围的端口，或其他未占用的高位端口。

### Q: 如何让服务之间相互通信?

所有服务运行在同一个容器内，可以直接通过 `localhost:<port>` 互相访问。例如你的服务可以调用 execd:
```bash
curl http://localhost:44772/command -d '{"command":"echo hi"}'
```
