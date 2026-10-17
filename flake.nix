{
  description = "enchiridion, an autonomous agent harness written in Common Lisp";

  # Pinned to one immutable commit, not a branch tip. flake.lock records the
  # rev and narHash, so the build is reproducible and only an explicit flake
  # update moves it.
  #
  # This is nixpkgs-unstable at 2026-10-16, chosen because it carries the two
  # versions section 8 of the plan names: SBCL 2.6.8 and SQLite 3.53.3. The
  # previous 25.05 pin carried SBCL 2.5.4, which cannot start on macOS 27: it
  # aborts with "failed to allocate 1048576 bytes at 0x300100000" before it
  # compiles anything. The fix is in SBCL 2.6.5 and later. NixOS 26.11 is not
  # released yet, so no release channel can supply it.
  inputs.nixpkgs.url =
    "github:NixOS/nixpkgs/f20cd90e28fe0403873f473b29e42662cd86e8c4";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      pkgsFor = system: import nixpkgs { inherit system; };

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
        "dexador"
        "cl-jschema"
        "com_dot_inuoe_dot_jzon"
        "clack"
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
      sbclWith = pkgs: pkgs.sbcl.withPackages (ps: map (fn: ps.${fn}) lispPackageNames);

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
          package-set = pkgs.sbcl.pkgs;
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
      rawSbcl = pkgs: pkgs.sbcl;

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

          # The fasls live under XDG_CACHE_HOME and not under
          # ASDF_OUTPUT_TRANSLATIONS. ASDF merges the environment, the user
          # config and the system config for that variable, and the value that
          # reaches it from the nixpkgs wrapper is not parseable, so this build
          # owns the cache directory outright instead.
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
            export SBCL_HOME="${sbcl}/lib/sbcl"
            export LD_LIBRARY_PATH="${library-path}"

            ${sbcl}/bin/sbcl \
              --non-interactive \
              --no-userinit --no-sysinit \
              --eval '(require :asdf)' \
              --eval '(handler-case (progn
                        (asdf:load-system "enchiridion")
                        ;; The entry script is not a system component, so it
                        ;; has to be compiled here as well. Without this a
                        ;; broken main.cl ships inside a derivation that built
                        ;; cleanly and only fails when it is run.
                        (let ((root (uiop:pathname-directory-pathname
                                      *default-pathname-defaults*)))
                          (compile-file (merge-pathnames "src/main.cl" root)
                                        :output-file
                                        (merge-pathnames "main.fasl" #p"."))
                          (compile-file (merge-pathnames "src/broker-exec.cl" root)
                                        :output-file
                                        (merge-pathnames "broker-exec.fasl" #p"."))))
                      (error (condition)
                        (format *error-output* "~&~A~%" condition)
                        (sb-ext:exit :code 1)))'

            # Move the compiled output into the store, layout and all. ASDF
            # keys its cache on the source path, and the source path at run
            # time is this same store path, so the entries match.
            cp -a "$XDG_CACHE_HOME/." "$out/cache/"

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            makeWrapper ${sbcl}/bin/sbcl "$out/bin/enchiridion" \
              --prefix SBCL_HOME : "${sbcl}/lib/sbcl" \
              --prefix CL_SOURCE_REGISTRY : "${registry}" \
              --prefix LD_LIBRARY_PATH : "${library-path}" \
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

      # The container image. Docker is the isolation boundary and Nix performs
      # every install inside it, so the result is a self contained closure with
      # no SBCL, no Quicklisp, and nothing from the host on the host side.
      # Linux only: an image needs a Linux builder, and a darwin host reaches
      # one through Colima rather than by accident.
      mkImage = { system }:
        let pkgs = pkgsFor system;
        in
        pkgs.dockerTools.buildImage {
          name = "enchiridion";
          tag = "0.1.0";
          copyToRoot = true;
          config = {
            User = "0:0";
            Env = [
              "PATH=/usr/local/bin:/usr/bin:/bin"
              "ENCHIRIDION_HOME=/var/lib/enchiridion"
            ];
            ExposedPorts = [ "8787" ];
            Volumes = [ "/var/lib/enchiridion" ];
            WorkingDir = "/var/lib/enchiridion";
          };
          runAsRoot = ''
            mkdir -p /run/secrets /var/lib/enchiridion
            chmod 700 /run/secrets
            groupadd --gid 1000 agent
            useradd --uid 1000 --gid 1000 --home-dir /home/agent --shell /bin/sh agent
          '';
          extraInputs = [
            (mkEnchiridion { inherit pkgs; })
            ./docker/entrypoint.sh
          ];
        };

      # The flake evaluates for every supported system. Cheap, and it catches a
      # broken attribute path long before a container build fails on it.
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

            run_sbcl() {
              ${sbcl}/bin/sbcl --non-interactive --no-userinit --no-sysinit \
                --eval '(require :asdf)' \
                --eval "(handler-case (progn $1) (error (condition) (format *error-output* \"~&~A~%\" condition) (sb-ext:exit :code 1)))"
            }

            echo "compiling the entry scripts, which are not system components"
            run_sbcl "(asdf:load-system \"enchiridion\")
                       (let* ((root (pathname (format nil \"~A/\" (uiop:getenv \"SOURCE_DIR\"))))
                              (out (pathname (uiop:getenv \"GATE_DIR\"))))
                         (compile-file (merge-pathnames \"src/main.cl\" root)
                                       :output-file (merge-pathnames \"main.fasl\" out))
                         (compile-file (merge-pathnames \"src/broker-exec.cl\" root)
                                       :output-file (merge-pathnames \"broker-exec.fasl\" out)))"

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
        // lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux) {
          container = mkImage { inherit system; };
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