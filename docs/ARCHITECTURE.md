# Architecture

## 1. System design

```
POST /webhook/arcvault-intake  {source, message}
  │
  ├─ Normalize Input ─ Valid? ──(no)── 400 {"error"}  (no record)
  │                     │(yes)
  │   Build Classify Request → LLM: Classify & Extract (gpt-oss-120b) → Validate LLM Output
  │   → Route & Escalate (code) → Build Summary Request → LLM: Team Summary (gpt-oss-20b)
  │   → Build Record → Convert to File → Write Record File → Respond 200 {record}
```

- **Trigger:** each inbound message is one HTTP POST to an n8n webhook, which simulates email, web-form and portal
  integrations. `scripts/send-samples.ps1` replays the sample set.
- **Processing:** one request is one n8n execution with one item, run end to end. Three steps are code (validation,
  routing, record assembly) and two steps are LLM calls.
- **Response:** the caller waits for a "Respond to Webhook" node and receives the finished record (about 1.5–5.5 s).
- **State:** the pipeline keeps no state between requests.
  - Each record is written to `output/records/<request_id>.json`.
  - n8n's execution history (in its Docker volume) keeps every node's input and output for audit and debugging.
  - The sender script collects the responses into `output/arcvault_output.json`.
- **Secrets:** the Groq key lives only in n8n's encrypted credential store. The exported workflow references it by
  name.

**Models.** Groq's free tier, through its OpenAI-compatible API, so switching provider is a change of URL and model
name.
- **Classification:** `openai/gpt-oss-120b`, the most accurate production model available on the free tier. It
  supports **strict `json_schema`** (constrained decoding), so the output shape is guaranteed. The planned Llama 3.3 70B
  had been retired on 2026-08-16.
- **Summary:** `gpt-oss-20b`. It's an easier task, the model is faster, and it has a separate quota.

## 2. Routing logic

| Category | Queue (`suggested_queue`) | Why |
|---|---|---|
| Bug Report | Engineering | Something is broken for a user; engineers reproduce and fix |
| Incident/Outage | Engineering (On-call) | Needs immediate response (in practice always escalated, see below) |
| Feature Request | Product | Roadmap decision, not a fix |
| Billing Issue | Billing | Invoices and contracts need finance access |
| Technical Question | Technical Support | How-to and configuration answers |
| LLM failure / unknown category | Escalation – Human Review | Nothing safe to route automatically |

**Why code makes this decision, not the LLM.** The LLM does the judgment work: classifying, extracting and
summarising. **Code decides everything with consequences.** Routing is a lookup table, so it is:
- **auditable:** every decision traces to a rule
- **testable:** the same input gives the same output
- **free:** no tokens
- **safe:** a manipulated model can't route around it

## 3. Escalation logic

If **any** rule fires, `destination_queue` becomes **"Escalation – Human Review"** and each rule adds a readable reason
to `escalation_reasons`. `suggested_queue` keeps the normal owner, so the reviewer confirms or redirects instead of
triaging from scratch (human-in-the-loop).

| Rule | Why |
|---|---|
| Confidence < 0.70 | The brief's threshold, and the low-confidence fallback |
| Category = Incident/Outage | Customer-wide impact needs a person immediately |
| Bug Report with `multiple_users` / `organization` impact | A bug hitting many users is a potential incident. Applied to bugs only, because billing and feature requests often say "our org" without anything being broken |
| Keywords in the raw text: outage, down for all/multiple/everyone, all users, multiple users, data loss, breach | A safety net **independent of the LLM** |
| Billing discrepancy \|billed − expected\| > $500 | The brief's "billing error > $500". The LLM only extracts the amounts; **code computes the gap**, because LLMs are unreliable at arithmetic and thresholds |
| LLM call failed / invalid output | A real message must never be dropped or misrouted silently |
| Suspected prompt injection | An attempt to manipulate the system is a security event worth a look |

**Tradeoffs and known limits:**
- **Keyword false positives.** Keywords favour false alarms over missed outages: "Do you publish outage reports?"
  escalates. A false alarm costs a reviewer seconds, while a missed outage costs customers.
- **Duplicate charges.** A holdout test showed the billing rule misses duplicate charges (a $2,150 double charge has
  no "expected" amount). The fix is to extract a `disputed_amount` and apply the same threshold. It is documented and
  not applied, so the holdout stays an honest test.
- **Currency.** The $500 threshold assumes USD amounts.

**Other failure handling:**
- Missing or empty message → HTTP 400 with no record.
- Malformed JSON → n8n returns 422.
- LLM HTTP errors → 3 retries, then `llm_valid=false` → escalated.
- Summary failure → a template summary built from the fields.
- Hallucinated identifiers, amounts or quotes → dropped by grounding against the message text, with a warning in
  `checks.warnings`.

**Evaluation:**
- 8/8 samples match the expected category, priority, queue and escalation, and the results are identical across
  repeated runs.
- A holdout set of 3 unseen messages scored 2/3 (the miss is the duplicate-charge limitation above).

## 4. Production scale

| Concern | Current (assessment) | Production |
|---|---|---|
| **Reliability** | Synchronous webhook; n8n retries; failures escalate | Put a **queue** (SQS / Pub/Sub / RabbitMQ) in front: the webhook enqueues and answers `202` immediately. Workers process with **idempotency** on a message ID or content hash (no duplicate tickets on redelivery). Exponential backoff that honours `retry-after`, and a **dead-letter queue** after N failures. n8n in queue mode with Postgres (not SQLite) and external task runners |
| **Cost** | ≈ $0.0005 per request at Groq paid rates (≈ $50 per 100K requests); about 80% of it is the static classify prompt | Prompt caching of the system prompt. Route easy messages to the 20B model and keep 120B for low-confidence or retry cases. Track cost per request as a metric |
| **Latency** | 1.3–5.5 s end to end, serial calls | Async processing removes it from the user path. Latency budget per stage. The summary could run in parallel with routing if it were made routing-independent (a quality tradeoff) |
| **Rate limits** | Free tier: 8K tokens/min; sender pauses 20 s | Paid tier, a client-side token bucket, and spreading load across models or providers |
| **Model fallback** | Retry, then escalate | Fallback chain (120B → 20B → second provider) through the same OpenAI-compatible interface, with the eval set run before switching |
| **PII and security** | Raw text sent to the LLM; webhook unauthenticated | Redact PII (emails, card numbers) before the LLM call; set retention limits on records and execution logs; choose data region; sign webhooks (HMAC); keep the n8n editor off the public internet |
| **Observability** | n8n execution log; per-record token usage | Dashboards for volume, escalation rate, confidence distribution, grounding warnings and cost. Alert on spikes (for example many outage escalations at once means a real incident) |

## 5. Phase 2 (one more week)

1. **Feedback loop.** When a reviewer changes a category or queue, store the correction. That builds a labelled
   dataset for evaluation, few-shot examples and threshold tuning.
2. **A larger eval set + regression tests in CI.** Every prompt or model change runs against it before deploying,
   because prompts are versioned like code.
3. **Calibrated confidence.** Self-consistency (k samples → agreement rate) or log-probabilities, then calibrate the
   0.70 threshold against real reviewer outcomes.
4. **Rules.** Add the `disputed_amount` billing rule, plus currency normalisation.
5. **Dedup and threading.** Link follow-ups and duplicate reports to an existing ticket. This also clusters outage
   reports.
6. **Real connectors.** Gmail/IMAP trigger, a helpdesk (Zendesk/Freshdesk) webhook in, and ticket creation out.
7. **Injection pre-filter.** A dedicated classifier (for example Llama Prompt Guard 2) before the main call.
