# AI 接口与计费

## 配置入口

页面右上角的“模型设置”管理供应商、个人 API Key、型号及单价。当前固定供应商各保存一组配置，另有一组自定义配置。保存并使用后，该配置用于下一次手动生成。

| 供应商 | 默认基础地址 | 生成协议 | 模型列表 |
| --- | --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | Responses | `GET /v1/models` |
| DeepSeek | `https://api.deepseek.com` | Chat Completions | `GET /models` |
| GLM | `https://open.bigmodel.cn/api/paas/v4` | Chat Completions | 先访问该基础路径的 `/models`，不支持时读取智谱官方模型目录 |
| Qwen | `https://dashscope.aliyuncs.com/compatible-mode/v1` | Chat Completions | 同一服务 origin 下的 `/api/v1/models`，支持百炼原生分页 |
| MiMo | `https://api.xiaomimimo.com/v1` | Chat Completions | `GET /v1/models` |

Qwen 新版业务空间端点需要填写自己的 `https://业务空间ID.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`，并使用同地域密钥。模型列表使用 `providers=qwen` 和 `capabilities=TG`，从 `output.models` 读取型号并处理 `total`。默认地址用于现有 DashScope 端点，具体可用性取决于账户。

GLM 列表端点返回 404、405 或 501 时，客户端通过无鉴权请求读取官方模型概览中的文本与视觉语言模型。目录来源明确标注为官方目录，账户访问权限由实际调用验证。401、403 等鉴权错误会直接显示，用户也可手动输入型号。

自定义可选择三种协议，基础地址填写版本所在路径，如 `https://example.com/gateway/v1`。客户端追加所选协议的 `models`、`chat/completions`、`responses` 或 `messages`。鉴权支持 Bearer、`x-api-key`、`api-key`。Anthropic 默认版本为 `2023-06-01`，可修改。仅接受 HTTPS 基础地址，地址中的账号、查询参数及 URL 片段会被拒绝。

## 生成与记录

每日明细的 AI 分析使用当晚与最近一次有有效分析的非测试夜间记录，允许日期不连续，界面标出对比日期。状态页使用最近 7 个日历夜的已有记录。发送字段包括日期、有效分析时长、鼾声和较强鼾声时长、不确定时长、覆盖率、实验评分及测试数据标记。

调用先写入本地 pending 记录，再发送一次模型请求。返回后保存实际用量、结果与状态。输出上限为 4096 Token。客户端关闭自动重定向，连接超时为 20 秒，总请求超时为 120 秒。失败后由用户决定是否再次调用，每次重新生成形成独立记录。

记录保存在应用私有 SQLite `mianban_ai.db` 中。API Key 使用 `flutter_secure_storage`，Android 使用 Keystore 支持的加密存储，iOS 使用 Keychain。密钥以独立随机引用关联到供应商配置。替换密钥时先写入新密钥，再事务保存配置，成功后清理旧引用。修改目标 origin 后需要重新填写密钥。

进程重启后，未完成的 pending 调用标记为 interrupted，用量与费用待账单核对。最终记录保存失败时，之前的 pending 记录仍可恢复。生成结果按分析范围保存，相关统计发生变化时，界面标注“数据已更新”。

## 费用

单价由用户按供应商报价填写，单位为所选币种每百万 Token。列表刷新负责模型发现。不同供应商对价格、套餐与折扣的公开方式不同，当前提供单价配置入口。每次调用冻结其单价快照，后续配置变动只作用于后续请求。

输入分为普通输入、缓存读取、普通缓存写入、短档缓存写入和长档缓存写入。各部分互斥，分别乘以对应单价，再加输出费用。

- OpenAI Chat、Responses、DeepSeek 的输入总量包含缓存项，计算普通输入时减去这些缓存项。
- Anthropic 的 `input_tokens` 对应普通输入，缓存读取和创建计数单独加入输入总量。
- OpenAI 的短档、长档对应 30 分钟与 12 小时的缓存写入。Anthropic 对应 5 分钟与 1 小时。
- 思考 Token 已包含在输出总量中，明细单独展示其返回计数。
- 单价最多 6 位小数，金额使用纳币单位存储，每次请求合计后四舍五入到 `10^-9` 币种单位。累计使用整数运算，人民币和美元分别展示。
- 留空单价表示未知，填写 0 表示该项免费。缺少完整用量、单价或被使用的缓存项单价时，费用标为待核对。

记录中的金额为 Token 项估算。套餐、赠送额度、折扣、地域价格、缓存存储、税费及其他服务费用需结合实际账户账单核对。超时和中断也可能已产生供应商费用。

## 验证范围

协议和计费逻辑通过受控响应测试。Android 模拟器实际验证安全密钥读写、SQLite 持久化、模型选择、单价配置、生成分析、逐次明细和中断恢复。当前没有五家供应商的真实 API Key，真实鉴权、模型权限和账户计费还需使用个人密钥试用。iOS Keychain 能力已配置，Windows 环境未进行 iOS 构建或设备验证。

## 官方资料

以下文档用于本轮接口核对，核对日期为 2026-11-09。

- OpenAI 的模型列表和文本生成接口。[List models](https://developers.openai.com/api/reference/resources/models/methods/list)、[Text generation](https://developers.openai.com/api/docs/guides/text)
- OpenAI 的缓存用量与计价口径。[Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)
- DeepSeek 模型列表和 API 说明。[Lists Models](https://api-docs.deepseek.com/api/list-models/)
- 智谱 OpenAI 兼容接口及模型目录。[OpenAI API 兼容](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction)、[模型概览](https://docs.bigmodel.cn/cn/guide/start/model-overview)
- 百炼模型发现及兼容端点。[查询模型列表](https://help.aliyun.com/zh/model-studio/list-models)、[OpenAI 兼容接口](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope)
- MiMo 官方接入说明。[MiMo 官方接入工程](https://github.com/XiaomiMiMo/awesome-mimo-agent)
- Anthropic 的模型列表和 Messages 接口。[List Models](https://platform.claude.com/docs/en/api/models/list)、[Messages](https://platform.claude.com/docs/en/api/messages)
