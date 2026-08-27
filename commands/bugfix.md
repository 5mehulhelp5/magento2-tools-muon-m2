---
description: Reproduce → root-cause → minimal TDD fix → regression test → review (fix)
argument-hint: "\"<bug description>\" [--module=…] [--log=…] [--severity=…] [--agents|--inline]"
disable-model-invocation: true
---
Use the `magento2-tools:fix` skill, forwarding these arguments verbatim: $ARGUMENTS

Do not skip reproduction/RCA or the RCA approval gate; the skill's normal flow applies.
