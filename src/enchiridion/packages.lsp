;;;; packages.lsp --- Subsystem package definitions.
;;;;
;;;; All cross-package imports are explicit; symbols do not repeat package names.

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
   #:config-set #:channel-config #:channel-value #:channel-enabled-p #:model-for
   #:agent-directory #:run-directory #:load-config #:config-digest
   #:control-path #:status-path #:project-root
   #:sectioned-config-p #:config-section #:config-value #:config-section-value
   #:config-with-llm-value
   #:config-setting #:config-tool-rounds
   ;; Active-then-default lookup used by the LLM provider table.
   #:config-lookup
   ;; Shared API key env-var list.
   #:config-api-key-env-list
   #:configured-secret-names #:config-memory-db)
  (:documentation "Operator configuration (paths and behavior only, no secrets)."))

(defpackage #:enchiridion.compat
  (:use #:cl)
  (:export
   #:+implementation+ #:single-float-bits #:bits-single-float
   #:environment #:environment-value #:environment-bound-p
   #:set-environment-variable #:unset-environment-variable
   #:run-program #:run-program-blocking
   #:process-uid #:set-process-uid #:process-gid #:set-process-gid
   #:clear-supplementary-groups
   #:process-user #:set-process-user #:implementation-dependency-p
   #:process-id #:process-pid #:process-kill #:process-reap #:with-deadline
   ;; Process trees, for stopping a child's own children: each leads a group.
   #:signal-process #:process-alive-p #:process-descendants
   #:process-exit-code #:lisp-runtime-path
   #:script-arguments #:exit-with #:backtrace-string
   #:encode-utf8 #:decode-utf8 #:decode-utf8-lenient #:run-program-capture
   #:temp-directory
   #:set-file-mode #:file-mode #:symlink-target
   #:with-interrupt-handler #:signal-interactive-interrupt
   #:install-shutdown-signals #:shutdown-interrupt-p #:signal-shutdown-interrupt)
  (:documentation "Implementation-specific portability layer; everything above is standard CL."))

(defpackage #:enchiridion.git
  (:use #:cl)
  (:export
   #:git-available-p #:git-program #:repository-p #:git-init #:git-commit-all
   #:git-log #:git-show #:git-diff #:git-revert #:git-head
   #:git-run #:git-current-branch #:git-test-environment #:*commit-environment*
    #:*git-identity* #:*history-failure-reporter* #:*stale-lock-reporter*)
  (:documentation
   "Git wrapper for the agent directory via ENCHIRIDION.COMPAT.
Root processes run Git via src/git-exec.lsp as the configured agent uid/gid."))

(defpackage #:enchiridion.errors
  (:use #:cl)
  (:export
   #:enchiridion-error #:configuration-error #:usage-error #:missing-command
   #:backend-error #:transport-error #:tool-error #:schema-error
   #:block-overflow #:block-frozen #:bootstrap-pending #:budget-exceeded
   #:duplicate-message #:not-found #:unauthorized #:condition-report-line
   #:turn-cancelled #:turn-busy #:busy-agent
   ;; Human-readable detail attached to conditions.
   #:error-detail)
  (:documentation "Structured condition hierarchy for recoverable error handling."))

(defpackage #:enchiridion.llm
  (:use #:cl)
  (:export
   ;; Backend protocol.
   #:complete #:embed #:model-capabilities #:backend-name #:backendp
   ;; The result and message shapes.
   #:message #:user-message #:assistant-message #:system-message
   #:tool-message #:message-role #:message-content #:message-tool-call-id
   #:message-tool-calls
   #:tool-call #:tool-call-id #:tool-call-name #:tool-call-arguments
   #:completion #:completion-text #:completion-tool-calls
   #:completion-model #:completion-stop-reason #:completion-reasoning-text
   #:completion-input-tokens #:completion-output-tokens
   #:completion-cache-read-tokens #:completion-cache-write-tokens
   #:completion-total-tokens #:copy-completion
   #:take-completion-tool-message
   ;; API handler registry and provider/model records.
   #:api-handler #:find-api-handler #:register-api-handler
   #:registered-api-handlers #:provider-supported-p
   #:provider #:provider-id #:provider-name #:provider-api #:provider-profile
   #:provider-base-url #:provider-key #:provider-env #:provider-model
   #:provider-default-model #:provider-cached-models #:provider-headers
   #:provider-query-params #:provider-options #:provider-doc #:provider-source
   #:provider-option
   #:model-info #:model-info-id #:model-info-name #:model-info-tool-call-p
   #:model-info-reasoning-p #:model-info-context #:model-info-output
   #:model-info-cost-input #:model-info-cost-output
   #:model-info-cost-cache-read #:model-info-cost-cache-write
   ;; Declarative wire dialects.
   #:dialect #:dialect-field #:dialect-profile #:dialect-profile-p
   #:make-dialect-for
   ;; Auth: the simple schemes are here, the signed ones register themselves.
   #:auth-apply #:auth-headers #:auth-query-params
   #:register-auth-signer #:find-auth-signer
   ;; The transport, so a handler and a test can build a request.
   #:http-request #:make-http-request #:http-request-url #:http-request-body
   #:http-request-headers #:http-request-timeout
   #:http-post #:http-get #:post-with-retries #:merge-headers
   #:ensure-trailing-slash #:new-session-id #:provider-error-message
   ;; The runtime catalog and the provider table that consumes it.
   #:read-catalog-file #:refresh-catalog #:catalog-providers
   #:provider-models #:resolve-provider #:list-providers #:provider-from-base-url
   ;; Backends.
   #:openai-backend #:anthropic-backend #:resolve-backend
   ;; Pure OpenAI wire serialization/parsing and JSON helpers.
   #:completion-request #:parse-completion #:parse-json #:stringify
   ;; Pure Anthropic wire serialization/parsing.
   #:anthropic-completion-request #:anthropic-parse-completion
   ;; Model tiers (prefixed to avoid shadowing CL:SLEEP).
   #:*model-primary* #:*model-cheap* #:*model-sleep*
   #:tier #:model-for-tier #:primary-model #:cheap-model #:sleep-model
   ;; Provider detection and key env-var discovery.
   #:detect-provider #:default-api-key-env #:provider-key-names)
  (:documentation "LLM backends, shared message/completion types, and model tiers."))

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
   ;; Container secrets path, loading, mode checks, and scrubbing.
   #:+container-secrets-path+
   #:load-secrets #:load-secrets-from #:register-secret #:clear-secrets
   #:secret-names #:secret-value #:secret-source #:secret-present-p
   #:secret-file-mode-ok-p #:discard-secrets-file
   #:scrub #:scrub-object #:scrub-tree #:sealed-p #:seal #:unseal
   #:scrubber #:pattern #:secrets-file #:role-name-p #:credential-variable-p
   ;; Shared .env path resolution for loader and `secrets` command.
   #:operator-secrets-file
   ;; Recorded path/mode from load time (persists after container file unlink).
   #:secrets-file-read #:secrets-file-mode-read
   #:parse-env-line)
  (:documentation
   "Loads .env secrets into memory and scrubs loaded values and credential shapes
before text reaches models, transcripts, or channels."))

(defpackage #:enchiridion.memory
  (:use #:cl)
  (:shadow #:block)
  (:import-from #:alexandria #:ensure-list)
  (:export
   ;; Seed files and the first launch.
   #:init-agent #:init-result #:init-created #:init-existing
   #:init-status-line #:agent-seeded-p #:seed-file-names #:write-if-absent
   #:ensure-agent-repository
   #:init-result-directory #:init-result-existed-p #:init-problems
   #:seed-subdirectories
   ;; Templates, exported so that a test can assert on them without a disk.
   #:seed-templates #:*seed-templates* #:seed-template #:seed-description
   #:seed-kind
   ;; Runtime state (state.json: generation counter and bootstrap progress).
   #:state-file #:default-state #:read-state #:write-state
   #:state-generation #:set-state-generation
   #:bootstrap-steps #:bootstrap-handover #:reset-bootstrap
   #:bootstrap-status-line
   ;; Blocks.
   #:block #:make-block #:block-label #:block-text #:block-limit
   #:block-file #:block-writable-p #:block-bytes #:block-full-p #:block-slack
   #:default-block-limit #:canonical-block-label #:scan-block-text
   #:set-block-text #:write-block-file #:compile-blocks #:block-summary
   #:block-descriptions
   #:*block-limits* #:*unlisted-block-limit*
   ;; The bootstrap state machine.
   #:bootstrap-status #:bootstrap-complete-p #:bootstrap-remaining
   #:bootstrap-refuse-writes-p #:mark-bootstrap-step #:mark-bootstrap-steps
    #:upgrade-stock-bootstrap
   ;; Tiers.
   #:tiered #:tiered-l0 #:tiered-l1 #:tiered-l2 #:build-tiers #:promote-tier
   #:tier-for #:tier-name #:tier-misses #:note-tier-miss #:reset-tier-misses
   ;; Episodic log, retrieval, generations, gates, and status.
   ;; Schema and parameters.
   #:+episodic-schema+ #:+ext-schema+ #:*episodic-tables*
   #:*ext-tables* #:*episodic-views* #:ensure-episodic-schema
   #:ensure-ext-schema #:table-names
   #:*memory-parameters* #:parameter #:configure-memory
   #:enabled-p #:retrieval-enabled-p #:push-enabled-p #:record-sleep-p
   ;; Records.
   #:episode #:make-episode
   #:episode-id #:episode-session #:episode-role #:episode-body #:episode-ts
   #:episode-event-ts #:episode-channel #:episode-provenance #:episode-origin
   #:episode-authority #:episode-cue-type #:episode-depth #:episode-span
   #:episode-rarity-raw #:episode-arousal-raw #:episode-context-key
   #:episode-scene-trace #:episode-horizon #:episode-run-id
   #:assertion #:make-assertion
   #:assertion-id #:assertion-subject #:assertion-relation #:assertion-object
   #:assertion-polarity #:assertion-episode-id #:assertion-span-start
   #:assertion-span-end #:assertion-authority-basis #:assertion-valid-from
   #:assertion-valid-to #:assertion-tx-from #:assertion-tx-to
   #:assertion-authority #:assertion-provenance #:assertion-cue-type
   #:assertion-schema-id #:assertion-run-id
   #:link #:make-link #:link-src-kind #:link-src #:link-dst-kind #:link-dst
   #:link-type #:link-weight #:link-obs #:link-updated-ts
   #:activation #:make-activation #:activation-kind #:activation-id
   #:activation-n-enc #:activation-last-enc #:activation-n-ret
   #:activation-last-ret #:activation-created-ts #:activation-supp
   #:activation-supp-ts #:activation-imp #:activation-distinctness
   #:conflict #:make-conflict #:conflict-id #:conflict-kind #:conflict-left-id
   #:conflict-right-id #:conflict-basis #:conflict-resolution-state
   #:conflict-resolution #:conflict-resolver #:conflict-acting-query
   #:intention #:make-intention #:intention-id #:intention-text
   #:intention-trigger-kind #:intention-trigger-expr #:intention-state
   #:intention-budget #:intention-cooldown #:intention-expiry
   ;; Score terms and the required implementations.
   #:terms #:make-terms #:terms-base #:terms-spread #:terms-temporal
   #:terms-importance #:terms-cue-type #:terms-context #:terms-inhibition
   #:terms-distinct #:terms-lexical #:retrieval-score #:retrieval-probability
   #:retrieval-latency #:rank-normalise #:normalise-terms
   #:base-level #:base-level-exact #:base-level-approx #:base-level-forms
   #:associative-strength #:fan #:edge-weight #:decayed-edge-weight
   #:spread-activation #:retrieve #:decay-update #:decay-sweep
   #:inhibition-after-loss #:decay-inhibition
   ;; Supporting mechanisms.
   #:encoding-filter #:capture-p #:promotion-condition
   #:write-episode #:tokenise #:term-coverage #:jaccard #:context-match
   #:cue-type-match #:temporal-match #:conflict-kind-for #:detect-conflicts
   #:resolve-conflict #:update-conditions-hold-p #:admission-rule
   #:assertion-from-row
   #:judgement-of-learning #:isotonic-fit #:isotonic-predict
   #:recalibrate #:search-externally-p #:record-outcome
   #:candidates-for #:assertion-candidates-for #:graph-for
   #:episode-from-row
   #:episode-candidate #:item-terms
   #:*assertion-deriver* #:*derivation-tokens*
   #:make-model-assertion-deriver #:parse-assertion-json
   #:assertions-from-model-text
   ;; Extension layer.
   #:index-cue #:cue-index-for #:cue-index-many #:cue-index-size
   #:prune-cue-index #:push-pack #:precondition-surfacing
   #:learned-state-block #:fire-intentions #:assemble-pack
   #:register-canary #:canary-check #:canary-report #:+canary-families+
   #:valid-canary-p #:canary-coverage #:sync-canaries #:canary-behaviour-p
   #:propose-canary #:canary-proposals #:approved-canaries
   #:approve-canary #:discard-canary #:revoke-canary
   #:canary-predicate #:utility-tasks #:answer-hit-p #:answer-scorer
   #:rare-episode-ids #:tail-tasks #:t2-preflight
   #:sign-test-p #:paired-outcomes #:tail-gate #:provenance-gate #:cost-gate
   #:promotion-tokens #:gate-candidate #:check-promoted
   #:promotion-precision #:quarantine-rate #:precision-frozen-p #:quarantine-frozen-p
   #:promotion-freeze #:reset-promotion-precision #:t2-interval
   #:*precision-min* #:*precision-window* #:*precision-min-checked* #:*quarantine-max*
   #:*quarantine-window* #:*quarantine-min-candidates* #:*t2-interval-seconds*
   #:*t2-frozen-interval-seconds* #:*t2-enabled-p* #:*t2-episode-threshold*
   #:*t2-max-tokens-per-pass* #:*t2-deriver-max-tokens* #:*t2-deriver-model* #:*t2-deriver-concurrency*
   #:last-t2-ts #:mark-t2-pass #:new-episode-count #:t2-due-p #:t2-pass-spend
   #:t2-refusal #:run-t2-pass
   #:*memory-gate-alpha* #:*memory-tail-margin* #:*t2-max-tokens-per-episode* #:promotion-episodes
   #:*gate-pack-chars* #:pack-position
   #:utility-gate #:volume-gate
   #:run-arm #:compare-arms #:push-ab #:record-gate-row #:content-hash
   #:*push-max-fraction* #:*memory-pack-chars* #:*memory-graph-limit*
   #:*memory-gate-margin* #:*memory-gate-min-n* #:*memory-writes-per-episode*
   #:apply-memory-settings #:*compaction-rebase-every* #:*compaction-rebase-turns*
   #:*memory-canaries* #:*canary-min-families* #:*tail-rarity-fraction*
   #:*tail-min-n* #:*utility-max-tasks*
   ;; Integration entry points.
   #:retrieve-for-turn #:retrieve-rows-for-turn #:record-retrieval
   #:record-retrieval-outcome #:maintenance
   #:build-candidate #:promote-generation #:rollback-generation #:requeue-generation #:generation-row
   #:start-candidate #:generation-status #:generation-assertion-count
   #:live-assertion-count #:current-generation #:ensure-generation-state
   #:rebuild-derived #:graph-terms-on-p #:resolve-conflict-at-action #:forget-session
   #:add-intention #:list-intentions #:cancel-intention
   #:propose-change #:memory-status #:import-log
   #:live-generation-id #:render-pack #:pack-rows #:select-pack-rows
   #:*memory-reranker* #:make-model-reranker #:rerank-rows #:parse-rerank-reply
   #:*memory-embedder* #:*memory-embed-model* #:make-backend-embedder
   #:embed-pending #:hybrid-candidates #:dense-ranking
   #:encode-vector #:decode-vector
   ;; The bounded recent-conversation window a prompt carries.
   #:conversation-window #:*recent-turn-count* #:*recent-window-chars*)
  (:documentation "Memory blocks, seed templates, tiers, bootstrap state, and episodic log/retrieval."))

(defpackage #:enchiridion.memory.store
  (:use #:cl)
  (:export
   ;; Store path resolution and lifecycle.
   #:*store-path* #:default-store-path #:store-file-p
   #:open-store #:close-store #:store-path
   #:record-turn #:turn-row #:session-count #:recent-sessions #:delete-session
   ;; Turn row accessors.
   #:turn-row-id #:turn-row-session #:turn-row-role #:turn-row-body
   #:turn-row-model #:turn-row-channel #:turn-row-ts
   #:search-sessions #:search-memories #:save-memory #:list-memories
   #:session-block #:set-session-block #:ledger-block #:set-ledger-block
   #:record-usage #:usage-rows #:usage-since #:drop-store
   ;; Usage ledger aggregation.
   #:usage-summary #:usage-total-since #:usage-session-total #:recent-turns
   ;; The task queue. The CLI writes it and the sleep agent drains it.
   #:enqueue-task #:dequeue-task #:complete-task #:fail-task #:recover-tasks
   #:count-tasks #:list-tasks #:remove-task
   #:task-row #:task-row-id #:task-row-body #:task-row-status #:task-row-ts
   ;; SQLite primitives for derived memory modules.
   #:exec #:query-rows #:field #:last-row-id #:scrubbed #:fts-query
   #:with-store-lock #:with-store-transaction #:store-connection)
  (:documentation "SQLite + FTS5 persistence for turns, memories, usage, and tasks."))

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
  (:documentation "Tool registry, JSON schema generation/validation, and dispatch."))

(defpackage #:enchiridion.tools.pipe
  (:use #:cl)
  (:export #:pipe-eval #:pipe-safe-eval #:read-filter #:filter-form #:make-sandbox)
  (:documentation "Sandboxed Lisp filter expression evaluator."))

(defpackage #:enchiridion.tools.broker
  (:use #:cl)
  (:export
   #:broker #:broker-start #:broker-stop #:broker-call #:broker-running-p
   #:make-broker #:broker-health #:serve-broker
   #:broker-verify-plugin #:broker-load-generation
   #:*load-generation-function* #:*start-progress-function*)
  (:documentation "Supervisor-side privilege boundary; agent code runs in the broker child."))

(defpackage #:enchiridion.tools.builtin
  (:use #:cl)
  (:export
   #:register-builtin-tools #:file-index #:file-index-forms #:shell-run
   #:search-run #:block-ops #:memory-run #:meta-run #:presence-run
   #:register-presence-tools #:web-fetch #:cap-result #:spill-path)
  (:documentation "Built-in tools with result capping and oversized-output spilling."))

(defpackage #:enchiridion.plugin
  (:use #:cl)
  (:export
   #:define-plugin #:plugin #:plugin-name #:plugin-tool #:plugin-handler
   #:plugin-self-test #:plugin-generation #:load-generation #:reload
   #:current-generation #:generation-history #:package-name-for-generation
   #:verify-directory #:verify-result #:verify-ok-p #:verify-report
   #:discard-generation
   ;; Loader and data-only manifest reader.
   #:*generation* #:plugin-registry #:agent-source-files #:load-agent-code
   #:load-generation #:generation-result #:generation-result-ok-p
   #:generation-result-report #:generation-result-generation
   #:plugin-manifests #:manifest-name #:manifest-description #:manifest-schema
   #:verify-file #:run-self-tests #:tool
   ;; Lisp and markdown reference skills under skills/.
   #:skill-files #:reference-skill-files #:read-reference-skill
   #:generation-result-reference-skills #:verify-result-reference-skills
    #:snapshot-sources #:source-snapshot #:source-snapshot-p
    #:source-snapshot-files #:source-snapshot-digest #:source-snapshot-directory
    #:source-changes #:source-mismatch #:source-digest-value
    #:generation-result-digests #:verify-result-digests)
  (:documentation "Hot-reloadable agent code with per-generation packages and verification."))

(defpackage #:enchiridion.channel
  (:use #:cl)
  (:export
   #:channel #:channel-start #:channel-stop #:channel-send #:channel-status
   #:define-channel #:channel-name #:channel-live-p #:channel-state
   #:channel-thread
   #:msg #:make-msg #:msg-id #:msg-channel #:msg-target #:msg-thread #:msg-author
   #:msg-text #:msg-ts #:msg-reply-to #:normalize #:deliver #:message-digest
   #:digest-text #:make-followup-selector)
  (:documentation "Channel protocol and normalized message type."))

(defpackage #:enchiridion.channel.cli
  (:use #:cl)
  (:export #:start-cli #:make-cli-channel
           #:run-repl #:run-command #:command-table #:command-names
           #:command-help #:repl-only-commands
           #:command-requirements #:command-problem #:*doctor-function*
           ;; Dynamic command context passed to one-argument handlers.
           #:*command-context* #:make-command-context
           #:command-context-directory #:command-context-config
           #:command-context-store #:command-context-agent
           #:command-context-session #:command-context-broker
           #:command-context-generation #:command-context-supervisor
           #:command-context-channel #:command-context-respond
           #:command-context-cancel #:repl-evaluate)
  (:documentation "REPL and shared CLI command table."))

(defpackage #:enchiridion.channel.http
  (:use #:cl)
  (:export #:start-http #:stop-http #:http-running-p #:make-http-channel
           #:http-channel #:http-channel-acceptor
           #:make-http-service #:make-http-request
           #:http-channel-service #:http-service-token #:http-service-bind
           #:http-service-port #:http-service-body-limit
           #:http-request-method #:http-request-path #:http-request-body
           #:http-request-authorization #:http-request-content-type
           #:handle-http-request #:dispatch-http-request #:usage-limit
           #:loopback-bind-p #:constant-time-string= #:authorized-p
           #:bearer-token #:json-content-type-p #:declared-length
           #:check-http-policy
           #:http-error #:http-error-status #:http-error-message
           #:+http-body-limit+ #:+http-usage-limit+ #:+http-max-usage-limit+)
  (:documentation "HTTP webhook channel; loopback by default, non-loopback requires a token."))

(defpackage #:enchiridion.channel.fluxer
  (:use #:cl)
  (:export #:start-fluxer #:stop-fluxer #:fluxer-running-p #:allowed-p
           #:make-fluxer-channel #:propose-custom-status #:custom-status)
  (:documentation "Fluxer DM channel; allowlist-gated direct messages only."))

(defpackage #:enchiridion.supervisor
  (:use #:cl)
  (:export
   #:supervisor #:make-supervisor #:supervisor-start #:supervisor-stop
   #:supervisor-directory #:supervisor-config #:supervisor-store
   #:supervisor-agent #:supervisor-session #:supervisor-broker
   #:supervisor-run-directory
   #:supervisor-generation #:supervisor-channels #:supervisor-running-p
    #:supervisor-enable-channel #:supervisor-channel-factory
   ;; Health and status reporting.
   #:supervisor-channel-rows #:supervisor-disabled-channels
   #:supervisor-heartbeat-live-p #:supervisor-write-report
   #:supervisor-heartbeat-p #:supervisor-heartbeat-interval
   #:supervisor-poll-control #:supervisor-poll-loop
   #:supervisor-write-status #:supervisor-started #:channel-row
   #:supervisor-tick #:supervisor-tick-function
   #:supervisor-heartbeat-due-p #:supervisor-heartbeat-loop
   #:supervisor-ticks #:supervisor-last-tick #:supervisor-tick-report
   #:supervisor-tick-ok-p #:supervisor-tick-requested-p #:supervisor-tick-running-p
   #:supervisor-last-compacted-turn #:supervisor-last-sleep-turn
   #:supervisor-reload #:find-channel
   ;; File-based control/status IPC under run/.
   #:control-file #:status-file #:read-status #:status-fresh-p #:request-control
   #:+control-wait-seconds+ #:queue-control
   #:status-generation #:status-channels #:status-bootstrap #:status-pid
   #:status-updated #:status-report #:status-handled #:status-report-ok-p
   #:status-writes #:status-heartbeat)
  (:documentation "Supervisor process owning channels, heartbeats, and run/ control/status files."))

(defpackage #:enchiridion.kernel
  (:use #:cl)
  (:export
   #:agent #:make-agent #:agent-name #:agent-turn #:run-turn #:agent-snapshot
   #:*turn-progress-function*
   ;; Agent accessors.
   #:agent-backend #:agent-blocks #:agent-budget #:agent-directory
   #:compile-prompt #:prompt #:prompt-text #:prompt-tokens #:snapshot-p
   #:record-spend #:spend #:spend-since #:spend-count #:spend-summary #:reset-spend
   #:budget-exhausted-p #:spend-row
   #:session #:make-session #:session-id #:session-turns #:end-session
   #:heartbeat #:task-queue #:enqueue-task #:dequeue-task #:task-queue-length
   #:sleep-agent #:run-sleep-pass
   ;; Adaptation bearing and proposals.
   #:adaptation-path #:adaptation-proposal-path #:adaptation-maturity
   #:adaptation-bearing #:adaptation-begin #:adaptation-finish
   #:adaptation-apply-proposal #:adaptation-maintenance-prompt
   #:adaptation-rows #:revert-adaptation #:*adaptation-operator-channels*
   ;; Persistence failure reporting for health checks.
   #:*persistence-failure-reporter* #:persistence-failures
   #:last-persistence-failure)
  (:documentation "Core agent loop, prompt compiler, snapshot, budget ledger, and sleep pass."))

(defpackage #:enchiridion.user
  (:use #:cl)
  (:export #:*enchiridion-config*)
  (:documentation "Package into which operator config.lsp files are loaded."))
