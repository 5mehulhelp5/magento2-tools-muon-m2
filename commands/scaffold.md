---
description: Entry point for Magento 2 code generation — routes the request to the matching generator skill (defaults to module-create for a whole new module).
argument-hint: "[<type>] [<Vendor>_<Module>] [--flags]"
---
Match the request to the generator skill below and invoke THAT skill directly, forwarding these arguments verbatim: $ARGUMENTS

- a whole new module/extension → `magento2-tools:module-create` (the default)
- a plugin / observer / preference onto existing code → `magento2-tools:extension-point`
- admin Stores → Configuration settings → `magento2-tools:system-config`
- a `bin/magento` console command or cron job → `magento2-tools:cli-command`
- an async message-queue surface → `magento2-tools:message-queue`
- a product/customer/category EAV attribute → `magento2-tools:eav-attribute`
- a GraphQL query/mutation/type → `magento2-tools:graphql`
- a REST / Web-API surface for an existing entity → `magento2-tools:webapi`
- a theme, RequireJS/Knockout/Alpine component, or email template → `magento2-tools:frontend`
- an admin UI-component edit form → `magento2-tools:admin-form`
- an admin UI-component grid/listing → `magento2-tools:admin-listing`

If the request is multi-surface or its scope is unclear, use `magento2-tools:feature` instead.
If no specialist matches, default to the `magento2-tools:module-create` skill.
