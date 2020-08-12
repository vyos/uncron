all: uncron

uncron: uncron.ml
	ocamlfind ocamlopt -package lwt,lwt.unix,lwt_ppx,logs,logs.lwt -linkpkg -o uncron -g ./uncron.ml
