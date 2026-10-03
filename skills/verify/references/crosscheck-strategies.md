# Advice and planning crosschecks

Use only after the shared entrypoint has established task-scoped external-review permission. Both participants propose and evaluate; only the host implements under existing permissions.

## Shared brief and independent proposals

Give both participants the same goal, supplied facts, constraints, success criteria, and available evidence. Distinguish those facts from assumptions. Do not invent missing project details or approval. For conceptual questions, use the supplied requirements as evidence; repository access remains subject to the wrapper's compatibility and permission contract.

Both scan relevant perspectives: user value, correctness/failure conditions, simplicity/existing structure, token/time/maintenance cost, and practical adoption/verification. Omit irrelevant perspectives. Complementary emphasis is useful, but do not make one participant always positive or always negative, or divide the question so neither checks the whole proposal.

Keep each initial proposal within 10 lines and a cross-model summary within 15. Cover the strongest applicable points:
- Conclusion and useful parts of the current approach.
- Material problems or unproven assumptions, with evidence and consequences.
- The most useful improvement or simpler alternative, including keeping the current approach when appropriate.
- Expected benefit, cost, risk, conditions, and a feasible way to verify value.

Do not force a quota of ideas, criticisms, or alternatives. Prefer one actionable finding to several speculative ones. Existing conclusions are hypotheses, not a substitute for current evidence; disclose prior exposure that limits independence.

## Candid evaluation

Use `RECOMMENDATION: adopt|revise|keep-current|avoid|need-info`, compatible with the wrapper's required `VERDICT` and numbered findings.
- `adopt`: benefit justifies the cost under stated conditions.
- `revise`: the goal is useful, but the proposed approach needs specific changes.
- `keep-current`: the current approach is adequate and the improvement has poor marginal value.
- `avoid`: the proposal undermines the goal, violates constraints, or imposes unjustified cost/risk.
- `need-info`: a missing fact could materially change the recommendation; identify it precisely.

Say plainly when a proposal is bad or not worth doing, and explain the decisive reason and applicable conditions. Do not soften a negative conclusion into obligatory praise, invent faults to sound critical, or label a preference as a demonstrated defect. Distinguish observed evidence, predictions, and preferences; model agreement or self-rated confidence does not establish correctness.

Keep-current/avoid may finish an advice request without edits. Do not silently cancel an explicitly required deliverable merely because an optional improvement was rejected.

## Strategy execution and stopping

`independent` — Freeze both proposals before reading the counterpart's output. The host checks and merges common points, valuable one-sided discoveries, and conflicts. Normally one reviewer call; no automatic follow-up.

`debate` — Send the existing draft, criteria, and evidence once. Ask what is sound, what fails, and whether a simpler alternative or keeping the current approach is better. The host checks the critique and revises or rejects the draft. No follow-up just to obtain AGREE; follow up only for a consequential unresolved objection, decision-changing information, or an accepted fix needing verification.

`mutual` — Start with independent proposals. The host checks the counterpart's proposal, then sends its own frozen proposal and only material review findings in one follow-up. The counterpart must evaluate the host's proposal, answer relevant objections, and justify changed recommendations. This is mutual review even if the initial proposals agree; an initial agreement does not bypass it. Normally two reviewer calls total: initial proposal and reciprocal review. Allow one additional exchange only for the consequential conditions above, within the shared round/session caps.

Stop after the useful comparison; do not automatically add a separate plan-approval call to an advice request. In plan/full mode, reuse already observed coverage of an unchanged plan; changed code or unreviewed material decisions still need their relevant checks. Final code verification retains its fresh-session contract.

## Merge and evaluate value

Do not vote with two participants or discard a proposal because only one found it. The host owns the final recommendation, chosen against the shared goal, evidence, and cost. Keep conditional alternatives and unresolved dissent visible rather than manufacturing consensus. Summaries must retain the strongest relevant objection.

Lead with the recommendation and reason, then useful improvements in priority order, conditions/cost/risks, and only meaningful dissent or missing evidence. Identify a small validation step when useful. Avoid unsupported precision or exhaustive reports.

Evaluate future effectiveness by actionable unique findings, justified rejections, actual quality of adopted changes, and measured calls/tokens/time. Consensus rate and number of rounds are not quality measures. Do not claim measured savings or cross-model behavior from static validation alone.
