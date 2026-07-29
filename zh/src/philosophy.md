
优先原子解决一个问题。

要有一个大而全的作为兜底。

读免费,写谨慎 —— 默认档位保守,不让 LLM 自选风险。

明说不做什么,和明说做什么同等重要。

能力按需加载,不塞进主 prompt。


prompt 的书写技巧

1、明确工具的职责
2、明确什么时候可以使用、什么时候不能使用
3、工具之间的 prompt 是有关联的整体机制。明确什么情况下应该用更适合的工具
4、必要时给出例子;正例反例并列,反例信号更强
5、明确输入输出约束
6、失败要 loud,不默默降级
7、工具主动告知自己的信息损耗率,LLM 才能判断何时该走兜底
8、委托后验收实际改动,不只看 summary
9、默认幂等/可撤销,才敢在不确定时重试
10、不确定的交给用户,不猜


深一层

1、工具签名本身就是 prompt —— schema 比 doc 硬
例:AskUserQuestion 的 `minItems: 2, maxItems: 4`,想一次问 5 个直接报错。「别问过多」编码成不可绕过的失败,不靠描述劝。

2、工具描述是微型 system prompt,不是 API doc
例:Agent 里 `**Never delegate understanding.** Don't write "based on your findings, fix the bug"` —— 教认知怎么组织,不只讲能做什么。

3、对偶工具族形成闭环
例:TaskCreate / Get / List / Update 四件套 —— 累积状态有释放路径。缺失对偶是 code smell。

4、每一次 no 都带一次 yes
例:WebFetch `WILL FAIL for authenticated URLs... look for a specialized MCP tool that provides authenticated access` —— 拒绝时同步给路标。

5、Default 即 best practice,偏离要显式
例:Workflow `DEFAULT TO pipeline(). Only reach for a barrier when you genuinely need ALL prior-stage results` —— 少写参数自动选中最佳实践。

6、Context 预算是隐式一等公民
例:Agent `the agent's final report is not visible to the user... send a text message back` —— subagent transcript 留在自己的 context,主 window 只收 summary。用工具边界做 context isolation。
