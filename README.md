# streamlog

Local log viewer supporting filtering and highlighting all in a single elixir script, using Phoenix Live View.

## Usage

```bash
tail -f some-log-file | <path-to>/streamlog.exs --open --port 9090 --title 'some-log-file logs'
```

```bash
./some-program-loggin-on-stdout | <path-to>/streamlog.exs --port 9091 --title 'program logs'
```

## Options

* `--port` to run on a different port than the defaul (5051)
* `--title` to assign a title to the page
* `--open` open Streamlog in the browser


## Technicalities

* logs are stored in an ets table
* streamlog exposes a live dashboard on `/dashboard` for debug purpose and curiosity 

