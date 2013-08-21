(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 * Copyright (c) 2013 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Util

type mode = [
  |`unix of [`direct | `socket ]
  |`xen
  |`kfreebsd
]

let make =
  match (Unix.system "type gmake > /dev/null 2> /dev/null") with
   | Unix.WEXITED 0 -> "gmake"
   | _ -> "make"

let generated_by_mirari =
  let t = Unix.gettimeofday () in
  let months = [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun";
                  "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec" |] in
  let days = [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |] in
  let time = Unix.gmtime t in
  let date =
    Printf.sprintf "%s, %d %s %d %02d:%02d:%02d GMT"
      days.(time.Unix.tm_wday) time.Unix.tm_mday
      months.(time.Unix.tm_mon) (time.Unix.tm_year+1900)
      time.Unix.tm_hour time.Unix.tm_min time.Unix.tm_sec in
  Printf.sprintf "Generated by Mirari (%s)." date

let ocaml_version () =
  let version =
    match cut_at Sys.ocaml_version '+' with
    | Some (version, _) -> version
    | None              -> Sys.ocaml_version in
  match split version '.' with
  | major :: minor :: _ ->
    begin
      try int_of_string major, int_of_string minor
      with _ -> 0, 0
    end
  | _ -> 0, 0

(* Headers *)
module Headers = struct

  let output oc =
    append oc "(* %s *)" generated_by_mirari;
    newline oc

end

(* Filesystem *)
module FS = struct

  type fs = {
    name: string;
    path: string;
  }

  type t = {
    dir: string;
    fs : fs list;
  }

  let create ~dir kvs =
    let kvs = filter_map (subcommand ~prefix:"fs") kvs in
    let aux (name, path) = { name; path } in
    { dir; fs = List.map aux kvs }

  let call t =
    if not (cmd_exists "mir-crunch") && t.fs <> [] then begin
      info "mir-crunch not found, so installing the mirage-fs package.";
      opam_install ["mirage-fs"];
    end;
    List.iter (fun { name; path} ->
        let path = Printf.sprintf "%s/%s" t.dir path in
        let file = Printf.sprintf "%s/filesystem_%s.ml" t.dir name in
        if Sys.file_exists path then (
          info "Creating %s." file;
          command "mir-crunch -o %s -name %S %s" file name path
        ) else
          error "The directory %s does not exist." path
      ) t.fs

  let output oc t =
    List.iter (fun { name; _ } ->
        append oc "open Filesystem_%s" name
      ) t.fs;
    newline oc

end

(* IP *)
module IP = struct

  type ipv4 = {
    address: string;
    netmask: string;
    gateway: string;
  }

  type t =
    | DHCP
    | IPv4 of ipv4
    | NOIP

  let create kvs =
    let kvs = filter_map (subcommand ~prefix:"ip") kvs in
    if kvs = [] then NOIP
    else
      let use_dhcp =
        try List.assoc "use-dhcp" kvs = "true"
        with _ -> false in
      if use_dhcp then
        DHCP
      else
        let address =
          try List.assoc "address" kvs
          with _ -> "10.0.0.2" in
        let netmask =
          try List.assoc "netmask" kvs
          with _ -> "255.255.255.0" in
        let gateway =
          try List.assoc "gateway" kvs
          with _ -> "10.0.0.1" in
        IPv4 { address; netmask; gateway }

  let output oc = function
    | NOIP   -> ()
    | DHCP   -> append oc "let ip = `DHCP"
    | IPv4 i ->
      append oc "let get = function Some x -> x | None -> failwith \"Bad IP!\"";
      append oc "let ip = `IPv4 (";
      append oc "  get (Ipaddr.V4.of_string %S)," i.address;
      append oc "  get (Ipaddr.V4.of_string %S)," i.netmask;
      append oc "  [get (Ipaddr.V4.of_string %S)]" i.gateway;
      append oc ")";
      newline oc

end

(* HTTP listening parameters *)
module HTTP = struct

  type http = {
    port   : int;
    address: string option;
  }

  type t = http option

  let create kvs =
    let kvs = filter_map (subcommand ~prefix:"http") kvs in
    if List.mem_assoc "port" kvs &&
       List.mem_assoc "address" kvs then
      let port = List.assoc "port" kvs in
      let address = List.assoc "address" kvs in
      let port =
        try int_of_string port
        with _ -> error "%S s not a valid port number." port in
      let address = match address with
        | "*" -> None
        | a   -> Some a in
      Some { port; address }
    else
      None

  let output oc = function
    | None   -> ()
    | Some t ->
      append oc "let listen_port = %d" t.port;
      begin
        match t.address with
        | None   -> append oc "let listen_address = None"
        | Some a -> append oc "let listen_address = Ipaddr.V4.of_string %S" a;
      end;
      newline oc

end

(* Main function *)
module Main = struct

  type t =
    | IP of string
    | HTTP of string
    | NOIP of string

  let create kvs =
    let kvs = filter_map (subcommand ~prefix:"main") kvs in
    let is_http = List.mem_assoc "http" kvs in
    let is_ip = List.mem_assoc "ip" kvs in
    let is_noip = List.mem_assoc "noip" kvs in
    match is_http, is_ip, is_noip with
    | false, false, false -> error "No main function is specified. You need to add 'main-{ip,http,noip}: <NAME>'."
    | true , false, false -> HTTP (List.assoc "http" kvs)
    | false, true, false  -> IP (List.assoc "ip" kvs)
    | false, false, true -> NOIP (List.assoc "noip" kvs)
    | _  -> error "Too many main functions."

  let output_http oc main =
    append oc "let main () =";
    append oc "  let spec = Cohttp_lwt_mirage.Server.({";
    append oc "    callback    = %s;" main;
    append oc "    conn_closed = (fun _ () -> ());";
    append oc "  }) in";
    append oc "  Net.Manager.create (fun mgr interface id ->";
    append oc "    Printf.eprintf \"listening to HTTP on port %%d\\\\n\" listen_port;";
    append oc "    Net.Manager.configure interface ip >>";
    append oc "    Cohttp_lwt_mirage.listen mgr (listen_address, listen_port) spec";
    append oc "  )"

  let output_ip oc main =
    append oc "let main () =";
    append oc "  Net.Manager.create (fun mgr interface id ->";
    append oc "    Net.Manager.configure interface ip >>";
    append oc "    %s mgr interface id" main;
    append oc "  )"

  let output_noip oc main = append oc "let main () = %s ()" main

  let output oc t =
    begin
      match t with
      | IP main   -> output_ip oc main
      | HTTP main -> output_http oc main
      | NOIP main -> output_noip oc main
    end;
    newline oc;
    append oc "let () = OS.Main.run (Lwt.join [main (); Backend.run ()])"

end

(* Makefile & opam file *)
module Build = struct

  type t = {
    name   : string;
    dir    : string;
    depends: string list;
    packages: string list;
  }

  let get name kvs =
    let kvs = List.filter (fun (k,_) -> k = name) kvs in
    List.fold_left (fun accu (_,v) ->
        List.map strip (split v ',') @ accu
      ) [] kvs

  let create ~dir ~name kvs =
    let depends = get "depends" kvs in
    let packages = get "packages" kvs in
    { name; dir; depends; packages }

  let output_myocamlbuild_ml t =
    let minor, major = ocaml_version () in
    if minor < 4 || major < 1 then (
      (* Previous ocamlbuild versions weren't able to understand the
         --output-obj rules *)
      let file = Printf.sprintf "%s/myocamlbuild.ml" t.dir in
      let oc = open_out file in
      append oc "(* %s *)" generated_by_mirari;
      newline oc;
      append oc "open Ocamlbuild_pack;;";
      append oc "open Ocamlbuild_plugin;;";
      append oc "open Ocaml_compiler;;";
      newline oc;
      append oc "let native_link_gen linker =";
      append oc "  link_gen \"cmx\" \"cmxa\" !Options.ext_lib [!Options.ext_obj; \"cmi\"] linker;;";
      newline oc;
      append oc "let native_output_obj x = native_link_gen ocamlopt_link_prog";
      append oc "  (fun tags -> tags++\"ocaml\"++\"link\"++\"native\"++\"output_obj\") x;;";
      newline oc;
      append oc "rule \"ocaml: cmx* & o* -> native.o\"";
      append oc "  ~tags:[\"ocaml\"; \"native\"; \"output_obj\" ]";
      append oc "  ~prod:\"%%.native.o\" ~deps:[\"%%.cmx\"; \"%%.o\"]";
      append oc "  (native_output_obj \"%%.cmx\" \"%%.native.o\");;";
      newline oc;
      newline oc;
      append oc "let byte_link_gen = link_gen \"cmo\" \"cma\" \"cma\" [\"cmo\"; \"cmi\"];;";
      append oc "let byte_output_obj = byte_link_gen ocamlc_link_prog";
      append oc "  (fun tags -> tags++\"ocaml\"++\"link\"++\"byte\"++\"output_obj\");;";
      newline oc;
      append oc "rule \"ocaml: cmo* -> byte.o\"";
      append oc "  ~tags:[\"ocaml\"; \"byte\"; \"link\"; \"output_obj\" ]";
      append oc "  ~prod:\"%%.byte.o\" ~dep:\"%%.cmo\"";
      append oc "  (byte_output_obj \"%%.cmo\" \"%%.byte.o\");;";
      close_out oc
    )

  let output ~mode t =
    let file = Printf.sprintf "%s/Makefile" t.dir in
    let depends = match mode with
      | `unix _ -> "fd-send-recv" :: t.depends
      | _       -> t.depends in
    (* XXX: weird dependency error on OCaml < 4.01 *)
    let depends = "lwt.syntax" :: depends in
    let depends = match depends with
      | [] -> ""
      | ds -> "-pkgs " ^ String.concat "," ds in
    let ext = match mode with
      | `unix _ -> "native"
      | `xen | `kfreebsd -> "native.o" in
    let oc = open_out file in
    append oc "# %s" generated_by_mirari;
    newline oc;
    append oc "PHONY: clean main.native";
    newline oc;
    append oc "_build/.stamp:";
    append oc "\trm -rf _build";
    append oc "\tmkdir -p _build/lib";
    append oc "\t@touch $@";
    newline oc;
    append oc "main.native: _build/.stamp";
    append oc "\tocamlbuild -classic-display -use-ocamlfind -lflag -linkpkg %s %s -tags \"syntax(camlp4o)\" main.%s%s"
      (match mode with
       |`unix _ -> ""
       |`xen | `kfreebsd -> "-lflag -dontlink -lflag unix")
      depends ext
      (match mode with
       |`unix _ | `xen -> ""
       |`kfreebsd -> " module.o");
    newline oc;
    append oc "build: main.native";
    append oc "\t@ :";
    newline oc;
    append oc "clean:";
    append oc "\tocamlbuild -clean";
    close_out oc;
    output_myocamlbuild_ml t

  let check t =
    if t.packages <> [] && not (cmd_exists "opam") then
      error "OPAM is not installed."

  let prepare ~mode t =
    check t;
    let os =
      match mode with
      | `unix _ -> "mirage-unix"
      | `xen -> "mirage-xen" 
      | `kfreebsd -> "mirage-kfreebsd"
    in
    let net =
      match mode with
      | `kfreebsd | `xen | `unix `direct -> "mirage-net-direct"
      | `unix `socket -> "mirage-net-socket"
    in
    let ps = os :: net :: t.packages in
    opam_install ps
end

module Backend = struct

  let output ~mode dir =
    let file = Printf.sprintf "%s/backend.ml" dir in
    info "+ creating %s" file;
    let oc = open_out file in
    append oc "(* %s *)" generated_by_mirari;
    newline oc;
    match mode with
    |`unix `direct ->
      append oc "let (>>=) = Lwt.bind

let run () =
  let backlog = 5 in
  let sockaddr = Unix.ADDR_UNIX (Printf.sprintf \"/tmp/mir-%%d.sock\" (Unix.getpid ())) in
  let sock = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
  let () = Lwt_unix.bind sock sockaddr in
  let () = Lwt_unix.listen sock backlog in

  let rec accept_loop () =
    Lwt_unix.accept sock
    >>= fun (fd, saddr) ->
    Printf.printf \"[backend]: Receiving connection from mirari.\\n%%!\";
    let unix_fd = Lwt_unix.unix_file_descr fd in
    let msgbuf = String.create 11 in
    let nbread, sockaddr, recvfd = Fd_send_recv.recv_fd unix_fd msgbuf 0 11 [] in
    let () = Printf.printf \"[backend]: %%d bytes read, received fd %%d\\n%%!\" nbread (Fd_send_recv.int_of_fd recvfd) in
    let id = (OS.Netif.id_of_string (String.trim (String.sub msgbuf 0 10))) in
    let devtype = (if msgbuf.[10] = 'p' then OS.Netif.PCAP else OS.Netif.ETH) in
    OS.Netif.add_vif id devtype recvfd;
    Lwt_unix.(shutdown fd SHUTDOWN_ALL); (* Done, we can shutdown the connection now *)
    accept_loop ()
  in accept_loop ()"
    | _ ->
      append oc "let run () = Lwt.return ()"

end

module XL = struct
  let output name kvs =
    info "+ creating %s" (name ^ ".xl");
    let oc = open_out (name ^ ".xl") in
    finally
      (fun () ->
         output_kv oc (["name", "\"" ^ name ^ "\"";
                        "kernel", "\"mir-" ^ name ^ ".xen\""] @
                         filter_map (subcommand ~prefix:"xl") kvs) "=")
      (fun () -> close_out oc);
end

module KLD = struct
  let output dir name =
    let mfile = Printf.sprintf "%s/module.c" dir in
    info "+ creating %s" mfile;
    let mc = open_out mfile in
    append mc "#define _KERNEL 1
#define KLD_MODULE 1

#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/module.h>

extern int event_handler(module_t m, int w, void *p);

static moduledata_t conf = {
	\"mir-%s\"
,	event_handler
,	NULL
};

DECLARE_MODULE(mir_%s, conf, SI_SUB_KLD, SI_ORDER_ANY);
" name name
end

(* A type describing all the configuration of a mirage unikernel *)
type t = {
  file     : string;           (* Path of the mirari config file *)
  mode     : mode;             (* backend target *)
  name     : string;           (* Filename of the mirari config file*)
  dir      : string;           (* Dirname of the mirari config file *)
  main_ml  : string;           (* Name of the entry point function *)
  kvs      : (string * string) list;
  fs       : FS.t;             (* A value describing FS configuration *)
  ip       : IP.t;
  http     : HTTP.t;
  main     : Main.t;
  build    : Build.t;
}

let create mode file =
  let dir     = Filename.dirname file in
  let name    = Filename.chop_extension (Filename.basename file) in
  let lines   = lines_of_file file in
  let kvs     = filter_map key_value lines in
  let main_ml = Printf.sprintf "%s/main.ml" dir in
  let fs      = FS.create ~dir kvs in
  let ip      = IP.create kvs in
  let http    = HTTP.create kvs in
  let main    = Main.create kvs in
  let build   = Build.create ~name ~dir kvs in
  { file; mode; name; dir; main_ml; kvs; fs; ip; http; main; build }


let output_main t =
  let oc = open_out t.main_ml in
  Headers.output oc;
  FS.output oc t.fs;
  IP.output oc t.ip;
  HTTP.output oc t.http;
  Main.output oc t.main;
  close_out oc

let call_crunch_scripts t =
  FS.call t.fs

let call_xen_scripts t =
  let obj = "_build/main.native.o" in
  let target = "_build/main.xen" in
  if Sys.file_exists obj then begin
    let path = read_command "ocamlfind printconf path" in
    let lib = strip path ^ "/mirage-xen" in
    command "ld -d -nostdlib -m elf_x86_64 -T %s/mirage-x86_64.lds %s/x86_64.o %s %s/libocaml.a %s/libxen.a \
             %s/libxencaml.a %s/libdiet.a %s/libm.a %s/longjmp.o -o %s"  lib lib obj lib lib lib lib lib lib target;
    command "ln -nfs _build/main.xen mir-%s.xen" t.name;
    command "nm -n mir-%s.xen | grep -v '\\(compiled\\)\\|\\(\\.o$$\\)\\|\\( [aUw] \\)\\|\\(\\.\\.ng$$\\)\\|\\(LASH[RL]DI\\)' > mir-%s.map" t.name t.name
  end else
    error "xen object file %s not found, cannot continue" obj

let call_kfreebsd_scripts t =
  let obj    = "_build/main.native.o" in
  let target = "_build/main.ko"  in
  let glue = "_build/module.o" in
  if Sys.file_exists obj then begin
    let path = read_command "ocamlfind printconf path" in
    let lib = strip path ^ "/mirage-kfreebsd" in
    command "ld -nostdlib -r -d -o %s %s %s %s/libmir.a" target obj glue lib;
    command "objcopy --strip-debug %s" target;
    command "ln -nfs %s mir-%s.ko" target t.name
  end else
    error "kFreeBSD object file %s not found, cannot continue" obj

let call_build_scripts ~mode t =
  let makefile = Printf.sprintf "%s/Makefile" t.dir in
  if Sys.file_exists makefile then (
    in_dir t.dir (fun () -> command "%s build" make);
    (* gen_xen.sh *)
    match mode with
    |`xen -> call_xen_scripts t
    |`unix _ ->
      command "ln -nfs _build/main.native mir-%s" t.name
    |`kfreebsd -> call_kfreebsd_scripts t
  ) else
    error "You should run 'mirari configure %s' first." t.file

let configure ~mode ~no_install file =
  let file = scan_conf file in
  let t = create mode file in
  (* Generate main.ml *)
  info "Generating %s." t.main_ml;
  output_main t;
  (* Generate the Makefile *)
  Build.output ~mode t.build;
  (* Generate the Backend module *)
  Backend.output ~mode t.dir;
  (* Generate the XL config file if backend = Xen *)
  if mode = `xen then XL.output t.name t.kvs;
  (* Generate the KLD glue file if backend = kFreeBSD *)
  if mode = `kfreebsd then KLD.output t.dir t.name;
  (* install OPAM dependencies *)
  if not no_install then Build.prepare ~mode t.build;
  (* crunch *)
  call_crunch_scripts t

let build ~mode file =
  let file = scan_conf file in
  let t = create mode file in
  (* build *)
  call_build_scripts ~mode t

let run ~mode file =
  let file = scan_conf file in
  let t = create mode file in
  match mode with
  |`unix `socket ->
    info "+ unix socket mode";
    Unix.execv ("mir-" ^ t.name) [||] (* Just run it! *)
  |`unix `direct ->
    info "+ unix direct mode";
    (* unix-direct backend: launch the unikernel, then create a TAP
       interface and pass the fd to the unikernel *)
    let cpid = Unix.fork () in
    if cpid = 0 then (* child code *)
      Unix.execv ("mir-" ^ t.name) [||] (* Launch the unikernel *)
    else
      begin
        try
          info "Creating tap0 interface.";
          (* Force the name to be "tap0" because of MacOSX *)
          let fd, id =
            (try
               let fd, id = Tuntap.opentap ~devname:"tap0" () in
               (* TODO: Do not hardcode 10.0.0.1, put it in mirari config file *)
               let () = Tuntap.set_ipv4 ~devname:"tap0" ~ipv4:"10.0.0.1" () in
               fd, id
             with Failure m ->
               Printf.eprintf "[mirari] Tuntap failed with error %s. Remember that %s has to be run as root have the CAP_NET_ADMIN \
                               capability in order to be able to run unikernels for the UNIX backend" m Sys.argv.(0);
               raise (Failure m)) (* Go to cleanup section *)
          in
          let sock = Unix.(socket PF_UNIX SOCK_STREAM 0) in

          let send_fd () =
            let open Unix in
            sleep 1;
            info "Connecting to /tmp/mir-%d.sock..." cpid;
            connect sock (ADDR_UNIX (Printf.sprintf "/tmp/mir-%d.sock" cpid));
            let nb_sent = Fd_send_recv.send_fd sock "tap0      e" 0 11 [] fd in
            if nb_sent <> 11 then
              (error "Sending fd to unikernel failed.")
            else info "Transmitted fd ok."
          in
          send_fd ();
          let _,_ = Unix.waitpid [] cpid in ()
        with exn ->
          info "Ctrl-C received, killing child and exiting.\n%!";
          Unix.kill cpid 15; (* Send SIGTERM to the unikernel, and then exit ourselves. *)
          raise exn
      end
  |`xen -> (* xen backend *)
    info "+ xen mode";
    Unix.execvp "xl" [|"xl"; "create"; "-c"; t.name ^ ".xl"|]
  |`kfreebsd -> (* kfreebsd backend *)
    info "+ FreeBSD kernel module mode";
    let kmod = ("mir-" ^ t.name ^ ".ko") in
    let cpid = Unix.fork () in
    if cpid = 0 then
      begin
        command "/sbin/kldload ./%s" kmod;
        info "Kernel module loaded, sleeping.  (Hit Ctrl+C to stop.)";
        let rec loop () = Unix.sleep 5; loop ()
        in loop ()
      end
    else
      begin
        try
          (* Waiting for the user to terminate the process, 
           * keep the module running in the meantime.
           *)
          let _,_ = Unix.waitpid [] cpid in ()
        with
          | Sys.Break ->
              info "Ctrl-C received, unloading the kernel module and exiting.%!";
              command "/sbin/kldunload %s" kmod;
              info "Kernel module unloaded.%!";
          | exn -> raise exn
      end

let clean file =
  let file = scan_conf file in
  let t = create `xen file in
  in_dir t.dir (fun () ->
      command "%s clean" make;
      command "rm -f main.ml myocamlbuild.ml Makefile mir-* backend.ml module.c filesystem_*.ml *.xl *.map"
    )
