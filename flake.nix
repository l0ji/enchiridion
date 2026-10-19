{
  description = "enchiridion, an autonomous agent harness written in Common Lisp";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      pkgsFor = system: import nixpkgs { inherit system; };
      sbclVersion = "2.6.9";
      mkSbcl = pkgs:
        let
          base = pkgs.callPackage (nixpkgs.outPath + "/pkgs/development/compilers/sbcl") {
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
        || relative == "config.cl"
        || relative == "PLAN.md"
        || base == ".env"
        || lib.hasPrefix ".env." base
        || base == "result"
        || lib.hasPrefix "result-" base
        || builtins.any (segment: lib.elem segment [ ".git" ".direnv" ".asdf" ]) segments
        || lib.elem first [ "run" "enchiridion-property" "enchiridion-property-agents" ]
        || agent-state;
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
      lispPackageNames = [
        "cl-dbi" "dbd-sqlite3" "dexador" "cl-jschema" "com_dot_inuoe_dot_jzon"
        "hunchentoot" "websocket-driver-client" "chanl" "cl-ppcre" "cl-base64"
        "alexandria" "usocket" "bordeaux-threads" "trivial-backtrace" "rove"
        "cl-quickcheck"
      ];
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
      source-registry = pkgs: extra:
        lib.concatStringsSep ":"
          ((map (path: "${path}//") (lispClosure pkgs)) ++ extra);
      devRegistry = pkgs:
        source-registry pkgs [ "${(mkSbcl pkgs).pkgs.slynk}//" ];
      muffled = body: ''
        (handler-bind ((warning (lambda (condition)
                                   (let ((report (princ-to-string condition)))
                                     (when (or (search "redefining DEFTYPE type to be a class" report)
                                               (search "bare references to struct types are deprecated" report))
                                       (muffle-warning condition))))))
          (handler-case (progn ${body})
            (error (condition) (format *error-output* "~&~A~%" condition) (sb-ext:exit :code 1))))'';
      shellQuoted = text: lib.replaceStrings [ "\"" ] [ "\\\"" ] text;
      compileEntry = ''
        (flet ((compile-entry (source output)
                 (multiple-value-bind (fasl warnings-p failure-p)
                     (compile-file source :output-file output)
                   (declare (ignore fasl warnings-p))
                   (when failure-p (error "compile-file reported a failure for ~A" source)))))'';
      mkEnchiridion = { pkgs }:
        let
          sbcl = mkSbcl pkgs;
          library-path = lib.makeLibraryPath [ pkgs.sqlite pkgs.openssl ];
          registry = source-registry pkgs [ "$out/lib" ];
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "enchiridion";
          version = "0.1.0";
          src = source;
          nativeBuildInputs = [ sbcl pkgs.sqlite pkgs.makeWrapper ];
          buildInputs = [ pkgs.sqlite ];
          dontConfigure = true;
          # Compiling the system is the check, so this derivation is the gate
          # that nix run .#check runs, and dontBuild would skip it.
          buildPhase = ''
            runHook preBuild
            mkdir -p "$out/lib" "$out/cache" "$out/config" "$out/bin"
            # Only the system and its sources ship: t/, docs/, docker/, flake.nix
            # and the rest are not runtime inputs, and the store copy is world
            # readable.
            cp -r "$src/src" "$src/enchiridion.asd" "$out/lib/"
            chmod -R u+w "$out"
            export XDG_CACHE_HOME="$TMPDIR/build-cache"
            export XDG_CONFIG_HOME="$TMPDIR/build-config"
            export CL_SOURCE_REGISTRY="${registry}"
            # Identity translation: a fasl is looked for beside its source, so
            # this system's fasls land in the writable copy in $out/lib.
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

      flake-check = { pkgs, system }:
        pkgs.runCommand "enchiridion-flake-check" { } ''
          echo "enchiridion flake evaluates for ${system}"
          touch "$out"
        '';

      mkGate = { pkgs, run-tests }:
        let
          enchiridion = mkEnchiridion { inherit pkgs; };
          sbcl = mkSbcl pkgs;
          name = if run-tests then "enchiridion-test" else "enchiridion-check";
          registry = source-registry pkgs [ "${enchiridion}/lib" "${source}/t" ];
        in
        pkgs.runCommand name
          {
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
            # The test sources come from the read-only store, so their output
            # goes to the writable gate cache.
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

            mkdir -p "$out/bin"
            printf '#!/bin/sh\necho "%s passed.\\n"\n' "${name}" > "$out/bin/${name}"
            chmod 755 "$out/bin/${name}"
          '';
      perSystem = system:
        let
          pkgs = pkgsFor system;
          sbcl = mkSbcl pkgs;
          library-path = lib.makeLibraryPath [ pkgs.sqlite pkgs.openssl ];
          enchiridion = mkEnchiridion { inherit pkgs; };
          check = mkGate { inherit pkgs; run-tests = false; };
          test = mkGate { inherit pkgs; run-tests = true; };
          # mkShell propagates stdenv-darwin (1.3 GB) and pkgs.git pulls python3
          # (1.6 GB), so the default shell uses mkShellNoCC and gitMinimal; the C
          # toolchain and full git stay behind `nix develop .#full`.
          mkDevShell = { shell, git, extra ? [ ], banner ? "" }: shell {
            name = "enchiridion-dev";
            packages = [ sbcl pkgs.sqlite pkgs.nixfmt-rfc-style git ] ++ extra;
            SBCL_HOME = "${sbcl}/lib/sbcl";
            CL_SOURCE_REGISTRY = devRegistry pkgs;
            ASDF_OUTPUT_TRANSLATIONS = "(:output-translations (t nil) :ignore-inherited-configuration)";
            LD_LIBRARY_PATH = library-path;
            DYLD_LIBRARY_PATH = library-path;
            shellHook = ''
              # The live checkout precedes the store on the registry, so the REPL
              # loads the tree the operator is editing.
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
