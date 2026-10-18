{
  description = "enchiridion, an autonomous agent harness written in Common Lisp";

  # nixpkgs-unstable, tracked by branch. flake.lock records the commit, so a
  # build is reproducible until `nix flake update nixpkgs` moves it to the
  # current tip. Unstable is the branch because no release channel carries
  # SBCL 2.6: NixOS 25.05 has 2.5.4, and NixOS 26.11 is not released yet.
  #
  # nixpkgs carries SBCL 2.6.8 at this revision. The flake builds 2.6.9 from
  # source below, so the Nix build and the Docker image use one version.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      pkgsFor = system: import nixpkgs { inherit system; };

      # SBCL 2.6.9. nixpkgs carries 2.6.8, so the release is built from source
      # here and wrapped the way nixpkgs wraps its own SBCL. The nixpkgs SBCL
      # is the bootstrap compiler: the default bootstrap on aarch64-darwin is
      # ECL, and an ECL bootstrap takes hours where a host SBCL takes minutes.
      sbclVersion = "2.6.9";

      mkSbcl = pkgs:
        let
          base = pkgs.callPackage
            (nixpkgs.outPath + "/pkgs/development/compilers/sbcl")
            {
              # The 2.6.8 hash satisfies nixpkgs' version table. The override
              # below replaces both the version and the source.
              version = "2.6.8";
              bootstrapLisp =
                "${pkgs.sbcl}/bin/sbcl --disable-debugger --no-userinit --no-sysinit";
            };
        in
        pkgs.wrapLisp {
          pkg = base.overrideAttrs (_old: {
            version = sbclVersion;
            src = pkgs.fetchurl {
              url = "mirror://sourceforge/project/sbcl/sbcl/${sbclVersion}/sbcl-${sbclVersion}-source.tar.bz2";
              hash = "sha256-xv0dc1Vw60/zTK+WCZiMp37QvRK1XQmk/tB1vokNpRM=";
            };
          });
          faslExt = "fasl";
          flags = [
            "--dynamic-space-size"
            "3000"
          ];
        };

      # Nix must never read a secret. Nix hashes every file it is handed into a
      # store path, and /nix/store is world readable. One builtins.readFile ./.env
      # would turn the key into a permanent, public, content addressed string.
      # This filter is the only thing between .env and the binary cache, so it
      # is deny by default and no path reaches Nix unfiltered.
      #
      # The rules are about the path inside this checkout, so the relative path
      # is what they get. An earlier version took the head of the absolute path
      # instead: for /Users/penny/.../enchiridion/.env that is "", not ".env",
      # so every segment rule was dead and the file would have been copied into
      # the store like any other source file. Absolute paths do not intersect
      # the names below, which is why the bug was invisible until it was tested.
      source-root = toString ./.;

      relative-path = path:
        let
          text = toString path;
        in
        if text == source-root then ""
        else lib.removePrefix (source-root + "/") text;

      denied = path:
        let
          relative = relative-path path;
          segments = if relative == "" then [ ] else lib.splitString "/" relative;
          base = baseNameOf (toString path);
          first = if segments == [ ] then "" else lib.head segments;
          under-agents = first == "agents";
          agent-state =
            under-agents
            && (base == "state.json"
                || lib.hasPrefix "state.json." base
                || base == "memory.db"
                || lib.hasPrefix "memory.db-" base
                || lib.elem "private" segments);
        in
        lib.elem base [ ".DS_Store" ]
        # The operator config and the working plan sit at the root only.
        # Matching the basename anywhere also excluded src/enchiridion/config.cl,
        # which is a source module and not the operator's file.
        || relative == "config.cl"
        || relative == "PLAN.md"
        # .env and .env.* anywhere in the tree. The secret is beside the code,
        # and a nested copy is just as readable from the store.
        || base == ".env"
        || lib.hasPrefix ".env." base
        # A build output symlink is not source. result-* is the .gitignore form.
        || base == "result"
        || lib.hasPrefix "result-" base
        # Version-control and cache directories. Matched at any depth, not only
        # at the root, because a vendored checkout can carry its own .git.
        || builtins.any
             (segment: lib.elem segment [ ".git" ".direnv" ".asdf" ])
             segments
        # Runtime and test scratch at the root. Root only: these names are
        # directories here, not source directories that happen to share them.
        # The property tests write enchiridion-property* into their current
        # directory because the build sandbox has nowhere else to write.
        || lib.elem first [
          "run"
          "enchiridion-property"
          "enchiridion-property-agents"
        ]
        # Per-agent runtime state. The Markdown seed files and the example
        # skills and tools stay in the source; state.json, memory.db, and
        # private/ are the three that hold what the agent has learned.
        || agent-state;

      source = builtins.path {
        path = ./.;
        name = "enchiridion-source";
        filter = path: _type: !(denied path);
      };

      # Every dependency named in the plan. Nothing outside this list is
      # reachable from a build, which is what keeps the closure auditable.
      # Names rather than derivations, because the same list has to name the
      # packages in the set and the directories ASDF searches.
      lispPackageNames = [
        "cl-dbi"
        "dbd-sqlite3"
        "dexador"
        "cl-jschema"
        "com_dot_inuoe_dot_jzon"
        "hunchentoot"
        "websocket-driver-client"
        "chanl"
        "cl-ppcre"
        "cl-base64"
        "alexandria"
        "usocket"
        "bordeaux-threads"
        "trivial-backtrace"
        "rove"
        "cl-quickcheck"
      ];

      # withPackages hangs off pkgs.sbcl, not off pkgs.sbclPackages. The
      # package set is recursed into for the libraries; the wrapped
      # interpreter is the attribute that carries them. This is what the dev
      # shell and any REPL use.
      sbclWith = pkgs:
        (mkSbcl pkgs).withPackages (ps: map (fn: ps.${fn}) lispPackageNames);

      # Every library in the transitive closure, not just the direct ones.
      # rove pulls in dissect, dexador pulls in fifteen more, and a source
      # registry that names only the direct list finds a system whose own
      # dependency is missing and stops with a component error.
      #
      # followed by hand rather than taken from the wrapper: build-asdf-system
      # puts a package's own lispLibs in propagatedBuildInputs, but
      # lispWithPackages sets that attribute to exactly the list it was given,
      # so the wrapper carries only the direct list and not the closure.
      lispClosure = pkgs:
        let
          package-set = (mkSbcl pkgs).pkgs;
          direct = map (name: package-set.${name}) lispPackageNames;
          walk = seen: pending:
            let
              fresh = builtins.filter (p: !(builtins.elem p seen)) pending;
            in
            if fresh == [ ] then
              seen
            else
              walk (seen ++ fresh)
                   (builtins.concatMap
                      (p: p.propagatedBuildInputs or [ ]) fresh);
        in
        walk [ ] direct;

      # What a build actually runs is the raw interpreter, not the wrapper.
      # The wrapper exports an ASDF_OUTPUT_TRANSLATIONS whose trailing ::
      # makes ASDF read two inherit markers and refuse to start, and it
      # prepends to whatever is already set, so it cannot be corrected from
      # outside. The registry is built here instead, and the dev shell and the
      # REPL are the only things that go through the wrapper.
      rawSbcl = pkgs: mkSbcl pkgs;

      source-registry = pkgs: extra:
        lib.concatStringsSep ":"
          ((map (path: "${path}//") (lispClosure pkgs)) ++ extra);

      # Compiling the system is the check. Warnings are errors, so this
      # derivation is the gate rather than a separate one that can drift.
      mkEnchiridion = { pkgs }:
        let
          sbcl = rawSbcl pkgs;
          # openssl because dexador pulls in cl+ssl, and cl+ssl dlopens
          # libcrypto at load time rather than linking against it. An RPATH on
          # the SBCL binary is therefore not enough: without this on
          # LD_LIBRARY_PATH the system loads right up to the point where the
          # first HTTPS call is made and then dies inside CFFI.
          # sqlite because the memory store opens it, and it is the same
          # situation: loaded by name, not linked.
          library-path = lib.makeLibraryPath [ pkgs.sqlite pkgs.openssl ];

          # Load every dependency from the fasl beside its source. Nix built
          # each dependency with this SBCL, so the store already holds the
          # fasls, and this build compiles only this system's own files.
          registry = source-registry pkgs [ "$out/lib" "$out/lib/t" ];
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "enchiridion";
          version = "0.1.0";
          src = source;

          nativeBuildInputs = [
            sbcl
            pkgs.sqlite
            pkgs.makeWrapper
          ];
          buildInputs = [ pkgs.sqlite ];

          # There is no configure step and no Makefile, but there is a build
          # step: the compilation below is the build, and it is the check.
          # dontBuild would skip it.
          dontConfigure = true;

          # Compile once, here, into a scratch cache. Nothing runs as this
          # derivation's output until the compiler has had its say, so this
          # phase is the gate that nix run .#check runs.
          buildPhase = ''
            runHook preBuild

            mkdir -p "$out/lib" "$out/cache" "$out/config" "$out/bin"
            cp -r "$src/." "$out/lib/"
            chmod -R u+w "$out"

            export XDG_CACHE_HOME="$TMPDIR/build-cache"
            export XDG_CONFIG_HOME="$TMPDIR/build-config"
            export CL_SOURCE_REGISTRY="${registry}"
            # Identity translation: a fasl is looked for beside its source.
            # The dependencies' fasls are beside their sources in the store, so
            # ASDF loads them. The copy of this source tree in $out/lib is
            # writable during the build, so this system's fasls land there too.
            export ASDF_OUTPUT_TRANSLATIONS='(:output-translations (t nil) :ignore-inherited-configuration)'
            export SBCL_HOME="${sbcl}/lib/sbcl"
            export LD_LIBRARY_PATH="${library-path}"

            ${sbcl}/bin/sbcl \
              --non-interactive \
              --no-userinit --no-sysinit \
              --eval '(require :asdf)' \
              --eval '(handler-bind ((warning (lambda (condition)
                                                 (let ((report (princ-to-string condition)))
                                                   (when (or (search "redefining DEFTYPE type to be a class" report)
                                                             (search "bare references to struct types are deprecated" report))
                                                     (muffle-warning condition))))))
                         (handler-case (progn
                        (asdf:load-system "enchiridion")
                        ;; The entry script is not a system component, so it
                        ;; has to be compiled here as well. Without this a
                        ;; broken main.cl ships inside a derivation that built
                        ;; cleanly and only fails when it is run.
                        ;;
                        ;; COMPILE-FILE reports a read error by returning with
                        ;; FAILURE-P true, not by signalling. Ignoring that
                        ;; value is how a gate reports success on a file it
                        ;; never compiled, which is the one failure mode this
                        ;; phase exists to prevent.
                        (flet ((compile-entry (source output)
                                 (multiple-value-bind (fasl warnings-p failure-p)
                                     (compile-file source :output-file output)
                                   (declare (ignore fasl warnings-p))
                                   (when failure-p
                                     (error "compile-file reported a failure for ~A"
                                            source)))))
                          (let ((root (uiop:pathname-directory-pathname
                                        *default-pathname-defaults*)))
                            (compile-entry (merge-pathnames "src/main.cl" root)
                                           (merge-pathnames "main.fasl" #p"."))
                            (compile-entry (merge-pathnames "src/broker-exec.cl" root)
                                           (merge-pathnames "broker-exec.fasl" #p".")))))
                      (error (condition)
                        (format *error-output* "~&~A~%" condition)
                        (sb-ext:exit :code 1))))'

            # The cache stays empty: with the identity translation the fasls
            # are written beside the sources in $out/lib. The directory itself
            # stays because the wrapper points XDG_CACHE_HOME at it.

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

      # The flake evaluates for every supported system. Cheap, and it catches a
      # broken attribute path long before a build fails on it.
      flake-check = { pkgs, system }:
        pkgs.runCommand "enchiridion-flake-check" { } ''
          echo "enchiridion flake evaluates for ${system}"
          touch "$out"
        '';

      # The gate. Compiles the entry script as well as the system, which the
      # system cannot do because loading a system must never start an agent.
      # The tests run in a scratch cache rather than in the store, because
      # they are recompiled from source under the test policy.
      mkGate =
        { pkgs, run-tests }:
        let
          enchiridion = mkEnchiridion { inherit pkgs; };
          sbcl = rawSbcl pkgs;
          name = if run-tests then "enchiridion-test" else "enchiridion-check";
          registry = source-registry pkgs [
            "${enchiridion}/lib"
            "${enchiridion}/lib/t"
          ];
        in
        pkgs.runCommand name
          {
            # bash and coreutils are here for the tests, not for the build.
            # The sandbox exposes only the declared inputs, so without them
            # /bin/sh and id do not exist and the suite cannot tell a broken
            # run-program from a missing program.
            nativeBuildInputs = [
              sbcl
              pkgs.sqlite
              pkgs.bash
              pkgs.coreutils
              # The git tests run inside the sandbox with no global git
              # configuration, so git has to be an input here.
              pkgs.git
            ];
            LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.sqlite pkgs.openssl ];
            SBCL_HOME = "${sbcl}/lib/sbcl";
            REGISTRY = registry;
            SOURCE_DIR = "${enchiridion}/lib";
          }
          ''
            mkdir -p gate-cache gate-config

            export XDG_CACHE_HOME="$PWD/gate-cache"
            export XDG_CONFIG_HOME="$PWD/gate-config"
            export GATE_DIR="$PWD/gate-cache"
            export CL_SOURCE_REGISTRY="$REGISTRY"
            # Dependencies and the built system load from the fasl beside their
            # source in the store. The test sources are not compiled by the
            # package build, and the store is read-only, so their output goes to
            # the writable gate cache. They are the only sources this gate
            # compiles, apart from the entry scripts below.
            export ASDF_OUTPUT_TRANSLATIONS="(:output-translations ((\"$SOURCE_DIR/t/\" :**/ :*.*.*) \"$GATE_DIR/t/\") (t nil) :ignore-inherited-configuration)"

            run_sbcl() {
              ${sbcl}/bin/sbcl --non-interactive --no-userinit --no-sysinit \
                --eval '(require :asdf)' \
                --eval "(handler-bind ((warning (lambda (condition) (let ((report (princ-to-string condition))) (when (or (search \"redefining DEFTYPE type to be a class\" report) (search \"bare references to struct types are deprecated\" report)) (muffle-warning condition)))))) (handler-case (progn $1) (error (condition) (format *error-output* \"~&~A~%\" condition) (sb-ext:exit :code 1))))"
            }

            echo "compiling the entry scripts, which are not system components"
            run_sbcl "(asdf:load-system \"enchiridion\")
                       ;; COMPILE-FILE returns with FAILURE-P true on a read
                       ;; error instead of signalling, so the value has to be
                       ;; checked here or this gate reports success on a file
                       ;; it never compiled.
                       (flet ((compile-entry (source output)
                                (multiple-value-bind (fasl warnings-p failure-p)
                                    (compile-file source :output-file output)
                                  (declare (ignore fasl warnings-p))
                                  (when failure-p
                                    (error \"compile-file reported a failure for ~A\"
                                           source)))))
                         (let* ((root (pathname (format nil \"~A/\" (uiop:getenv \"SOURCE_DIR\"))))
                                (out (pathname (uiop:getenv \"GATE_DIR\"))))
                           (compile-entry (merge-pathnames \"src/main.cl\" root)
                                          (merge-pathnames \"main.fasl\" out))
                           (compile-entry (merge-pathnames \"src/broker-exec.cl\" root)
                                          (merge-pathnames \"broker-exec.fasl\" out))))"

            ${if run-tests then ''
              echo "running the suite"
              run_sbcl '(asdf:test-system "enchiridion-tests")'
              run_sbcl '(asdf:test-system "enchiridion-tests/property")'
            '' else ''
              echo "no tests requested"
            ''}

            # The build is the check. This binary exists so that nix run finds
            # something to execute, and it never runs when the gate failed,
            # because nix stops before the install phase.
            mkdir -p "$out/bin"
            printf '#!/bin/sh\necho "%s passed.\\n"\n' "${name}" > "$out/bin/${name}"
            chmod 755 "$out/bin/${name}"
          '';

      mkCheck = { pkgs }: mkGate {
        inherit pkgs;
        run-tests = false;
      };

      mkTest = { pkgs }: mkGate {
        inherit pkgs;
        run-tests = true;
      };
    in
    {
      devShells = lib.genAttrs systems (
        system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            name = "enchiridion-dev";
            packages = [
              (sbclWith pkgs)
              pkgs.sqlite
              pkgs.colima
              pkgs.sly
              pkgs.clang-tools
              pkgs.nixfmt-rfc-style
              pkgs.git
            ];
            shellHook = ''
              echo "enchiridion dev shell. Every dependency is in ASDF; there is no Quicklisp."
              echo "  nix run .#check              compile every file, warnings fail"
              echo "  nix run .#test               run the suite"
              echo "  nix run .#enchiridion        first launch"
              echo "  sly                         start a REPL"
            '';
          };
        }
      );

      packages = lib.genAttrs systems (
        system:
        let pkgs = pkgsFor system;
        in {
          enchiridion = mkEnchiridion { inherit pkgs; };
          enchiridion-aarch64-linux = mkEnchiridion { pkgs = pkgsFor "aarch64-linux"; };
          enchiridion-x86_64-linux = mkEnchiridion { pkgs = pkgsFor "x86_64-linux"; };
        }
      );

      apps = lib.genAttrs systems (
        system:
        let pkgs = pkgsFor system;
        in {
          default = {
            type = "app";
            program = "${mkEnchiridion { inherit pkgs; }}/bin/enchiridion";
          };
          check = {
            type = "app";
            program = "${mkCheck { inherit pkgs; }}/bin/enchiridion-check";
          };
          test = {
            type = "app";
            program = "${mkTest { inherit pkgs; }}/bin/enchiridion-test";
          };
        }
      );

      checks = lib.genAttrs systems (
        system:
        let pkgs = pkgsFor system;
        in {
          flake = flake-check {
            inherit pkgs system;
          };
          enchiridion = mkEnchiridion { inherit pkgs; };
          check = mkCheck { inherit pkgs; };
          default = mkTest { inherit pkgs; };
        }
      );

      formatter =
        lib.genAttrs systems (system: (pkgsFor system).nixfmt-rfc-style);
    };
}