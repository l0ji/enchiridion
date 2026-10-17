;;;; packages.cl --- One package per subsystem.
;;;;
;;;; A symbol carries the name of its thing, never the name of its package, so
;;;; it is enchiridion.llm:complete and not enchiridion:llm-complete. Every
;;;; import is explicit. Nothing outside this file uses another package
;;;; wholesale, because a wholesale use is how two files quietly disagree about
;;;; what list-length means.

(defpackage #:enchiridion
  (:nicknames #:core)
  (:use #:cl)
  (:import-from
   #:alexandria
   #:assoc-value
   #:curry
   #:ensure-list
   #:hash-table-keys
   #:last-elt
   #:parse-body
   #:symbolicate
   #:when-let)
  (:export
   ;; Configuration.
   #:*config* #:*config-source* #:default-config #:read-config #:config
   #:config-set #:channel-config #:channel-enabled-p #:model-for
   #:agent-directory #:run-directory #:load-config #:config-digest
   #:sectioned-config-p #:config-section #:config-value)
  (:documentation
   "Configuration. Paths and behaviour only; a secret never comes from here,
because a file in the repository is a file that ends up in a store path."))

(defpackage #:enchiridion.compat
  (:use #:cl)
  (:export
   #:+implementation+
   #:environment #:environment-value #:environment-bound-p
   #:run-program #:run-program-blocking #:process-uid #:set-process-uid
   #:process-user #:set-process-user #:implementation-dependency-p
   #:script-arguments #:exit-with #:backtrace-string
   #:encode-utf8 #:decode-utf8 #:run-program-capture #:temp-directory)
  (:documentation
   "The only file in the tree that contains implementation extensions.
Everything above it is standard Common Lisp, which is what makes the agent
able to rewrite itself without rewriting the porting layer."))

(defpackage #:enchiridion.errors
  (:use #:cl)
  (:export
   #:enchiridion-error #:configuration-error #:usage-error #:missing-command
   #:backend-error #:transport-error #:tool-error #:schema-error
   #:block-overflow #:block-frozen #:bootstrap-pending #:budget-exceeded
   #:duplicate-message #:not-found #:unauthorized #:condition-report-line
   ;; The note every condition carries. The report line stays one line so it can
   ;; go in a log; this is the part that says what to do about it.
   #:error-detail)
  (:documentation
   "The condition hierarchy. Conditions, not formatted strings: a caller can
recover from a block overflow by asking it for the shortfall, and it cannot
recover from a string."))

(defpackage #:enchiridion.llm
  (:use #:cl)
  (:export
   ;; The protocol every backend implements. Three generic functions and the
   ;; check that stands in for satisfies, because SBCL 2.5.4 has no
   ;; defprotocol.
   #:complete #:model-capabilities #:backend-name #:backendp
   ;; The result and message shapes.
   #:message #:user-message #:assistant-message #:system-message
   #:tool-message #:message-role #:message-content #:message-tool-call-id
   #:message-tool-calls
   #:tool-call #:tool-call-id #:tool-call-name #:tool-call-arguments
   #:completion #:completion-text #:completion-tool-calls
   #:completion-model #:completion-stop-reason
   #:completion-input-tokens #:completion-output-tokens
   #:completion-cache-read-tokens #:completion-cache-write-tokens
   #:completion-total-tokens
   ;; Backends.
   #:openai-backend #:resolve-backend
   ;; The two halves of the OpenAI wire format, exported so they can be tested
   ;; without a network. They are pure functions over text and data, which is
   ;; the only reason the format is testable at all. PARSE-JSON goes with them
   ;; because it is the JSON door: one place decides what a parsed object is.
   #:completion-request #:parse-completion #:parse-json #:stringify
   ;; Tiers. The models are primary-model, cheap-model and sleep-model rather
   ;; than the bare words, because a function named SLEEP in a package that
   ;; uses CL is a package lock error.
   #:*model-primary* #:*model-cheap* #:*model-sleep*
   #:tier #:model-for-tier #:primary-model #:cheap-model #:sleep-model
   ;; Provider selection and the variable that holds the key for the active
   ;; provider. Main uses the second one before it builds the backend.
   #:detect-provider #:default-api-key-env)
  (:documentation
   "LLM backends, the request and result shapes they share, and the three
model tiers. The kernel never branches on which backend is in use."))

(defpackage #:enchiridion.llm.secrets
  (:use #:cl)
  (:import-from
   #:ppcre
   #:create-scanner
   #:quote-meta-chars
   #:regex-replace-all)
  (:export
   #:*minimum-secret-length*
   #:*loaded-secrets*
   #:*loaded-sources*
   #:*sealed*
   #:+redaction-marker+
   #:load-secrets #:load-secrets-from #:register-secret #:clear-secrets
   #:secret-names #:secret-value #:secret-source #:secret-present-p
   #:scrub #:scrub-object #:scrub-tree #:sealed-p #:seal #:unseal
   #:scrubber #:pattern #:secrets-file #:role-name-p #:parse-env-line)
  (:documentation
   "Loads .env into memory and scrubs every loaded value and every known shape
out of text on its way to a model, a transcript, or Fluxer. This is the
defence against a secret that reached a block through some path the operator
did not think of."))

(defpackage #:enchiridion.memory
  (:use #:cl)
  (:shadow #:block)
  (:import-from #:alexandria #:ensure-list)
  (:export
   ;; Seed files and the first launch.
   #:init-agent #:init-result #:init-created #:init-existing
   #:init-status-line #:agent-seeded-p #:seed-file-names #:write-if-absent
   #:init-result-directory #:init-result-existed-p #:init-problems
   #:seed-subdirectories
   ;; Templates, exported so that a test can assert on them without a disk.
   #:seed-templates #:*seed-templates* #:seed-template #:seed-description
   #:seed-kind
   ;; Blocks. Written in milestone 2.
   #:block #:make-block #:block-label #:block-text #:block-limit
   #:block-file #:block-writable-p #:block-bytes #:block-full-p #:block-slack
   #:default-block-limit #:scan-block-text
   #:set-block-text #:compile-blocks #:block-summary #:block-descriptions
   #:*default-block-limits*
   ;; The bootstrap state machine. Milestone 7.
   #:bootstrap-status #:bootstrap-complete-p #:bootstrap-remaining
   #:bootstrap-refuse-writes-p #:mark-bootstrap-step
   ;; Tiers. Milestone 4.
   #:tiered #:tiered-l0 #:tiered-l1 #:tiered-l2 #:build-tiers #:promote-tier
   #:tier-for #:tier-name #:tier-misses #:note-tier-miss #:reset-tier-misses)
  (:documentation
   "Memory blocks, the operator seed files that back the first three of them,
the three loading tiers, and the bootstrap state machine."))

(defpackage #:enchiridion.memory.store
  (:use #:cl)
  (:export
   #:open-store #:close-store #:store-path
   #:record-turn #:turn-row #:session-count #:recent-sessions #:delete-session
   #:search-sessions #:search-memories #:save-memory #:list-memories
   #:session-block #:set-session-block #:ledger-block #:set-ledger-block
   #:record-usage #:usage-rows #:usage-since #:drop-store)
  (:documentation
   "SQLite with FTS5 over raw messages. Returns real text: no summarisation and
no model call, so a search costs nothing."))

(defpackage #:enchiridion.tools
  (:use #:cl)
  (:export
   ;; Registry.
   #:tool #:make-tool #:tool-name #:tool-description #:tool-schema
   #:tool-handler #:tool-self-test #:tool-generation #:tool-broker-side-p
   #:registry #:register-tool #:define-tool #:find-tool #:tool-names #:list-tools
   #:unregister-tool #:clear-registry #:registry-schema
   #:registry-tool-definitions #:dispatch
   ;; Schema.
   #:*schema-budget* #:schema-tokens #:schema-budget-report #:validate-arguments
   #:schema-to-json #:schema-json-string #:schema-error-message)
  (:documentation
   "Tool registration, the single schema that drives the model facing JSON and
the argument validation, and dispatch."))

(defpackage #:enchiridion.tools.pipe
  (:use #:cl)
  (:export #:pipe-eval #:pipe-safe-eval #:read-filter #:filter-form #:make-sandbox)
  (:documentation
   "The Lisp filter sandbox. In Lisp the filter is an ordinary expression, so
this costs no interpreter of its own."))

(defpackage #:enchiridion.tools.broker
  (:use #:cl)
  (:export
   #:broker #:broker-start #:broker-stop #:broker-call #:broker-running-p
   #:make-broker #:broker-health #:serve-broker)
  (:documentation
   "Supervisor side of the privilege boundary. Agent authored code runs in the
child; the supervisor never loads it."))

(defpackage #:enchiridion.tools.builtin
  (:use #:cl)
  (:export
   #:register-builtin-tools #:file-index #:file-index-forms #:shell-run
   #:search-run #:block-ops #:meta-run #:web-fetch #:cap-result #:spill-path)
  (:documentation
   "The built-in tools. Index before read, cap every result, and spill the
middle of anything oversized to a file the agent can go and read."))

(defpackage #:enchiridion.plugin
  (:use #:cl)
  (:export
   #:define-plugin #:plugin #:plugin-name #:plugin-tool #:plugin-handler
   #:plugin-self-test #:plugin-generation #:load-generation #:reload
   #:current-generation #:generation-history #:package-name-for-generation
   #:verify-directory #:verify-result #:verify-ok-p #:verify-report
   #:discard-generation)
  (:documentation
   "Hot reloadable agent code. Each generation loads into a fresh package, so
a rename leaves no stale symbol behind and a bad edit costs one turn rather
than the process."))

(defpackage #:enchiridion.channel
  (:use #:cl)
  (:export
   #:channel #:channel-start #:channel-stop #:channel-send #:channel-status
   #:msg #:make-msg #:msg-id #:msg-channel #:msg-target #:msg-thread #:msg-author
   #:msg-text #:msg-ts #:msg-reply-to #:normalize #:deliver #:message-digest)
  (:documentation
   "The channel protocol and the one message shape every channel normalizes
into. The agent loop never learns which channel a turn arrived on."))

(defpackage #:enchiridion.channel.cli
  (:use #:cl)
  (:export #:start-cli #:run-repl #:run-command #:command-table #:command-names
           #:command-help #:repl-only-commands)
  (:documentation
   "The REPL and the shared command table that also backs the shell
interface, so the two surfaces cannot drift."))

(defpackage #:enchiridion.channel.http
  (:use #:cl)
  (:export #:start-http #:stop-http #:http-running-p)
  (:documentation
   "The webhook. Loopback by default; a non loopback bind without a token is
refused at startup rather than at first request."))

(defpackage #:enchiridion.channel.fluxer
  (:use #:cl)
  (:export #:start-fluxer #:stop-fluxer #:fluxer-running-p #:allowed-p)
  (:documentation
   "Direct messages only. Group channels, guild events, mentions, and
reactions are all out, so the allowlist is the whole authorisation story."))

(defpackage #:enchiridion.kernel
  (:use #:cl)
  (:export
   #:agent #:make-agent #:agent-name #:agent-turn #:run-turn #:agent-snapshot
   #:compile-prompt #:prompt #:prompt-text #:prompt-tokens #:snapshot-p
   #:record-spend #:spend #:reset-spend #:budget-exhausted-p #:spend-row
   #:session #:make-session #:session-id #:session-turns #:end-session
   #:heartbeat #:task-queue #:enqueue-task #:dequeue-task #:task-queue-length
   #:sleep-agent #:run-sleep-pass)
  (:documentation
   "The agent loop, the prompt compiler, the frozen snapshot, and the ledger.
This is the frozen core: it holds the shape of the system and it does not
change shape at run time."))

(defpackage #:enchiridion.user
  (:use #:cl)
  (:export #:*enchiridion-config*)
  (:documentation
   "The package config.cl is read into. It exists so that the operator writes
a Lisp file and the project stays a Lisp project."))