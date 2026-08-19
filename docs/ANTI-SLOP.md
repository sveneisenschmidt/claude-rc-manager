# Anti-Slop Writing Rules

Stop the slop. Slop is text that nobody championed: the author cannot explain or defend its
contents. These patterns make text feel machine-generated, dilute meaning, or substitute
rhythm for substance. They apply to all prose in this repo: commits, PRs, issues, specs, docs,
comments, and user-facing strings. Rules 29 to 32 (Response shaping) also govern chat
replies.

Base style: [ASD-STE100](https://asd-ste100.org/) (Simplified Technical English). Short
sentences, active voice, simple words, one fact per sentence, same term for the same thing.
Then check the result against the rules below.

## Content checks before style

The style rules operate on words. They cannot detect a wrong fact, an undefined term, or a
missing argument. Rule-compliant prose gives weak reasoning a confident appearance. Check
content first:

- **Define every term at first use, or delete it.** A cold reader must follow the document
  without asking what a word means.
- **Every factual claim carries a source or an owner.** Name the file, the issue, the
  measurement, or the person. If you cannot, the claim does not go in.
- **Every number passes a sanity check.** Compare each figure against a known reference
  before it ships.
- **Keep the causal chain visible.** Write the claim, the reason, and the evidence. If a
  conclusion needs three steps, write three steps. Compression that drops the reason leaves
  a gap in the argument.
- **Claim audit.** Before committing a spec, plan, PR body, or issue: every sentence that
  asserts code or test behaviour is checked against the file it describes. A claim about a
  moving target (an open PR, a running count) carries the timestamp of its measurement.

A document can pass all style rules and fail all four checks. That document is worse than
obvious slop, because it looks finished.

Each rule: what to avoid, why, and what to do instead.

## 1. No contrastive antithesis
- **Don't:** "It's not just a feature, it's a paradigm shift." Also the flat variant when the contrast adds no content: "The reasoning is A, not B."
- **Why:** dramatic shape, no information.
- **Do:** state the actual claim directly. "This feature changes how users onboard." Contrast is allowed when it carries the mechanism ("announces intent instead of executing it"), not when it only adds drama.

## 2. No em-dash overuse
- **Don't:** "The plan, which we discussed, needs review, soon." (written with em-dashes between each clause)
- **Why:** rhythmic crutch, breaks flow.
- **Do:** use commas, periods, or parentheses. Reserve em-dashes for genuine asides.

## 3. No abstract metaphor clichés
- **Don't:** "In the ever-evolving landscape of...", "navigating the realm of...", "the rich tapestry of...".
- **Why:** filler phrases that signal effort without delivering content.
- **Do:** name the actual thing. "In B2B SaaS pricing..." instead of "in the landscape of pricing."

## 4. No announcement verbs
- **Don't:** "Let's delve into...", "Let's explore...", "Let's unpack...", "Let's dive deep into...".
- **Why:** announces intent instead of executing it.
- **Do:** just start. "ERP migration has three risks: ..."

## 5. No hedge stacking
- **Don't:** "It's worth noting that, in many cases, it could perhaps be argued that..."
- **Why:** multiple hedges erase the claim.
- **Do:** state the position with one calibrated hedge max. "In most B2B cases, X holds."

## 6. No listicle reflex
- **Don't:** turning every answer into bullets when prose would be clearer.
- **Why:** fragments thinking, hides reasoning.
- **Do:** use bullets for genuine lists; use prose for arguments and reasoning.

## 7. No mirror openers / restating the prompt
- **Don't:** "Great question! You're asking about how to handle the ERP rollout..."
- **Why:** wastes the reader's time.
- **Do:** answer directly. The reader knows what they asked.

## 8. No sycophantic openers
- **Don't:** "What a fascinating problem!", "That's a great question!", "Excellent point!".
- **Why:** empty validation, signals agreement-bias.
- **Do:** skip the opener. Start with the substance.

## 9. No false symmetry / both-sides-ism
- **Don't:** presenting two positions as equally weighted when evidence is clearly one-sided.
- **Why:** fake neutrality is dishonest.
- **Do:** state where the evidence points; flag the minority position briefly if relevant.

## 10. No throat-clearing closes
- **Don't:** "In conclusion...", "To summarize, it's important to remember...", "Ultimately, the key takeaway is...".
- **Why:** repeats what was just said.
- **Do:** stop when the point is made. If a summary is needed, make it new information.

## 11. No concept-laundering through abstraction
- **Don't:** "At its core, this represents a paradigm shift in how we approach value creation."
- **Why:** abstract layering hides whether there's a real claim underneath.
- **Do:** write the concrete claim. "Switching to usage-based pricing changes margins by X%."

## 12. No tricolon reflex
- **Don't:** "It's fast, efficient, and powerful." / "We need clarity, focus, and execution."
- **Why:** three-part rhythm as auto-pattern, often with redundant synonyms.
- **Do:** use one precise word, or use three only when each adds distinct meaning.

## 13. No performative sincerity
- **Don't:** "Constraints to mention honestly:", "frankly", "to be clear", "let's be honest", "the honest read is...".
- **Why:** claims honesty instead of being honest; the content must carry it.
- **Do:** state the constraint. "Constraints: Apple Silicon only."

## 14. No participle-trailer analysis
- **Don't:** "The build failed, highlighting the importance of CI." / ", underscoring...", ", showcasing...", ", reflecting...".
- **Why:** staples unearned analysis onto a fact sentence.
- **Do:** if the analysis matters, give it its own sentence with evidence; otherwise cut.

## 15. No significance verbs replacing "is"
- **Don't:** "serves as", "stands as", "marks a milestone", "is a testament to", "plays a vital role".
- **Why:** inflates a plain statement into fake importance.
- **Do:** use "is"/"does". "ConfigStore is the JSON store."

## 16. No AI vocabulary
- **Don't:** "delve", "crucial", "pivotal", "leverage", "harness", "robust", "seamless", "comprehensive", "cutting-edge", "streamline", "journey".
- **Why:** high-frequency LLM words; [Kobak et al. 2025 (Science Advances)](https://www.science.org/doi/10.1126/sciadv.adt3813) measured their excess frequency in over 15 million PubMed abstracts after ChatGPT's release. Each is vaguer than a concrete alternative.
- **Do:** the specific word. Not "robust error handling" but "retries five times, then fails the run".

## 17. No vague attribution
- **Don't:** "experts say", "studies show", "industry reports", "many consider".
- **Why:** unverifiable authority.
- **Do:** name the source and link it, or drop the claim.

## 18. No elegant variation
- **Don't:** rotating synonyms for one thing ("the app", "the tool", "the utility", "the solution").
- **Why:** reads as vocabulary showmanship and breaks term consistency.
- **Do:** same thing, same name, every time.

## 19. No bolded-label bullets
- **Don't:** every bullet as "**Speed:** ...", "**Safety:** ...".
- **Why:** mechanical structure that substitutes for connected reasoning.
- **Do:** prose for arguments; plain bullets for actual lists.

## 20. No rhetorical question scaffolding
- **Don't:** "Why does this matter?", "The result?", "So what's the catch?".
- **Why:** fake dialogue to manufacture transitions.
- **Do:** make the statement the question was stalling for.

## 21. No punchline fragments
- **Don't:** "Fast. Reliable. Done." / closing zingers like "And that changes everything." / colon-label fragments as answers: "Meine Seite: Minuten."
- **Why:** rhythm posing as conclusion.
- **Do:** complete sentences; end when the information ends. Applies in every language the conversation uses, like rule 26.

## 22. No reader-chumming
- **Don't:** "As developers, we all know...", "In today's fast-paced world...".
- **Why:** universalizes the audience to borrow agreement.
- **Do:** address the actual case; no "we" unless it names real people.

## 23. No verdict staging
- **Don't:** "This is where it lands.", "On the surface...", "X is the runner-up rather than the choice.", "The tension here is...", "The through-line is...".
- **Why:** metaphorical framing performs judgment instead of stating it; the verdict hides behind stagecraft.
- **Do:** state the verdict as a plain claim with the reason. "Option B is worse because it doubles cost."

## 24. No eager-availability closers
- **Don't:** "Just say the word.", "Happy to help!", "Let me know if you'd like me to...", "Want me to go ahead?", ending every message with an offer.
- **Why:** performs willingness instead of adding information; pads the close.
- **Do:** end when the information ends. Offer a next step only when the reader must decide one, and phrase it as a closed question with enumerated answers: "Merge the PR, yes or no?" or "Pick a date: A) May 5, B) May 12, C) May 19." The reader answers with one word or one letter. Open offers ("thoughts?", "should I?") and ability questions ("can you confirm...?") are not decision points.

## 25. No gate/guard vocabulary
- **Don't:** "gate", "gated", "gating", "gates", "guard" (and inflections) in prose: code comments, doc comments, Markdown docs, PR/issue text, commit messages, branch names.
- **Why:** metaphor where a precise word exists; one mechanism collects four names.
- **Do:** requirement, expectation, check, or condition. The Swift `guard` keyword in code statements is language syntax and stays; code identifiers referenced in backticks are code, not prose. `docs/superpowers/` is the archive: historical records there are exempt from vocabulary sweeps and from documentation-drift findings, and the archive is never a rule source. Text quoted verbatim from another source keeps the words, because it has to match what that source wrote. The lists that name the banned words keep them too. Text that names a banned word as its subject keeps it, which is what lets a rule, an issue, a commit message or a branch name state which word is meant.

## 26. No pretentious diction
- **Don't:** term-of-art metaphors and inflated synonyms where a plain word exists: "seam", "chokepoint", "hoist", "hydrate", "sentinel", "no-op" (and "noop"); "utilize", "employ", "orchestrate" for "use"/"run"; "carries" for contains/has, "surface" for a place or set of places, "drag along", "fold into" for combining scopes, "probe" for a quick check program, "lens" for a reviewer's assigned focus (say what the reviewer checks).
- **Why:** borrowed vocabulary performs expertise; the reader must translate it back into the plain fact.
- **Do:** the plain word: "test override", "single call site", "copied into a local". For "no-op", state what happens instead, which differs per site: "returns without changing anything", "writes the same value again", "does nothing when the key is absent", and in a state table the resulting state itself. A term of art earns its place only when defined at first use and used consistently. Rule 25 is the enforced special case of this rule for gate/guard. The exemptions of rule 25 apply here too.
- **The list records precedents, not the boundary.** The test for the whole class: does the word name a mechanism, an action, or a relation through an image where a plain word exists? Then it is this rule, in every language the prose or the conversation uses, whether or not the word is listed. A writer checks the sentence against this test before it ships, not against the list.

## 27. No personification
- **Don't:** code or components as actors with intentions: "ImageCaptureCore owes a completion", "the parser gives up", "the cache is happy". Also non-personified imagery that describes a state and stops there: "the entry is left dangling".
- **Why:** the image replaces the mechanism; the reader learns a mood, not what happens and what it causes.
- **Do:** condition, then consequence: "On unplug, requestReadData may never call its completion handler; the task then never finishes and a strong self would keep the source in memory."

## 28. No jargon-compressed claims
- **Don't:** "Die Projektionen bleiben im Rahmen." / "the two sheets use item: bindings with different payload types, but are structurally identical."
- **Why:** two failure shapes. A verdict compressed into shorthand forces the reader to reconstruct what was checked and what was found. A technical clause stapled to a claim that is already complete ("structurally identical") is decoration; the terms perform expertise without adding content.
- **Do:** write the finding as a plain sentence: what was checked, what holds. "None of the five bindings needs more than the pattern the issue already accepts." / "Both sheets need the same binding code, once with PhotoItem, once with ImportSheetPayload." Keep a technical term only when it adds something the plain sentence loses, and define it at first use (content checks above). Rules 25 and 26 ban single words; this rule bans the sentence shape.

## Response shaping

Rules 29 to 32 govern chat replies. The other rules apply there too. The four rules are
adapted from the i-have-adhd skill
([ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd)), whose premise ("What ADHD
changes about reading") is a reader with small working memory: the reader may not reach
an answer placed after its context. The skill defines ten rules; four are adopted here:
lead with the next action (rule 29), number multi-step tasks (rule 30), restate state
(rule 31), suppress tangents (rule 32). Its no-preamble rule is already covered by
rules 7, 8, 10, and 24. Its end-with-one-next-action rule is rejected: rule 24 permits
a next step only when the reader must decide one. Its time-estimate rule is rejected
because an invented number is speculation (the content check "Every number
passes a sanity check" above). Its remaining rules (make completed work visible,
matter-of-fact tone for errors, cap lists at 5 items) are not adopted.

## 29. Answer or action first
- **Don't:** background, method narration, or caveats before the result: "Before the answer, context on how the import loop works: ..."
- **Why:** the reader acts on the first sentence; an answer placed after the context is an answer the reader must search for.
- **Do:** the first sentence states the result or the next executable step. Reasoning and evidence follow it.

## 30. Numbered bounded steps
- **Don't:** multi-step instructions as flowing prose, or a step that contains a decision ("run X, and if it looks wrong, adjust Y").
- **Why:** a step without a visible end does not tell the reader when it is done; the reader must re-derive the plan in the middle of the step.
- **Do:** number the steps. Each step is one action with a visible end and works without a mid-step decision. A decision gets its own step with enumerated options (rule 24).

## 31. Progress restated
- **Don't:** assuming the reader remembers how far a multi-step task has progressed: "Continuing where we left off."
- **Why:** state that exists only in an earlier message forces the reader to scroll back.
- **Do:** in multi-step work, each reply names the position: "Step 3 of 5 done, step 4 running."

## 32. One task at a time
- **Don't:** interleaving side findings, ideas, or new questions with the current task: "Step 2 is done. Unrelated: the cache budget looks wrong, and also ..."
- **Why:** a tangent makes the reader lose track of the current task.
- **Do:** finish the current task. Then report side findings, each as its own decidable item (rule 24).

## 33. No self-grading labels
- **Don't:** labels or lead-ins that grade the writer's own delivery: "Der Konflikt, sauber benannt:", "a clean summary:", "kurz und präzise:", "the fix, done right:", "properly scoped:".
- **Why:** the label asserts a quality only the content can demonstrate; the reader gets a grade instead of the thing.
- **Do:** drop the grade, keep the noun: "Der Konflikt:". This is rule 13's special case for labels and applies in every language the conversation uses, like rule 26.
