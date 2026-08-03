## 派完之后,原地等还是先去做别的

上一篇讲完权限——派出去的 agent 手里能用什么工具。但选完类型、按下"派"这个动作之后,紧接着有一个更朴素的问题:**我是不是要在原地等它做完?**

## 一个反过来的默认值

`Bash` 工具有个 `run_in_background` 选项,说明写的是"设为 true 才会在后台跑"——不特意设置,默认就是在原地等命令跑完、立刻拿到结果。这符合直觉:大多数命令几秒钟就完事,等一下无所谓。

`Agent` 工具也有同名的字段,但默认值是反过来的:

> "Agents run in the background by default; you will be notified when one completes. Set to false to run this agent synchronously when you need its result before continuing."

**默认就是后台**——派出去不用在原地等,干完了会有通知送过来。只有明确知道"接下来的动作离不开这次结果"时,才手动把它掰回前台。

这个反转不是随手定的。`Bash` 命令通常几秒内结束,前台等一下的代价很小;`Agent` 天然对应的是"多步骤、跨文件"这类本来就要跑一阵子的任务,默认后台,是让这段等待时间能被别的工作填上,而不是干耗着。**默认值本身,就是在替使用者做"这类任务通常要多久"的判断**。

## 一条禁令:后台跑着的时候,不许编结果

后台默认带来一个新问题:既然不在原地等,那"它现在跑到哪了"这件事,该怎么处理?工具说明给了一条明确的禁令:

> "Don't race: after launching a background agent, you know nothing about its results. Never fabricate or predict them in any format — not as prose, summary, or structured output."

**不知道就是不知道**——后台任务没跑完之前,不能编一段"它大概会得出什么结论"糊弄过去,不管是写成大白话还是包装成正式格式,都不行。工具说明接着交代了正确的姿势:

> "The completion notification arrives in a later turn; it is never something you write yourself."

**完成通知只会在"以后的某一轮"里真正出现**——不是自己想象出来的,是等真的轮到那一轮,系统会把结果递过来。用户如果这时候追问进展,唯一诚实的回答是"还在跑",而不是编一个像模像样的中间汇报。

## Workflow:连"要不要等"这个选项都没有

`Agent` 好歹还留了 `run_in_background: false` 这个开关,想等还是能等。`Workflow` 工具**连这个开关都不给**:

> "Workflow runs in the background — this tool returns immediately with a task ID, and a `<task-notification>` arrives when the workflow completes."

没有"设为前台"这一说——调用 `Workflow` 永远立刻拿到一个任务 ID,真正的执行结果一定是之后某一轮通知里才出现。这不难理解:一个 `Workflow` 脚本内部可能同时管着几十个 agent 在跑,没有任何"原地等"的模式能装得下这种规模的编排。

## 但脚本内部,"要不要等"这件事又被重新交还给了作者

`Workflow` 对外是铁板一块的后台,但脚本**内部**怎么组织并发,是写脚本时自己决定的。这里出现两种截然不同的写法:

- `parallel(thunks)`——**是一个屏障**:"awaits all thunks before returning"。一批任务扔进去同时跑,但**必须等这一批全部跑完**,才能往下走。
- `pipeline(items, stage1, stage2, ...)`——**没有屏障**:"Item A can be in stage 3 while item B is still in stage 1"。每一项各自流过自己的阶段,谁跑得快谁先到终点,不必等别人。

这跟 `Agent` / `Workflow` 对外的"后台默认"是两回事——那是"调用方要不要等一整个任务"的问题;`parallel` / `pipeline` 是"脚本内部这一步,要不要等一整批任务"的问题。前者是工具设计者定好的默认值,后者是**每次写脚本时,作者自己在两种同步策略之间做的选择**。

## 并发也不是没有边界

不管是 `parallel` 还是 `pipeline`,"同时跑"这件事本身也是有硬顶的:

> "Concurrent agent() calls are capped at min(16, cpu cores - 2) per workflow — excess calls queue and run as slots free up."

超过这个上限的调用不会报错,而是**排队等空位**——传 100 个任务进去,不代表真的有 100 个同时在跑,任何时刻大概只有十来个在真正执行,其余的在队列里候着。这条限制之上还有一层更粗的兜底:

> "Total agent count across a workflow's lifetime is capped at 1000 — a runaway-loop backstop set far above any real workflow."

这条不是常规限制,是防止脚本写出无限循环时的最后一道闸——数字定得远高于正常规模,平时碰不到,只在失控时起作用。

## 这一篇留下的接口

到这里,"前台还是后台"这个问题在三个层次上都有了答案:单次 `Agent` 调用默认后台(可反转)、`Workflow` 整体恒为后台(不可反转)、脚本内部并发策略由作者自己选(屏障或不屏障),外加一层硬顶防止失控。

但不管等不等、等多久,最终都要面对同一件事:**它说完了,到底怎么算"说完"**——是一段话就行,还是必须交一份固定格式的东西。这是下一篇的问题。

## 参考

- 本篇立足的一手材料:`Bash` / `Agent` 工具的 `run_in_background` 字段说明、`Workflow` 工具的后台调用说明、脚本内 `parallel()` / `pipeline()` 的语义说明、并发上限与总量上限说明(工具集内直接可读 · 已逐字核对)
- 尚未做源码级 discovery——`<task-notification>` 具体怎样被投递到"某一轮"、并发调度器的排队实现细节,留待后续如有 discovery 补充
- 已有素材,本篇不重复:[tools 系列 · Agent 篇](../power/agent.md)(`run_in_background` 默认值反转的完整讨论)
