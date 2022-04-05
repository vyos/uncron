# uncron

Uncron is a simple job queue service that reads command from a UNIX domain socket
and executes them sequentially.

Its goal is to serve as an intermediate layer for tools that don't implement locking
and thus aren't safe to run in parallel.

## Installation

You need to install [OPAM](opam.ocaml.org/), the [OCaml](https://ocaml.org) package manager first.

Follow its [installation instructions](https://opam.ocaml.org/doc/Install.html).
OPAM is capable of installing the OCaml compiler itself and it will be 

```
# Initialize the opam environment and install the latest stable compiler
opam init

# Install dependencies
opam install lwt logs containers

# Build uncron
dune build

```

Then you can copy the `uncron` executable to somewehre in the `$PATH`.
On Linux, you can also use the systemd unit file from `data/uncron.service`.
