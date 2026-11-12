# Triage roles

| 技能中的角色 | Linear 中的表示 |
| --- | --- |
| needs-triage | 原生 Triage 状态，不创建同名标签 |
| needs-info | needs-info 标签 |
| ready-for-agent | ready-for-agent 标签 |
| ready-for-human | ready-for-human 标签 |
| wontfix | wontfix 标签 |

- 状态和标签是不同字段：needs-triage 必须设置状态为 Triage。
- 其余标签在实际需要时先检查是否存在，缺少时创建。
- needs-info、ready-for-agent、ready-for-human、wontfix 表示不同分类结果，切换结果时移除已失效的分类标签。
- 不因修改分类标签而擅自改变开发状态。
