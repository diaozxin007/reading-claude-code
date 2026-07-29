# 附录 · 工具索引

按字母顺序排列 · 快速跳转到每个工具的详细章节。

## 交互类

| 工具 | 一句话职责 | 章节 |
|---|---|---|
| [AskUserQuestion](interaction/ask-user-question.md) | 让用户从预设选项里点选 | 交互原语 |
| [EnterPlanMode](interaction/enter-plan-mode.md) | 进入只读规划模式 | 交互原语 |
| [ExitPlanMode](interaction/exit-plan-mode.md) | 提交方案给用户批准 | 交互原语 |

## 执行类

| 工具 | 一句话职责 | 章节 |
|---|---|---|
| [Glob](execution/grep-glob.md) | 按路径 pattern 找文件 | 执行原语 |
| [Grep](execution/grep-glob.md) | 按内容找文件 / 行 | 执行原语 |
| [Read](execution/read.md) | 读文件内容 | 执行原语 |
| [Edit](execution/edit.md) | 精确字符串替换 | 执行原语 |
| [Write](execution/write.md) | 全文件写入 | 执行原语 |

## 通用类

| 工具 | 一句话职责 | 章节 |
|---|---|---|
| [Bash](power/bash.md) | 执行 shell 命令 | 通用能力 |
| [Agent](power/agent.md) | 派生 subagent 完成子任务 | 通用能力 |

## 状态 & 调度类

| 工具 | 一句话职责 | 章节 |
|---|---|---|
| [TaskCreate](state/task-family.md) | 创建一个待办任务 | Task 家族 |
| [TaskList](state/task-family.md) | 列出所有任务 | Task 家族 |
| [TaskGet](state/task-family.md) | 拿一个任务详情 | Task 家族 |
| [TaskUpdate](state/task-family.md) | 改任务状态 / 元数据 | Task 家族 |
| [TaskStop](state/task-family.md) | 停止后台运行的任务 | Task 家族 |
| [TaskOutput](state/task-family.md) | 从后台任务取输出 (deprecated) | Task 家族 |
| [CronCreate](state/cron-family.md) | 安排未来触发的 prompt | Cron 家族 |
| [CronList](state/cron-family.md) | 列出所有 cron job | Cron 家族 |
| [CronDelete](state/cron-family.md) | 取消一个 cron job | Cron 家族 |
| [ScheduleWakeup](state/cron-family.md) | /loop 特化的自唤醒 | Cron 家族 |
| [Monitor](state/monitor.md) | 持续监听事件流 | Monitor |
| Background(能力) | 跨工具的异步执行模式 | [Background 机制](state/background.md) |

## 信息访问类

| 工具 | 一句话职责 | 章节 |
|---|---|---|
| [WebFetch](info/web.md) | 抓一个已知 URL 的内容 | 信息访问 |
| [WebSearch](info/web.md) | 用关键词从公网找入口 | 信息访问 |

## 按「解决什么问题」查

| 需求 | 用什么 |
|---|---|
| 让用户拍板一个决策 | [AskUserQuestion](interaction/ask-user-question.md) |
| 先规划再动手 | [EnterPlanMode](interaction/enter-plan-mode.md) → [ExitPlanMode](interaction/exit-plan-mode.md) |
| 找项目里哪些文件相关 | [Glob](execution/grep-glob.md) / [Grep](execution/grep-glob.md) |
| 感知一个文件当前的样子 | [Read](execution/read.md) |
| 改一个已知位置的代码 | [Edit](execution/edit.md) |
| 新建文件 / 完全重写 | [Write](execution/write.md) |
| 跑测试 / build / git | [Bash](power/bash.md) |
| 大规模跨文件调研 | [Agent](power/agent.md) |
| 拆解复杂需求为多步 | [Task 家族](state/task-family.md) |
| 起长任务不阻塞对话 | [Background 机制](state/background.md) |
| 到某时刻自动触发 | [Cron 家族](state/cron-family.md) |
| 持续监听事件流 | [Monitor](state/monitor.md) |
| 拿最新的公网信息 | [WebFetch + WebSearch](info/web.md) |

## 按「设计哲学」查

| 观察 | 章节 |
|---|---|
| runtime 硬阻断 > AI 自律 | 分散在多个章节 · 见 [Edit](execution/edit.md) 的 Read 前置约束 |
| Read 先行的信任链 | [Edit](execution/edit.md) · [Write](execution/write.md) |
| 空参数 = 状态切换意图 | [EnterPlanMode](interaction/enter-plan-mode.md) · [ExitPlanMode](interaction/exit-plan-mode.md) |
| Context 隔离 | [Agent](power/agent.md) · [WebFetch](info/web.md) |
| 从血泪教训里长出来的 prompt | [Bash](power/bash.md) · [Monitor](state/monitor.md) |
| 正交能力 vs 独立工具 | [Background 机制](state/background.md) |
| 时态原语(过去/现在/未来) | [Task 家族](state/task-family.md) · [Cron 家族](state/cron-family.md) |

---

回到 [目录](SUMMARY.md)。
