;;;; settings.cl --- The memory module's settings, bound from the :memory section.
;;;;
;;;; Every value here comes from the configuration. None carries a default of
;;;; its own: DEFAULT-CONFIG holds the one shipped default for each key, and
;;;; this file binds the specials from it when it loads, so a reader that ran
;;;; before CONFIGURE-MEMORY still sees the shipped values rather than a second
;;;; copy of them that can drift. CONFIGURE-MEMORY rebinds them from config.cl.
;;;;
;;;; The file loads first in the module, because the blocks, the pack, and the
;;;; gates all read these specials.

(in-package #:enchiridion.memory)

(defvar *memory-enabled-p*)
(setf (documentation '*memory-enabled-p* 'variable)
      "Master switch. NIL makes every integration hook a no-op.")

(defvar *memory-retrieve-p*)
(setf (documentation '*memory-retrieve-p* 'variable)
      "When true, a turn asks for a cue pack.")

(defvar *memory-push-p*)
(setf (documentation '*memory-push-p* 'variable)
      "When true, the four push channels compete for the pack. Off until measured.")

(defvar *memory-record-sleep-p*)
(setf (documentation '*memory-record-sleep-p* 'variable)
      "When true, sleep and compaction turns are appended to the log.")

(defvar *memory-maintenance-batch*)
(setf (documentation '*memory-maintenance-batch* 'variable)
      "Episodes one maintenance pass may derive links and rarity for.")

(defvar *memory-t2-episodes-per-tick*)
(setf (documentation '*memory-t2-episodes-per-tick* 'variable)
      "Episodes one T2 candidate build may parse in one tick. The build is
resumable, so a large log is processed in bounded batches.")

(defvar *memory-embed-settings*)
(setf (documentation '*memory-embed-settings* 'variable)
      "The :memory section's embedding keys, as a plist. The harness builds the
embedder from these; nothing here makes a connection.")

(defvar *memory-rerank-p*)
(setf (documentation '*memory-rerank-p* 'variable)
      "When true, the harness installs a cheap-model reranker. Off until measured.")

(defvar *memory-pack-chars*)
(setf (documentation '*memory-pack-chars* 'variable)
      "The cue pack budget in characters. The resident blocks are charged
separately, so this is not the whole prompt.")

(defvar *push-max-fraction*)
(setf (documentation '*push-max-fraction* 'variable)
      "The most of the pack that push may occupy. INVENTED-DESIGN. The
justification is structural rather than measured: push must not be able to
evict a retrieved record the cue ranked above it, and capping push at a
fraction of the budget makes that guarantee enforceable rather than
aspirational.")

(defvar *memory-graph-limit*)
(setf (documentation '*memory-graph-limit* 'variable)
      "Link rows one retrieval may load.")

(defvar *memory-gate-margin*)
(setf (documentation '*memory-gate-margin* 'variable)
      "The least outcome delta by which consolidation must beat retention-only.")

(defvar *memory-gate-min-n*)
(setf (documentation '*memory-gate-min-n* 'variable)
      "The fewest outcome rows each arm needs before the utility gate can open.")

(defvar *memory-gate-alpha*)
(setf (documentation '*memory-gate-alpha* 'variable)
      "The one-sided sign test's significance level for the utility gate.")

(defvar *gate-pack-chars*)
(setf (documentation '*gate-pack-chars* 'variable)
      "The pack budget, in characters, that both utility arms are scored in.
Smaller than the turn's pack, so the gate rewards a semantic layer that says
the same thing in less room.")

(defvar *memory-tail-margin*)
(setf (documentation '*memory-tail-margin* 'variable)
      "How far the candidate's recall on rare answers may fall below
retention-only before the tail gate fails.")

(defvar *t2-max-tokens-per-promotion*)
(setf (documentation '*t2-max-tokens-per-promotion* 'variable)
      "The most tokens the candidates built since the last promotion may have
cost, together, for the next one to be promoted.")

(defvar *memory-writes-per-episode*)
(setf (documentation '*memory-writes-per-episode* 'variable)
      "The most semantic rows a candidate may write per episode it derived:
the volume gate's allowance grows with the work the build did, so ordinary
output passes and a deriver that writes far more than usual does not.")

(defvar *memory-canaries*)
(setf (documentation '*memory-canaries* 'variable)
      "The operator's canaries: plists of :NAME, :FAMILY, :CUE and :EXPECT, and
:STALE for the update family. They are the only external ground truth the
memory has, so they come from config.cl and nowhere else.")

(defvar *canary-min-families*)
(setf (documentation '*canary-min-families* 'variable)
      "How many canary families must be covered before promotion can be checked.")

(defvar *tail-rarity-fraction*)
(setf (documentation '*tail-rarity-fraction* 'variable)
      "The share of episodes, rarest first, that the tail gate treats as rare.")

(defvar *tail-min-n*)
(setf (documentation '*tail-min-n* 'variable)
      "The fewest rare tasks a tail sample needs before the gate can be checked.")

(defvar *utility-max-tasks*)
(setf (documentation '*utility-max-tasks* 'variable)
      "The most question-and-answer pairs one utility run scores, newest first.")

(defvar *precision-min*)
(defvar *precision-window*)
(defvar *precision-min-checked*)
(setf (documentation '*precision-min* 'variable)
      "The least share of recent promotions that must pass their post-promotion
check, below which promotion freezes until the operator resets it.")

(defvar *quarantine-max*)
(defvar *quarantine-window*)
(defvar *quarantine-min-candidates*)
(setf (documentation '*quarantine-max* 'variable)
      "The most share of recently gated candidates that may be quarantined,
above which promotion freezes and T2 runs at the frozen interval.")

(defvar *t2-enabled-p*)
(setf (documentation '*t2-enabled-p* 'variable)
      "True when the heartbeat runs T2 passes on their schedule.")

(defvar *t2-episode-threshold*)
(setf (documentation '*t2-episode-threshold* 'variable)
      "New episodes since the last pass that make a T2 pass due before its
interval has elapsed. Ignored while the quarantine rate is over its ceiling.")

(defvar *t2-max-tokens-per-pass*)
(setf (documentation '*t2-max-tokens-per-pass* 'variable)
      "Most tokens T2 may spend in any rolling twenty-four hours. A candidate
that reaches it pauses and resumes once the window has room.")

(defvar *t2-deriver-max-tokens*)
(setf (documentation '*t2-deriver-max-tokens* 'variable)
      "The reply cap of one T2 deriver call. The deriver gets a backend of its
own with this cap, so the chat path keeps the :llm section's :max-tokens.")

(defvar *t2-deriver-model*)
(setf (documentation '*t2-deriver-model* 'variable)
      "The model the T2 deriver calls, or NIL for the cheap tier's model. A
deriver wants a model that answers in JSON without a long reasoning pass,
which is not always the model a turn wants.")

(defvar *t2-interval-seconds*)
(defvar *t2-frozen-interval-seconds*)
(setf (documentation '*t2-frozen-interval-seconds* 'variable)
      "The T2 interval while the quarantine rate is over its ceiling.")

(defvar *compaction-rebase-every*)
(setf (documentation '*compaction-rebase-every* 'variable)
      "Every this many compaction passes, one rebuilds the session block from raw
turns instead of the previous summary, so the summary cannot drift by
summarising itself.")

(defvar *compaction-rebase-turns*)
(setf (documentation '*compaction-rebase-turns* 'variable)
      "How many raw turns a rebase pass reads.")

(defvar *block-limits*)
(setf (documentation '*block-limits* 'variable)
      "Character limits per block label, the shipped :block-limits with the
operator's merged over them key by key. Raising a limit raises the fixed token
cost of every prompt.")

(defvar *unlisted-block-limit*)
(setf (documentation '*unlisted-block-limit* 'variable)
      "The limit for a block whose label *BLOCK-LIMITS* does not name.")

(declaim (ftype (function (list list) list) merge-plist))

(defun merge-plist (base overrides)
  "Return a fresh copy of BASE with each key of OVERRIDES set over it."
  (let ((merged (copy-list base)))
    (loop for (key value) on overrides by #'cddr
          do (setf (getf merged key) value))
    merged))

(declaim (ftype (function (t) t) apply-memory-settings))

(defun apply-memory-settings (config)
  "Bind every memory special from the :memory section of CONFIG, falling back
key by key to the shipped defaults. Return NIL."
  (flet ((setting (key)
           (enchiridion:config-setting config :memory key))
         (shipped (key)
           (enchiridion:config-setting (enchiridion:default-config) :memory key)))
    (setf *memory-enabled-p* (not (null (setting :enabled)))
          *memory-retrieve-p* (not (null (setting :retrieve)))
          *memory-push-p* (not (null (setting :push)))
          *memory-record-sleep-p* (not (null (setting :record-sleep)))
          *memory-rerank-p* (not (null (setting :rerank)))
          *memory-embed-settings* (list :enabled (not (null (setting :embed)))
                                        :model (setting :embed-model)
                                        :dimensions (setting :embed-dimensions)
                                        :base-url (setting :embed-base-url)
                                        :key-env (setting :embed-key-env))
          *memory-maintenance-batch* (setting :maintenance-batch)
          *memory-t2-episodes-per-tick* (setting :t2-max-episodes-per-tick)
          *memory-pack-chars* (setting :pack-chars)
          *push-max-fraction* (setting :push-max-fraction)
          *memory-graph-limit* (setting :graph-limit)
          *memory-gate-margin* (setting :gate-margin)
          *memory-gate-min-n* (setting :gate-min-n)
          *memory-writes-per-episode* (setting :t2-writes-per-episode)
          *memory-gate-alpha* (setting :gate-alpha)
          *memory-tail-margin* (setting :tail-margin)
          *gate-pack-chars* (setting :gate-pack-chars)
          *t2-max-tokens-per-promotion* (setting :t2-max-tokens-per-promotion)
          *memory-canaries* (let ((own (setting :canaries))) (if (listp own) own '()))
          *canary-min-families* (setting :canary-min-families)
          *tail-rarity-fraction* (setting :tail-rarity-fraction)
          *tail-min-n* (setting :tail-min-n)
          *utility-max-tasks* (setting :utility-max-tasks)
          *precision-min* (setting :precision-min)
          *precision-window* (setting :precision-window)
          *precision-min-checked* (setting :precision-min-checked)
          *quarantine-max* (setting :quarantine-max)
          *quarantine-window* (setting :quarantine-window)
          *quarantine-min-candidates* (setting :quarantine-min-candidates)
          *t2-enabled-p* (not (null (setting :t2-enabled)))
          *t2-episode-threshold* (setting :t2-episode-threshold)
          *t2-max-tokens-per-pass* (setting :t2-max-tokens-per-pass)
          *t2-deriver-max-tokens* (setting :t2-deriver-max-tokens)
          *t2-deriver-model* (let ((own (setting :t2-deriver-model)))
                               (and (stringp own) (plusp (length own)) own))
          *t2-interval-seconds* (setting :t2-interval-seconds)
          *t2-frozen-interval-seconds* (setting :t2-frozen-interval-seconds)
          *compaction-rebase-every* (setting :compaction-rebase-every)
          *compaction-rebase-turns* (setting :compaction-rebase-turns)
          ;; An operator who writes (:persona 8000) keeps the other limits.
          *block-limits* (merge-plist (shipped :block-limits)
                                      (let ((own (setting :block-limits)))
                                        (if (listp own) own '())))
          *unlisted-block-limit* (setting :unlisted-block-limit)))
  nil)

(apply-memory-settings (enchiridion:default-config))
