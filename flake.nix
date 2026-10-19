{
  description = "enchiridion, an autonomous agent harness written in Common Lisp";
  # nixpkgs-unstable, tracked by branch; flake.lock pins the commit, so a build
  # is reproducible until `nix flake update nixpkgs` moves it. Unstable because
  # no release channel has SBCL 2.6 (NixOS 25.05 has 2.5.4); nixpkgs has 2.6.8
  # here, so the flake builds 2.6.9 from source and Nix and Docker agree.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      pkgsFor = system: import nixpkgs { inherit system; };
      # SBCL 2.6.9, wrapped the way nixpkgs wraps its own. The nixpkgs SBCL is
      # the bootstrap compiler: the default aarch64-darwin bootstrap is ECL, and
      # an ECL bootstrap takes hours where a host SBCL takes minutes.
      sbclVersion = "2.6.9";
      mkSbcl = pkgs:
        let
          base = pkgs.callPackage (nixpkgs.outPath + "/pkgs/development/compilers/sbcl") {
            # The 2.6.8 hash satisfies nixpkgs' version table; the override
            # below replaces both the version and the source.
            version = "2.6.8";
            bootstrapLisp = "${pkgs.sbcl}/bin/sbcl --disable-debugger --no-userinit --no-sysinit";
          };
        in
        pkgs.wrapLisp {
          pkg = base.overrideAttrs (old: {
            version = sbclVersion;
            src = pkgs.fetchurl {
              url = "mirror://sourceforge/project/sbcl/sbcl/${sbclVersion}/sbcl-${sbclVersion}-source.tar.bz2";
              hash = "sha256-xv0dc1Vw60/zTK+WCZiMp37QvRK1XQmk/tB1vokNpRM=";
            };
            # Darwin only. nixpkgs substitutes ${posixUtils}/bin/env into SBCL's
            # sources, and there posixUtils is darwin.shell_cmds
            # (sbcl/default.nix:73, :214-215). That path is baked into the
            # compiled core, so shell_cmds and its 267 MB bootstrap-tools chain
            # land in every closure holding SBCL; coreutils is a few MB. The
            # rewrite goes in sbclPatchPhase, after nixpkgs' own substitution:
            # postPatch runs before it and would see none of these strings.
            sbclPatchPhase = (old.sbclPatchPhase or "") + lib.optionalString
              pkgs.stdenv.hostPlatform.isDarwin ''
                (
                  shopt -s nullglob
                  substituteInPlace {tests,src/code}/*.{lisp,sh} \
                    --replace-quiet "${pkgs.darwin.shell_cmds}" "${pkgs.coreutils}"
                )
              '';
          });
          faslExt = "fasl";
          flags = [ "--dynamic-space-size" "3000" ];
        };
      # Nix must never read a secret: it hashes every file it is handed into a
      # world-readable store path, so one builtins.readFile ./.env would turn the
      # key into a permanent public string. This filter is the only thing between
      # .env and the binary cache: deny by default, nothing reaches Nix unfiltered.
      #
      # The rules match the path inside this checkout, so they take the relative
      # path. An earlier version took the head of the absolute path: for
      # /Users/penny/.../enchiridion/.env that is "", not ".env", so every
      # segment rule was dead and the file would have been copied into the store
      # like any other source file. The bug was invisible until it was tested.
      source-root = toString ./.;
      relative-path = path:
        let text = toString path;
        in if text == source-root then "" else lib.removePrefix (source-root + "/") text;
      denied = path:
        let
          relative = relative-path path;
          segments = if relative == "" then [ ] else lib.splitString "/" relative;
          base = baseNameOf (toString path);
          first = if segments == [ ] then "" else lib.head segments;
          agent-state = first == "agents"
            && (base == "state.json" || lib.hasPrefix "state.json." base
                || base == "memory.db" || lib.hasPrefix "memory.db-" base
                || lib.elem "private" segments);
        in
        lib.elem base [ ".DS_Store" ]
        # The operator config and the working plan sit at the root only; matching
        # the basename anywhere also excluded src/enchiridion/config.cl, a source
        # module and not the operator's file.
        || relative == "config.cl"
        || relative == "PLAN.md"
        # .env and .env.* anywhere: the secret is beside the code, and a nested
        # copy is just as readable from the store.
        || base == ".env"
        || lib.hasPrefix ".env." base
        # result-* is the .gitignore form of a build output symlink; VCS and
        # cache directories match at any depth because a vendored checkout can
        # carry its own .git.
        || base == "result"
        || lib.hasPrefix "result-" base
        || builtins.any (segment: lib.elem segment [ ".git" ".direnv" ".asdf" ]) segments
        # Runtime and test scratch at the root only. The property tests write
        # enchiridion-property* into their current directory because the build
        # sandbox has nowhere else to write.
        || lib.elem first [ "run" "enchiridion-property" "enchiridion-property-agents" ]
        # Per-agent runtime state: the Markdown seeds and the example skills and
        # tools stay in the source; state.json, memory.db and private/ hold what
        # the agent has learned.
        || agent-state;
      # The filter is code and code can regress, so the two files it exists to
      # stop are checked after it runs: a broken rule fails the evaluation.
      source =
        let
          filtered = builtins.path {
            path = ./.; name = "enchiridion-source";
            filter = path: _type: !(denied path);
          };
        in
        if builtins.pathExists (filtered + "/.env")
        || builtins.pathExists (filtered + "/config.cl") then
          throw "the source filter let a secret or the operator config into the store"
        else filtered;
      # Every dependency named in the plan, as names rather than derivations: the
      # same list names the packages in the set and the directories ASDF
      # searches. Nothing outside it is reachable from a build.
      lispPackageNames = [
        "cl-dbi" "dbd-sqlite3" "dexador" "cl-jschema" "com_dot_inuoe_dot_jzon"
        "hunchentoot" "websocket-driver-client" "chanl" "cl-ppcre" "cl-base64"
        "alexandria" "usocket" "bordeaux-threads" "trivial-backtrace" "rove"
        "cl-quickcheck"
      ];
      # Every library in the transitive closure, not just the direct ones: rove
      # pulls in dissect, dexador pulls in fifteen more, and a registry naming
      # only the direct list finds a system whose own dependency is missing.
      # Followed by hand because lispWithPackages sets propagatedBuildInputs to
      # exactly the list it was given, so the wrapper omits the closure.
      lispClosure = pkgs:
        let
          package-set = (mkSbcl pkgs).pkgs;
          direct = map (name: package-set.${name}) lispPackageNames;
          walk = seen: pending:
            let fresh = builtins.filter (p: !(builtins.elem p seen)) pending;
            in if fresh == [ ] then seen
               else walk (seen ++ fresh)
                         (builtins.concatMap (p: p.propagatedBuildInputs or [ ]) fresh);
        in
        walk [ ] direct;
      # What a build and the dev shell run is the raw interpreter: at this
      # nixpkgs revision the `withPackages` wrapper's install phase writes
      # `--prefix CL_SOURCE_REGISTRY : "$CL_SOURCE_REGISTRY:"` and a second
      # `--prefix` holding ASDF's `::` syntax, which makeBinaryWrapper rejects as
      # empty PATH-like segments (GHSA-p7v3-pr2c-8584), so it never builds. The
      # registry is built here and exported instead.
      source-registry = pkgs: extra:
        lib.concatStringsSep ":"
          ((map (path: "${path}//") (lispClosure pkgs)) ++ extra);
      # The dev shell's registry adds slynk. The checkout is not named here:
      # inside the flake `./.` is the read-only store copy, so the shell hook
      # prepends its own directory. SLY is two halves in nixpkgs and neither is
      # the attribute `sly` (a Linux-only Flutter image editor, which is what
      # broke this shell on aarch64-darwin): the Lisp half is slynk and the Emacs
      # half is emacsPackages.sly. slynk stays out of lispPackageNames because a
      # built agent must not carry a debugger front end.
      devRegistry = pkgs:
        source-registry pkgs [ "${(mkSbcl pkgs).pkgs.slynk}//" ];
      # Two warnings come from dependencies this project does not own and are
      # muffled; every other condition reaches the handler-case, which prints it
      # and exits 1, so a gate cannot report success on a build that died.
      muffled = body: ''
        (handler-bind ((warning (lambda (condition)
                                   (let ((report (princ-to-string condition)))
                                     (when (or (search "redefining DEFTYPE type to be a class" report)
                                               (search "bare references to struct types are deprecated" report))
                                       (muffle-warning condition))))))
          (handler-case (progn ${body})
            (error (condition) (format *error-output* "~&~A~%" condition) (sb-ext:exit :code 1))))'';
      # The gate embeds this in a double-quoted shell word; escape its quotes.
      shellQuoted = text: lib.replaceStrings [ "\"" ] [ "\\\"" ] text;
      # The entry scripts are not system components, so build and gate compile
      # them here. COMPILE-FILE reports a read error by returning FAILURE-P true,
      # not by signalling; ignoring that is how a gate reports success on a file
      # it never compiled.
      compileEntry = ''
        (flet ((compile-entry (source output)
                 (multiple-value-bind (fasl warnings-p failure-p)
                     (compile-file source :output-file output)
                   (declare (ignore fasl warnings-p))
                   (when failure-p (error "compile-file reported a failure for ~A" source)))))'';
      # Compiling the system is the check. Warnings are errors, so this
      # derivation is the gate rather than a separate one that can drift.
      mkEnchiridion = { pkgs }:
        let
          sbcl = mkSbcl pkgs;
          # openssl because dexador pulls in cl+ssl, which dlopens libcrypto at
          # load time, and sqlite because the memory store opens it: an RPATH is
          # not enough, and without these on LD_LIBRARY_PATH the system loads
          # until the first HTTPS call and dies inside CFFI.
          library-path = lib.makeLibraryPath [ pkgs.sqlite pkgs.openssl ];
          # Load every dependency from the fasl beside its source: Nix built each
          # with this SBCL, so this build compiles only this system's own files.
          registry = source-registry pkgs [ "$out/lib" ];
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "enchiridion";
          version = "0.1.0";
          src = source;
          nativeBuildInputs = [ sbcl pkgs.sqlite pkgs.makeWrapper ];
          buildInputs = [ pkgs.sqlite ];
          # No configure step and no Makefile, but the compilation below is the
          # build and the check; dontBuild would skip it.
          dontConfigure = true;
          # Compile once into a scratch cache. Nothing runs as this derivation's
          # output until the compiler has had its say, so this phase is the gate
          # that nix run .#check runs.
          buildPhase = ''
            runHook preBuild
            mkdir -p "$out/lib" "$out/cache" "$out/config" "$out/bin"
            # Only the system and its sources ship: t/, docs/, docker/,
            # compose.yml, flake.nix, README.md and LICENSE are not runtime
            # inputs, and the store copy is world readable.
            cp -r "$src/src" "$src/enchiridion.asd" "$out/lib/"
            chmod -R u+w "$out"
            export XDG_CACHE_HOME="$TMPDIR/build-cache"
            export XDG_CONFIG_HOME="$TMPDIR/build-config"
            export CL_SOURCE_REGISTRY="${registry}"
            # Identity translation: a fasl is looked for beside its source. The
            # dependencies' fasls are in the store beside their sources, and the
            # copy of src/ in $out/lib is writable during the build, so this
            # system's fasls land there too.
            export ASDF_OUTPUT_TRANSLATIONS='(:output-translations (t nil) :ignore-inherited-configuration)'
            export SBCL_HOME="${sbcl}/lib/sbcl"
            export LD_LIBRARY_PATH="${library-path}"
            ${sbcl}/bin/sbcl \
              --non-interactive --no-userinit --no-sysinit \
              --eval '(require :asdf)' \
              --eval '${muffled ''
                (asdf:load-system "enchiridion")
                ${compileEntry}
                (let ((root (uiop:pathname-directory-pathname *default-pathname-defaults*)))
                  (compile-entry (merge-pathnames "src/main.cl" root)
                                 (merge-pathnames "main.fasl" #p"."))
                  (compile-entry (merge-pathnames "src/broker-exec.cl" root)
                                 (merge-pathnames "broker-exec.fasl" #p"."))))''}'
            # The cache stays empty: the identity translation writes the fasls
            # beside the sources in $out/lib, and the wrapper points here anyway.
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            makeWrapper ${sbcl}/bin/sbcl "$out/bin/enchiridion" \
              --prefix SBCL_HOME : "${sbcl}/lib/sbcl" \
              --prefix CL_SOURCE_REGISTRY : "${registry}" \
              --prefix LD_LIBRARY_PATH : "${library-path}" \
              --set ASDF_OUTPUT_TRANSLATIONS "(:output-translations (t nil) :ignore-inherited-configuration)" \
              --set XDG_CACHE_HOME "$out/cache" \
              --set XDG_CONFIG_HOME "$out/config" \
              --set ENCHIRIDION_SOURCE "$out/lib" \
              --set ENCHIRIDION_SBCL "${sbcl}/bin/sbcl" \
              --add-flags '--script' \
              --add-flags "\"$out/lib/src/main.cl\""

            runHook postInstall
          '';

          passthru = { inherit sbcl; };
          meta = {
            description = "Autonomous agent harness written in Common Lisp";
            license = lib.licenses.bsd0;
            mainProgram = "enchiridion";
            platforms = systems;
          };
        };

      # Cheap, and it catches a broken attribute path long before a build fails.
      flake-check = { pkgs, system }:
        pkgs.runCommand "enchiridion-flake-check" { } ''
          echo "enchiridion flake evaluates for ${system}"
          touch "$out"
        '';

      # The gate. It compiles the entry scripts too, which the system cannot do
      # because loading a system must never start an agent, and it gets its own
      # source input: the package holds only the compiled system, and the tests
      # are recompiled into the writable gate cache under the test policy.
      mkGate = { pkgs, run-tests }:
        let
          enchiridion = mkEnchiridion { inherit pkgs; };
          sbcl = mkSbcl pkgs;
          name = if run-tests then "enchiridion-test" else "enchiridion-check";
          registry = source-registry pkgs [ "${enchiridion}/lib" "${source}/t" ];
        in
        pkgs.runCommand name
          {
            # bash, coreutils and git are for the tests: the sandbox exposes only
            # the declared inputs, so without them /bin/sh, id and git do not exist
            # and a broken run-program is indistinguishable from a missing program.
            nativeBuildInputs = [ sbcl pkgs.sqlite pkgs.bash pkgs.coreutils pkgs.git ];
            LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.sqlite pkgs.openssl ];
            SBCL_HOME = "${sbcl}/lib/sbcl";
            REGISTRY = registry;
            SOURCE_DIR = "${source}";
          }
          ''
            mkdir -p gate-cache gate-config

            export XDG_CACHE_HOME="$PWD/gate-cache"
            export XDG_CONFIG_HOME="$PWD/gate-config"
            export GATE_DIR="$PWD/gate-cache"
            export CL_SOURCE_REGISTRY="$REGISTRY"
            # Dependencies and the built system load from the fasl beside their
            # source in the store. The test sources come from this gate's own
            # input and the store is read-only, so their output goes to the
            # writable gate cache; they are the only sources compiled here.
            export ASDF_OUTPUT_TRANSLATIONS="(:output-translations ((\"$SOURCE_DIR/t/\" :**/ :*.*.*) \"$GATE_DIR/t/\") (t nil) :ignore-inherited-configuration)"

            run_sbcl() {
              ${sbcl}/bin/sbcl --non-interactive --no-userinit --no-sysinit \
                --eval '(require :asdf)' \
                --eval "${shellQuoted (muffled "$1")}"
            }

            echo "compiling the entry scripts, which are not system components"
            run_sbcl '(asdf:load-system "enchiridion")
                       ${compileEntry}
                       (let* ((root (pathname (format nil "~A/" (uiop:getenv "SOURCE_DIR"))))
                              (out (pathname (uiop:getenv "GATE_DIR"))))
                         (compile-entry (merge-pathnames "src/main.cl" root)
                                        (merge-pathnames "main.fasl" out))
                         (compile-entry (merge-pathnames "src/broker-exec.cl" root)
                                        (merge-pathnames "broker-exec.fasl" out))))'

            ${if run-tests then ''
              echo "running the suite"
              run_sbcl '(asdf:test-system "enchiridion-tests")'
              run_sbcl '(asdf:test-system "enchiridion-tests/property")'
            '' else ''
              echo "no tests requested"
            ''}

            # This binary exists so nix run finds something to execute; it never
            # runs when the gate failed, because nix stops before install.
            mkdir -p "$out/bin"
            printf '#!/bin/sh\necho "%s passed.\\n"\n' "${name}" > "$out/bin/${name}"
            chmod 755 "$out/bin/${name}"
          '';
      # One lazy evaluation per system, sliced four ways below.
      perSystem = system:
        let
          pkgs = pkgsFor system;
          sbcl = mkSbcl pkgs;
          # Both libraries load by name; Darwin also needs DYLD_LIBRARY_PATH.
          library-path = lib.makeLibraryPath [ pkgs.sqlite pkgs.openssl ];
          enchiridion = mkEnchiridion { inherit pkgs; };
          check = mkGate { inherit pkgs; run-tests = false; };
          test = mkGate { inherit pkgs; run-tests = true; };
          # The interpreter has no wrapper, so the shell carries the variables
          # that make it usable. The translation is the build's identity
          # translation, so a dependency's fasl loads from the store beside its
          # source rather than recompiling, and this system's own fasls land in
          # the checkout, which .gitignore covers.
          #
          # The default shell is the lean one: mkShell propagates stdenv-darwin
          # (1.3 GB) and pkgs.git pulls python3, which pulls the same toolchain
          # (1.6 GB), so it takes mkShellNoCC and gitMinimal instead. The C
          # toolchain is only needed to compile a new C-backed dependency by
          # hand, so it and full git stay behind `nix develop .#full`.
          mkDevShell = { shell, git, extra ? [ ], banner ? "" }: shell {
            name = "enchiridion-dev";
            packages = [ sbcl pkgs.sqlite pkgs.nixfmt-rfc-style git ] ++ extra;
            SBCL_HOME = "${sbcl}/lib/sbcl";
            CL_SOURCE_REGISTRY = devRegistry pkgs;
            ASDF_OUTPUT_TRANSLATIONS = "(:output-translations (t nil) :ignore-inherited-configuration)";
            LD_LIBRARY_PATH = library-path;
            DYLD_LIBRARY_PATH = library-path;
            shellHook = ''
              # The live checkout goes on the registry in front of the store:
              # `./.` is the read-only store copy, so the REPL loads the tree the
              # operator is editing.
              export CL_SOURCE_REGISTRY="$PWD//:$CL_SOURCE_REGISTRY"
              echo "enchiridion dev shell. Every dependency is in ASDF; there is no Quicklisp."
              echo "  nix run .#check              compile every file, warnings fail"
              echo "  nix run .#test               run the suite"
              echo "  nix run .#enchiridion        first launch"
              echo "  sbcl                         start a REPL"
              echo '  (asdf:load-system "slynk")   start the SLY server for an Emacs client'
              ${banner}
            '';
          };
        in
        {
          devShells = {
            default = mkDevShell { shell = pkgs.mkShellNoCC; git = pkgs.gitMinimal; };
            full = mkDevShell {
              shell = pkgs.mkShell; git = pkgs.git;
              extra = [ pkgs.colima pkgs.clang-tools ];
              banner = ''echo "This is the heavy shell: the C toolchain and full git are on PATH."'';
            };
          };

          packages = {
            inherit enchiridion;
            # Lazy attributes: the Linux cross-builds cost nothing until asked for.
            enchiridion-aarch64-linux = mkEnchiridion { pkgs = pkgsFor "aarch64-linux"; };
            enchiridion-x86_64-linux = mkEnchiridion { pkgs = pkgsFor "x86_64-linux"; };
          };
          apps = {
            default = { type = "app"; program = "${enchiridion}/bin/enchiridion"; };
            check = { type = "app"; program = "${check}/bin/enchiridion-check"; };
            test = { type = "app"; program = "${test}/bin/enchiridion-test"; };
          };

          checks = {
            flake = flake-check { inherit pkgs system; };
            inherit enchiridion check;
            default = test;
          };
        };

      bySystem = lib.genAttrs systems perSystem;
    in
    {
      devShells = lib.mapAttrs (_: v: v.devShells) bySystem;
      packages = lib.mapAttrs (_: v: v.packages) bySystem;
      apps = lib.mapAttrs (_: v: v.apps) bySystem;
      checks = lib.mapAttrs (_: v: v.checks) bySystem;
      formatter = lib.genAttrs systems (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
