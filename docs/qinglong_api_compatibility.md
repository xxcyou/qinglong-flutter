# 青龙面板 API 版本兼容对照（v2.10 ~ master/v2.22）

> 来源：GitHub whyour/qinglong `back/api/*.ts` 各 tag 路由声明。
> 路径均为面板实际 HTTP 路径（`/api` 前缀由 Nginx 反代层决定，App 里的 apiBaseUrl 已含）。

## 脚本 Scripts

| 版本范围 | 列表 | 读取 | 保存 | 新建 | 重命名 | 运行/停止 |
|---|---|---|---|---|---|---|
| v2.10 - v2.12 | `GET /scripts/files` | `GET /scripts/:file?path=` | `PUT /scripts` | `POST /scripts` | - | `PUT /scripts/run` / `PUT /scripts/stop` |
| v2.13 - v2.16 | `GET /scripts` | `GET /scripts/:file?path=` | `PUT /scripts` | `POST /scripts` | v2.15+ `PUT /scripts/rename` | 同上 |
| v2.17+ | `GET /scripts` | `GET /scripts/detail?path=&file=`（旧 `/:file` 返回 410） | `PUT /scripts` | `POST /scripts` | `PUT /scripts/rename` | 同上 |

## 日志 Logs

| 版本范围 | 列表 | 读取 | 删除 |
|---|---|---|---|
| v2.10 - v2.12 | `GET /logs` | `GET /logs/:dir/:file` 或 `GET /logs/:file` | - |
| v2.13 - v2.16 | `GET /logs` | `GET /logs/:file?path=` | `DELETE /logs` |
| v2.17+ | `GET /logs` | `GET /logs/detail?path=&file=`（旧 `/:file` 返回 410） | `DELETE /logs` |

## 定时任务 Crons

| 功能 | v2.10 - v2.13 | v2.14+ | v2.15+ | v2.21+ |
|---|---|---|---|---|
| 列表 | `GET /crons` | `GET /crons` | `GET /crons` | `GET /crons` |
| 详情 | `GET /crons/:id` | `GET /crons/:id` | `GET /crons/detail` 也可 | 同上 |
| 新建/保存/删除 | `POST/PUT/DELETE /crons` | 同左 | 同左 | 同左 |
| 运行/停止 | `PUT /crons/run` / `PUT /crons/stop` | 同左 | 同左 | 同左 |
| 启用/禁用/置顶 | `PUT /crons/{enable,disable,pin,unpin}` | 同左 | 同左 | 同左 |
| 运行日志 | `GET /crons/:id/log` | 同左 | 同左 | 同左 |
| 日志列表 | v2.12+ `GET /crons/:id/logs` | 同左 | 同左 | 同左 |

## 环境变量 Envs

| 功能 | v2.10 - v2.13 | v2.14 - v2.19 | v2.20+ |
|---|---|---|---|
| 列表 | `GET /envs` | 同左 | 同左 |
| 新建/保存/删除 | `POST/PUT/DELETE /envs` | 同左 | 同左 |
| 启用/禁用 | `PUT /envs/{enable,disable}` | 同左 | 同左 |
| 移动/改名 | `PUT /envs/:id/move` / `PUT /envs/name` | 同左 | 同左 |
| 上传 | - | v2.14+ `POST /envs/upload` | 同左 |
| 置顶 | - | - | v2.20+ `PUT /envs/{pin,unpin}` |
| 标签 | - | - | v2.21+ `POST/DELETE /envs/labels` |

## 依赖 Dependencies

基本稳定：`GET/POST/PUT/DELETE /dependencies`，`DELETE /dependencies/force`，`PUT /dependencies/reinstall`。
v2.17+ 增加 `PUT /dependencies/cancel`。

## 订阅 Subscriptions

基本稳定（v2.13 起有该模块）：`GET/POST/PUT/DELETE /subscriptions`，
`PUT /subscriptions/{run,stop,enable,disable}`，
`GET /subscriptions/:id/log`，`GET /subscriptions/:id/logs`。

## 系统 System

| 版本范围 | 说明 |
|---|---|
| v2.10 - v2.14 | `GET /system`，`PUT /system/log/remove`，`PUT /system/update-check` 等 |
| v2.15+ | 新增 `GET/PUT /system/config`、`PUT /system/reload`、`PUT /system/notify`、命令运行/停止、数据导入导出 |
| v2.17+ | `GET /system/log`、`DELETE /system/log`，配置改为细分接口 |
| v2.18+ | `PUT /system/auth/reset`、`PUT /system/config/timezone` |

## 配置文件 Configs

| 版本范围 | 文件列表 | 读取 | 保存 |
|---|---|---|---|
| v2.10 - v2.16 | `GET /configs/files` | `GET /configs/:file` | `POST /configs/save` |
| v2.17 - v2.20 | `GET /configs/sample` `GET /configs/files` `GET /configs/detail` | `GET /configs/:file` | `POST /configs/save` |
| v2.21+ | `sample` 改为 `samples`，其余同 | `GET /configs/detail` 可用 | 同上 |
