**🚧EXPERIMENTAL🚧**

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
workspaceMarkers = [[".emmyrc.json", ".luarc.json", ".luarc.jsonc"], [".luacheckrc", ".stylua.toml", "stylua.toml", "selene.toml", "selene.yml"], ".git"]
settings = { Lua = { codeLens = { enable = true }, hint = { enable = true, semicolon = "Disable" } } }
```

## How the conversion maps fields

| nvim-lspconfig | kakehashi | Notes |
| --- | --- | --- |
| `cmd` (table) | `cmd` | Selected dynamic commands use explicit static overrides; other functions are omitted — see WARN. |
| `filetypes` | `languages` | Direct mapping; verify against Tree-sitter grammar names. |
| `root_markers` | `workspaceMarkers` | Preserved as-is, including `.git`. |
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
The report lists `files_without_cmd` and their server names, including configs
that failed to evaluate, so new command-resolution cases are easy to spot.

### Command conversion edge cases

An audit of all 413 configs in nvim-lspconfig
`3928e638fdedf195b23ae5a18f024afa487982bc` found two missing commands that
can use global launchers: `tsc --lsp --stdio` and `svelteserver --stdio`.
These overrides do not prefer project-local executables. The `tsc` override
requires TypeScript 7.0+ with LSP support; it does not check the version or
fall back to `tsgo` as the source does.

`omnisharp` also uses a static command: the source's `--hostPID` embeds the
generator's Neovim PID, which is unrelated to the runtime host. The override
omits it and uses the lowercase `omnisharp` executable; adjust it if your
installation provides only `OmniSharp`. Parent-process monitoring through
`--hostPID` is not preserved.

The following eight configs still require manual command configuration:

| Config | Reason |
| --- | --- |
| `apex_ls` | Needs the installed Apex JAR path and Java launch arguments. |
| `bicep` | Needs the installed `Bicep.LangServer.dll` path. |
| `bsl_ls` | Upstream supplies no command. |
| `gdscript` | Connects to Godot over TCP instead of spawning a stdio server; needs a suitable stdio-to-TCP bridge. |
| `nelua_lsp` | Needs the nelua-lsp script and library paths. |
| `powershell_es` | Needs the PowerShellEditorServices bundle and runtime paths. |
| `raku_navigator` | Needs the installed `server/out/server.js` path. |
| `visualforce_ls` | Needs the installed `visualforceServer.js` path. |

### Testing the converter

Requires Python 3.11+ and Neovim on `PATH`. Tests use temporary directories and
synthetic source configs without modifying `lsp/` or launching language servers.

```sh
python3 -m unittest discover -s tests -v
```

## License

Licensed under the [Apache License, Version 2.0](LICENSE).

The configurations under `lsp/` are derived from
[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) (Apache-2.0); see
[NOTICE](NOTICE) for attribution.
