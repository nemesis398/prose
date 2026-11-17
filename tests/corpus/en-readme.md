# Marrowlog

Marrowlog is a small log viewer for the terminal — fast, local and free.
It's not just a pager, it is a full search tool. It's worth noting that the
index lives in a single file – which keeps backups simple. When it comes to
speed, Marrowlog reads about 40% of a gigabyte per second. Let's dive into the
setup.

## Install

Run `marrowlog --init` once, then add `~/.marrowlog/config.toml` to your
backups. See the [install guide](https://example.org/marrowlog/install) or the
raw page at https://example.org/marrowlog/raw for details.

```sh
# a comment with a speling mistake and  two spaces
marrowlog --init --dir  ~/logs
```

## Options

| Flag      | Effect               | Default |
| --------- | -------------------- | ------- |
| `--dir`   | Directory to watch   | —       |
| `--json`  | Print JSON           | off     |
| `--quiet` | Hide the banner      | —       |

Marrowlog plays a crucial role in our stack, and it integrates seamlessly with
systemd. At the end of the day, this is a game-changer for small teams.  The
tool have many options and this are the reason why we wrote a short guide.
Their are three modes , each with it's own flags. In conclusion, try it out.

He said “it works” and then typed "marrowlog --help" and "marrowlog --version"
and "marrowlog --init" without a pause.

Marrowlog is robust and scalable and a testament to patient work. Delve into the
source code, and harness the power of the query language.
