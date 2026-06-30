# kakehashi-lspconfig

[kakehashi](https://github.com/atusy/kakehashi) language-server configurations,
converted on a best-effort basis from
[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)'s `lsp/*.lua`.

Each `lsp/<name>.toml` holds one `[languageServers.<name>]` table that you can
drop into kakehashi's `languageServers` configuration.

```toml
[languageServers.lua_ls]
cmd = ["lua-language-server"]
languages = ["lua"]
rootMarkers = [[".emmyrc.json", ".luarc.json", ".luarc.jsonc"], [".luacheckrc", ".stylua.toml", "stylua.toml", "selene.toml", "selene.yml"], ".git"]
settings = { Lua = { codeLens = { enable = true }, hint = { enable = true, semicolon = "Disable" } } }
```

## How the conversion maps fields

| nvim-lspconfig | kakehashi | Notes |
| --- | --- | --- |
| `cmd` (table) | `cmd` | Lua-function `cmd` cannot be converted — see WARN. |
| `filetypes` | `languages` | Direct mapping; verify against Tree-sitter grammar names. |
| `root_markers` | `rootMarkers` | Preserved as-is, including `.git`. |
| `settings` | `settings` | Workspace config; propagated via `didChangeConfiguration` / `workspace/configuration`. |
| `init_options` | `initializationOptions` | Sent once at `initialize`. |

Everything else in a `vim.lsp.Config` (`on_attach`, `capabilities`, `handlers`,
`commands`, `root_dir`/`cmd` functions, …) has no kakehashi equivalent and is
dropped with a `# WARN:` comment at the top of the file so you can fill in or
adjust by hand.

## Caveats

- **`languages` is a direct copy of `filetypes`.** Neovim filetypes are not
  always Tree-sitter grammar names (e.g. clangd's `c.doxygen`, `objcpp`).
  `languages` gates whether the bridge fires, so verify compound/renamed entries.
- **`settings` vs `initializationOptions`.** nvim `settings` maps to kakehashi's
  per-server `settings` (propagated over `workspace/didChangeConfiguration` and
  answered on `workspace/configuration`); nvim `init_options` maps to
  `initializationOptions` (sent once at `initialize`). A few servers instead
  expect their `settings` payload inside `initializationOptions` and remap it in
  `before_init` (e.g. rust-analyzer); those carry a `before_init` WARN — move the
  `settings` block into `initializationOptions` by hand if the server needs it.

## Regenerating

```sh
NVIM_LSPCONFIG=/path/to/nvim-lspconfig nvim --headless -l scripts/convert.lua
```

The script evaluates each config with the real `vim` API via headless Neovim,
then serializes the resulting table to TOML.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).

The configurations under `lsp/` are derived from
[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) (Apache-2.0); see
[NOTICE](NOTICE) for attribution.
