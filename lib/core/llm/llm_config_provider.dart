/// 兼容入口：`llmConfigProvider` 现在住在 `llm_registry_provider.dart`。
///
/// 以前这里自己组装配置（读全局的 `llmBaseUrl` + 一把全局 API Key）。
/// 上了多提供商之后，配置来自"当前提供商 + 全局采样参数"，实现搬去了
/// 提供商总表那边。这个文件留成转发，是为了不动几十处 import。
library;

export 'llm_registry_provider.dart' show llmConfigProvider, llmRegistryProvider;
