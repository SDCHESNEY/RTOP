# Configuration

`rtop` reads one optional JSON file. Command-line options override it; it overrides the built-in defaults.

| Source | Wins over |
|---|---|
| Command-line option | file, defaults |
| `~/Library/Application Support/rtop/config.json` (or `--config PATH`) | defaults |
| Built-in default | — |

An option that was not given on the command line never overrides the file. `--no-mouse` supplies `mouse: false`, so it does override a `true` in the file.

## Error policy

| Situation | Result |
|---|---|
| Default file does not exist | Normal; defaults are used. |
| Default file exists but is invalid | A `config:` warning is shown in the footer until the next key and written to the log; defaults plus command-line options are used. |
| `--config PATH` file missing, unreadable, not a regular file, or invalid | Message on stderr, exit status 2, no terminal mode entered. |
| Unknown key | The rest of the file is used; a warning lists the unknown keys and the known ones (catches misspellings). |
| Wrong type or out-of-range value | The whole file is invalid (see above). Values are never silently clamped. |
| File larger than 64 KiB | Invalid; the file is not parsed. |

`rtop` never creates the configuration file or its directory.

## Keys

All keys are optional. Key names are case-sensitive.

| Key | Type | Values | Default | CLI |
|---|---|---|---|---|
| `refreshMs` | integer | 250 … 2147483647 | 1000 | `--refresh-ms` |
| `sort` | string | `pid`, `name`, `user`, `cpu`, `memory`, `status` | `pid` | `--sort` |
| `descending` | boolean | | `false` | `--descending` |
| `theme` | string | `dark`, `light`, `mono` | `dark` | `--theme` |
| `color` | string | `auto`, `never`, `"256"`, `truecolor` | `auto` | `--color` |
| `normalizeCpu` | boolean | | `false` | `--normalize-cpu` |
| `historySamples` | integer | 1 … 3600 | 60 | `--history-samples` |
| `mouse` | boolean | accepted; mouse support is not shipped, so it has no effect | `true` | `--no-mouse` |

`"256"` is a string in JSON. Integers must be whole numbers (`500`, not `500.0` or `"500"`).

```json
{
  "refreshMs": 1000,
  "sort": "cpu",
  "descending": true,
  "theme": "dark",
  "color": "auto",
  "normalizeCpu": false,
  "historySamples": 60,
  "mouse": false
}
```

This sample is `ConfigFile.sample`; a test parses it, and another test checks that its keys are exactly the known keys.

## Color

- A non-empty `NO_COLOR` always disables color, whatever `--color` or `theme` say.
- `theme: mono` and `--color never` disable color.
- `auto` uses 256-color output unless `TERM` is empty or `dumb`. It never queries the terminal and never selects true color on its own.
- `256` and `truecolor` are explicit requests and are honored even when `TERM` suggests otherwise. `truecolor` emits the same palette as 24-bit sequences.
- Themes differ only in color, never in text: `dark` is the original palette, `light` uses darker shades for light backgrounds, `mono` uses bold/dim/inverse only. The theme is chosen explicitly; `rtop` does not guess from macOS appearance, because that does not describe a terminal profile.

## CPU convention

By default 100 means one logical CPU fully busy, so a multithreaded process can exceed 100. With `--normalize-cpu` the column is headed `NCPU%` and each value is divided by the number of logical CPUs. If that count is unknown the value shows `—` rather than an unscaled number. The details pane states the convention next to the value.

## Logging

Diagnostics go to `~/Library/Logs/rtop/rtop.log`: start/exit, configuration warnings, rate-limited collection failures, terminal write failures. Never command lines, environment, or process listings. The directory is created lazily with mode 0700 and the file with 0600 (a looser existing mode on a file or directory you own is tightened); the file is never opened through a symlink. At 256 KiB it rotates to `rtop.log.1` … `rtop.log.3`, so at most four files and about 1 MiB are kept. Repeated warnings with the same key are written at most once per minute with a count of suppressed repeats. Nothing is ever written to the terminal UI, and a log that cannot be opened disables itself silently.
