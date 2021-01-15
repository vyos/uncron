all: uncron

uncron: uncron.ml
	ocamlfind ocamlopt -I +threads -package lwt,lwt.unix,lwt_ppx,logs,logs.lwt -linkpkg -thread -o uncron -g ./uncron.ml
