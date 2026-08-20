# Shiplog

A captain's log of what you shipped, for the [Omarchy](https://omarchy.org) bar.

Every developer widget shows work pending — inboxes, queues, pipelines. Shiplog shows work **done**: merged PRs, pushed commits, and closed issues since midnight, counted in the bar with the day's log one click away. Proof-of-done, not another todo list.

> **Status: specification phase.** The plugin contract, UX, data sources, and acceptance criteria are fully defined in [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). Implementation has not started. Watch the repo if you want the working version.

## Planned features

- Shipped-today count in the bar: commits pushed, PRs merged, issues closed
- Click-through panel: the day's log grouped by repo, deep links to each item
- GitHub via the `gh` CLI (read-only; your auth stays in `gh`) plus an offline local-repos source
- Seven-day strip — receipts, not analytics; no streaks, no badges, no guilt
- Configurable day boundary for night owls
- Theme-aware via Omarchy semantic tokens

## Plugin contract

- **ID:** `io.github.joshuaswarren.shiplog`
- **Kinds:** `bar-widget` + `panel`
- **Compatibility target:** Omarchy 4 / Quattro shell

## Requirements

- `gh` (GitHub CLI), authenticated — only for the GitHub source
- `git` — only for the optional local-repos source

## Installation (once implemented)

```bash
omarchy plugin add https://github.com/joshuaswarren/omarchy-shiplog
```

## Configuration

Settings live inline on the plugin entry in `~/.config/omarchy/shell.json` — see [docs/REQUIREMENTS.md §5](docs/REQUIREMENTS.md#5-settings-inline-on-the-shelljson-plugin-entry).

## Security

Strictly read-only. The plugin shells out to `gh` and `git` with structured arguments, never touches tokens, and never writes to any remote. Details in [docs/REQUIREMENTS.md §7](docs/REQUIREMENTS.md#7-security).

## License

[MIT](LICENSE)
