# kelivo-acp — 纯 ACP UI 工程（GHA 公仓）

把 [kelivo](https://github.com/Chevey339/kelivo) 改造成**纯 ACP Client**：app 只做 UI + Agent Client Protocol，沙箱里跑完整 ACP agent（`pi-acp` → `pi --mode rpc`）。

## 架构

```
Kelivo App = 纯 ACP Client (Flutter/Dart)
   │  spawn(经 PRoot 包装) + stdio JSON-RPC
   └── PRoot 沙箱（用户态，无 root）
          └── pi-acp (ACP server)  ──spawn──>  pi --mode rpc（任意 ACP 兼容 Agent，可换）
```

- **agent 可插拔**：`pi-acp` 是 ACP server 适配器，内部 spawn `pi --mode rpc`；换 agent 就是换被 PRoot 包装的进程
- **kelivo 只保留 UI**：会话/消息渲染/权限弹窗/终端/文件浏览；供应商/工具/沙盒/记忆逻辑全部下沉到 agent

## 已验证（Termux 实测）

`ACP 客户端 → pi-acp → pi --mode rpc → 真实模型` 全链路流式返回通过：
- `initialize`（params 需 `protocolVersion:1`）
- `session/new`（返回 `sessionId` + `availableModels` 模型上报 + `configOptions`）
- `session/prompt`（`{sessionId, prompt:[{type:'text',text}]}`）
- 通知 `session/update`（`agent_message_chunk` / `agent_message` / `usage_update` / `session_info_update` / `available_commands_update`）

## 本地跑

```bash
npm install
node acp-handshake.js        # 握手（无需模型 key）
node acp-client-piacp.js     # 完整 round-trip（需模型 key）
```

## GHA

- `.github/workflows/acp-integration.yml`：握手 job（必过）+ prompt job（配 `MODEL_API_KEY` 才跑）
- `.github/workflows/build-app.yml`：编译改造后 kelivo 的 APK（repo 内需 `app/` 或 `kelivo/` 子目录含 `pubspec.yaml`）

## Secrets（可选）

- `MODEL_API_KEY` / `MODEL_BASE_URL`：prompt 测试用；不配则 CI 只握手
