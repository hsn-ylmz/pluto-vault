# Clean-room installs

A from-zero claim is worth exactly as much as the clean room you can prove it in.

```bash
docker build -t pluto-ubuntu -f test/Dockerfile.ubuntu test
docker run --rm -v "$PWD":/src:ro pluto-ubuntu zsh -lc '
  git config --global --add safe.directory /src
  git config --global --add safe.directory /src/.git
  git clone -q /src ~/pluto-src && cd ~/pluto-src && ./install.sh -y'
```

Swap in `Dockerfile.debian` for the other image. To exercise the semantic tier without a
model download inside the container, point it at an Ollama already running on the host:

```bash
docker run --rm -v "$PWD":/src:ro \
  -e PLUTO_OLLAMA_URL=http://host.docker.internal:11434 \
  --add-host=host.docker.internal:host-gateway \
  pluto-ubuntu zsh -lc '...as above... ./install.sh --semantic -y'
```

## Why two images

`Dockerfile.ubuntu` installs `git`, `python3`, `curl` and `zsh`, and nothing else. That is
the state Ubuntu actually ships in, including `python3` without `ensurepip`, so
`python3 -m venv` fails.

`Dockerfile.debian` additionally installs `python3-venv`, which makes it a happy-path
image.

That difference is the point. The Debian image was written first, its `python3-venv` line
looked like ordinary setup, and it hid a real bug completely: the installer selected an
interpreter that could not build a virtualenv, then aborted mid-run under `set -e` and
left a half-configured machine. It was only found when someone ran it on stock Ubuntu.

A test environment that installs the dependency you are trying to test for is not a test
environment. Keep the Ubuntu image bare.

## What is worth checking

- The core install completes and the verify phase passes even when every optional tier is
  declined or unavailable.
- A second run reports content files as left alone and writes no new ones.
- `zsh -lc` (login, not interactive) can still find `pluto`, which is what scripts, `ssh`
  and cron get.
- `zsh -ic` has the alias and `$_comps[pluto]` is `_pluto`.
- Deleting `~/pluto/.venv/lib` to simulate an interrupted install makes the next run
  report the virtualenv as incomplete and rebuild it.
