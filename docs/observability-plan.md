---
title: "Observability on the Argo Playground — a study plan"
author: "Alex Benisch"
date: 2026-09-12
geometry: "margin=1.5cm"
papersize: a4
---

## What this document is

A theory-first plan for learning the Grafana observability stack — Prometheus,
Loki, Tempo, Grafana, Alloy, OpenTelemetry — on the existing playground
cluster. It is deliberately **not** an install guide. It defines the mental
model, settles the architectural decisions up front, and sequences the material
so each stage introduces exactly one new idea.

Hands-on comes after. Every stage below ends with checkpoint questions; if you
can't answer them from theory, installing the chart won't teach you the answer,
it will just give you a dashboard you don't understand.

## 1. The mental model

Every observability system, regardless of vendor, is the same four-layer
pipeline. Learn the layers first and the product names stop being confusing —
they're just implementations of a layer.

```
  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
  │  INSTRUMENT │──▶│   COLLECT   │──▶│    STORE    │──▶│  QUERY/VIZ  │
  └─────────────┘   └─────────────┘   └─────────────┘   └─────────────┘
   emit the data     scrape/receive     TSDB / log &      dashboards,
   in the first      it, transform,     trace backends    ad-hoc query,
   place             route it                             alerting

   OTel SDKs         Alloy              Prometheus        Grafana
   /metrics          OTel Collector     Loki
   stdout logs                          Tempo
```

Three (arguably four) **signals** flow through it:

| Signal      | Shape                                       | Answers                            | Cost driver          |
|-------------|---------------------------------------------|------------------------------------|----------------------|
| **Metrics** | numbers over time, low cardinality          | *Is it broken? How broken?*        | unique label combos  |
| **Logs**    | timestamped text, high volume               | *What exactly happened?*           | bytes ingested       |
| **Traces**  | causally-linked spans across services       | *Where in the call chain?*         | spans, sample rate   |
| *Profiles*  | CPU/memory attribution to code              | *Which function?*                  | (out of scope, §8)   |

The single most important concept across all of them is **cardinality**. A
metric labelled with `user_id` or a log stream labelled with `request_id`
creates one time series / one stream per unique value, and that is how you
take down your own monitoring. Every design decision in Prometheus and Loki is
downstream of this constraint. If you internalise one thing before touching a
chart, make it this.

## 2. The pieces, and what each actually solves

### Prometheus — the metrics store

A time-series database with a **pull** model: it fetches `/metrics` from
targets it discovers, on an interval. The pull model is the defining choice —
it means the monitoring system owns the schedule, targets are inherently
health-checked by the scrape itself, and there is no push-side backpressure to
manage. It also means Prometheus must be able to *reach* every target, which is
why short-lived jobs need a Pushgateway and why the model gets awkward across
network boundaries.

In Kubernetes you almost never write scrape configs by hand. The
**Prometheus Operator** (shipped in `kube-prometheus-stack`) turns scraping
into declarative CRDs — `ServiceMonitor`, `PodMonitor`, `PrometheusRule` — which
is exactly the GitOps-shaped interface this repo already lives in. The stack
also bundles `node-exporter` (host metrics), `kube-state-metrics` (object state
— deployments desired vs. ready, etc.), and Alertmanager.

Know the difference between the four metric types (counter, gauge, histogram,
summary) and why `rate()` on a counter is the fundamental PromQL idiom.

### Loki — the log store

Grafana's log backend, designed around one deliberate trade-off: **it indexes
only labels, not log content**. Everything else is compressed chunks in object
storage. Elasticsearch inverts this — full-text index, fast arbitrary search,
much higher storage and memory cost.

The consequence you must understand before you touch it: a LogQL query is
always *"select a small set of streams by label, then brute-force grep them"*.
That is cheap when your labels narrow well and catastrophic when they don't.
It's also why "just add another label" is the wrong instinct in Loki — each
label value multiplies your stream count.

LogQL is intentionally shaped like PromQL, and can turn logs into metrics
(`rate({app="x"} |= "error" [5m])`) — which is often the right way to alert on
logs without paying for a metric.

### Tempo — the trace store

Same philosophy applied to traces: cheap object storage, minimal index. Tempo's
original design point was "retrieve by trace ID and nothing else", on the
theory that you find the trace ID from a metric exemplar or a log line rather
than by searching. TraceQL has since added real search, but the correlation-first
mindset is still the point.

**You did not list Tempo, and I'd add it.** OpenTelemetry without a trace
backend is OpenTelemetry with its most distinctive signal missing — you'd be
learning the SDK and the collector while throwing away the one data type that
justifies them. Traces are also where the stack's payoff lives (§7, stage 5).
It's one more Helm Application and roughly 300 MB.

### Grafana — the query and visualisation layer

A UI over **datasources**. It stores no telemetry of its own. Three things to
learn, in order: *Explore* (ad-hoc querying, where you'll spend stage 1),
*dashboards* (panels, template variables, and why dashboards-as-code beats
click-ops), and *unified alerting* (Grafana-managed rules, which overlap
confusingly with Alertmanager rules — see stage 6).

### Alloy — the collector

Grafana Alloy is the telemetry collector that replaced both Promtail and
Grafana Agent (both are now end-of-life — if a tutorial tells you to install
Promtail, it is out of date). Two things make it worth learning specifically:

1. **The config model.** Alloy configuration is a graph of typed components
   wired by explicit references, not a YAML blob of sections:

   ```
   discovery.kubernetes "pods" { role = "pod" }

   loki.source.kubernetes "pods" {
     targets    = discovery.kubernetes.pods.targets
     forward_to = [loki.write.default.receiver]
   }

   loki.write "default" {
     endpoint { url = "http://loki-gateway/loki/api/v1/push" }
   }
   ```

   Once you see that `forward_to` is just a wire between components, the whole
   thing becomes legible, and the built-in UI graph makes debugging a pipeline
   far more tractable than reading someone's `promtail.yaml`.

2. **It embeds upstream OpenTelemetry Collector components** (`otelcol.*`)
   alongside Prometheus-native (`prometheus.*`) and Loki-native (`loki.*`)
   ones. So learning Alloy gets you most of the OTel Collector for free, and
   lets you mix a native Prometheus scrape with an OTLP receiver in one
   process. This is why the plan below uses Alloy rather than the standalone
   OTel Collector — see §4.

### OpenTelemetry — the standard, not a product

This is the one people get wrong most often, so be precise about it. OTel is
four separable things:

- **A specification and data model** for the three signals.
- **Semantic conventions** — agreed attribute names (`service.name`,
  `http.request.method`, `k8s.pod.name`). Boring, and the actual source of
  OTel's value: it's what makes tooling portable across vendors.
- **SDKs and auto-instrumentation** per language — the part that runs *inside*
  your app and emits data.
- **OTLP**, the wire protocol, and **the Collector**, a vendor-neutral
  receive/process/export daemon.

Crucially: **OTel is not a backend.** It defines how telemetry is produced and
moved, then hands off to Prometheus/Loki/Tempo (or Datadog, or whatever) for
storage and query. "Should I use OpenTelemetry or Prometheus?" is a category
error — the real questions are "OTLP push or Prometheus pull?" and "OTel SDK or
Prometheus client library?".

## 3. Three confusions worth clearing up before you start

**"Alloy or the OpenTelemetry Collector?"** — Largely the same category of
thing; Alloy ships upstream Collector components inside its own component
system. Pick Alloy here because (a) it speaks Prometheus and Loki natively
without OTLP translation, (b) one agent covers all stages of this plan, (c)
its config graph is a better teaching tool. Read enough of the vanilla
Collector's `receivers/processors/exporters` YAML to recognise it in the wild —
you will meet it in other people's clusters — but don't run both.

**"Why run a collector at all if Prometheus can scrape directly?"** — For a
single small cluster, you genuinely don't need one. The reasons that appear at
scale: you want to scrape in one place and ship to several backends; you want
to drop or relabel high-cardinality series *before* they hit storage and cost
you; you want the storage tier to be a dumb, horizontally-scalable sink
(Mimir/Thanos) rather than a scraper; and you want one agent handling all three
signals rather than three daemons. Stage 3 exists specifically so you feel this
rather than take my word for it.

**"Push or pull?"** — Prometheus pulls. OTLP pushes. Both are now possible on
both sides: Prometheus 3.x can *receive* OTLP metrics
(`--web.enable-otlp-receiver`), and Loki 3.x exposes a native OTLP logs
endpoint. So the boundary is blurrier than the tutorials suggest, and the
interesting question becomes where in *your* pipeline the model switches from
pull to push. In the topology this plan ends at, it switches at Alloy: pull
from targets, push to storage.

## 4. Decisions to settle before stage 1

| Decision | Recommendation | Why |
|---|---|---|
| Grafana bundled in `kube-prometheus-stack`, or its own Application? | **Standalone**, with `grafana.enabled=false` in the stack | You'll add Loki and Tempo datasources later. One obvious place for Grafana's config beats reaching into a subchart's values, and it avoids a disruptive split mid-plan. |
| Loki deployment mode | **SingleBinary + `filesystem` storage** | Simple-scalable (read/write/backend) and microservices modes exist to teach you Loki's *internal* architecture, which is a distraction at stage 2. Know that production means object storage; run the toy. |
| Collector | **Alloy**, as a DaemonSet | §3. One agent, all signals, best config model for learning. |
| Metrics topology | Start at **Prometheus scrapes directly**, migrate to **Alloy -> remote_write** at stage 3 | The migration *is* the lesson. Starting at the end state teaches nothing. |
| Grafana admin password | **Vault -> ExternalSecret** | You just built that machinery. This is its first real use rather than a synthetic demo, and it keeps the credential out of a public repo. |
| Persistence | **`emptyDir` / ephemeral** everywhere | The cluster is destroyed nightly by design. Wiring PVCs you then delete teaches nothing; retention is a config value you can read about. |
| Traces backend | **Add Tempo** | §2. Without it, stages 4–5 have nowhere to send the most interesting signal. |

## 5. Resource reality — read this before stage 1

This is the constraint that will actually bite, so plan for it now rather than
debugging `OOMKilled` later.

The VM is a `cpx32` (4 vCPU / 8 GB) and `scripts/remote/host-setup.sh` starts
minikube with `--cpus=4 --memory=6g`. Current occupancy is roughly 40 pods:
Argo CD (~7), cert-manager (3), Argo Workflows (2), Vault, ESO (3),
ingress-nginx, the two `api-consumer` pods — **plus about 20 nginx replicas**
from the demo and webapp examples (`demo-app` 2, kustom dev 3 / prod 4, helm
dev 5 / prod 6).

Rough additional demand for the full stack: Prometheus 1–2 GB (the big one,
driven by retention and series count), Loki 0.5–1 GB, Tempo ~300 MB, Grafana
~200 MB, Alloy ~200 MB per node, plus the operator, Alertmanager,
kube-state-metrics and node-exporter. Call it **3–4 GB and ~10 pods**. That
does not fit in 6 GB alongside what's already there.

Two ways out, and I'd do both:

1. **Reclaim what's free.** Those ~20 nginx replicas are teaching artifacts —
   the replica counts exist to demonstrate Kustomize patches and Helm values,
   and they demonstrate that equally well at 1 each. Dropping them to 1 frees
   ~16 pods for nothing.
2. **Resize the VM.** The next step up in `nbg1` is **`cpx42` — 8 vCPU / 16 GB
   / 320 GB** (`SERVER_TYPE` in `scripts/lib.sh`), with minikube at
   `--memory=12g`. Roughly doubles the hourly rate, which on a torn-down-nightly
   playground is still cents per session. (`cax31` is the ARM equivalent and
   cheaper, but would need every image in the repo to have an arm64 build —
   not worth the yak-shave here.)

Do the resize before stage 4 at the latest; stages 1–2 will fit in 6 GB if you
trim the replicas first.

**One more pre-existing snag you'll hit:** `scripts/10-dns.sh` only creates A
records for `argo` and `argo-wf`. The four webapp hostnames
(`kustom-dev`, `kustom-prod`, `helm-dev`, `helm-prod`) have ingresses but no
DNS, so they've presumably never resolved. `grafana.kubetest.uk` will need the
same treatment — worth fixing `10-dns.sh` to take a list once, rather than
patching it per hostname.

## 6. Repo integration

Nothing here changes the existing pattern: one Argo CD `Application` per
component in `manifests/apps/`, Helm charts pinned by version, sync waves for
ordering. Current waves run -1 (cert-manager, ESO) through 4 (vault-secrets),
so observability slots in above that:

| Wave | Component | Depends on |
|------|-----------|------------|
| 5 | `kube-prometheus-stack` (CRDs: ServiceMonitor, PrometheusRule) | cert-manager |
| 5 | `loki`, `tempo` | — |
| 6 | `grafana` | its ExternalSecret for the admin password; datasource targets existing |
| 7 | `alloy` | all three backends reachable |

Chart versions current as of writing, to pin at install time:

| Chart | Repo | Version | App |
|---|---|---|---|
| `kube-prometheus-stack` | `prometheus-community.github.io/helm-charts` | 90.1.1 | operator v0.93.1 |
| `grafana` | `grafana.github.io/helm-charts` | 10.5.15 | 12.3.1 |
| `loki` | `grafana.github.io/helm-charts` | 7.3.0 | 3.6.12 |
| `tempo` | `grafana.github.io/helm-charts` | 1.24.4 | 2.9.0 |
| `alloy` | `grafana.github.io/helm-charts` | 1.12.1 | v1.19.2 |

The Grafana ingress follows `manifests/config/argocd-ingress.yaml` — nginx
class, `letsencrypt` ClusterIssuer, DNS-01. Grafana serves plain HTTP behind
the ingress, so no insecure-mode workaround is needed.

## 7. The staged plan

Each stage: the idea, what to read, what you'd build, and the checkpoint. Move
on only when the checkpoint questions are answerable without looking.

---

### Stage 0 — Theory only. No cluster.

**Idea:** the four-layer pipeline and the three signals (§1). Cardinality as
the universal constraint.

**Read:** Google SRE Book ch. 6 ("Monitoring Distributed Systems") for the RED
and USE method vocabulary; the OpenTelemetry docs' "What is OpenTelemetry"
page; the Prometheus docs on data model and metric types.

**Checkpoint:**

- Which signal answers "is the service up", and which answers "why was *this
  one* request slow"?
- Why is `http_requests_total{user_id="…"}` a bug rather than a useful metric?
- What is the difference between a metric with high *volume* and one with high
  *cardinality*, and which one hurts more?

---

### Stage 1 — Metrics: Prometheus + Grafana

**Idea:** one signal, end to end, with the pull model made concrete.

**Concepts:** scraping and service discovery; the Operator's
`ServiceMonitor`/`PodMonitor` CRDs and how a label selector connects one to a
`Prometheus`; PromQL (selectors, `rate()`, aggregation with `by`/`without`,
histogram quantiles); retention and the local TSDB; recording rules; the
Grafana datasource -> Explore -> dashboard progression.

**Build:** `kube-prometheus-stack` with Grafana disabled; Grafana standalone
with its admin password from Vault via ExternalSecret; a `ServiceMonitor`
against something you already run — ingress-nginx and Argo CD both export
useful metrics, and Argo CD's are more interesting because you understand what
they mean.

**Checkpoint:**

- Trace the path from a `ServiceMonitor` you wrote to a series in the TSDB.
  What does the Operator actually *do* with that CRD?
- Why `rate(x_total[5m])` and not `x_total`? What breaks if the counter resets?
- Where does a Prometheus dashboard's data live when Grafana is restarted, and
  where does the *dashboard* live?

---

### Stage 2 — Logs: Loki + Alloy

**Idea:** the second signal, and the label-index trade-off. First contact with
Alloy, doing exactly one job.

**Concepts:** streams and labels vs. log content; LogQL's two-phase shape
(stream selector, then line filter / parser); why `|= "error"` is cheap and a
regex over unlabelled streams is not; parsers (`json`, `logfmt`) and when to
extract a label vs. leave it in the line; Alloy's component graph, and
`discovery.kubernetes` -> `loki.source.kubernetes` -> `loki.write` as a concrete
pipeline; relabelling and dropping noise before ingest.

**Build:** Loki in SingleBinary/filesystem mode; Alloy as a DaemonSet tailing
pod logs; Loki added as a Grafana datasource. Read your own `api-consumer` and
Argo CD logs in Explore.

**Checkpoint:**

- Why does Loki not build a full-text index, and what does that cost you at
  query time?
- You have a `request_id` in your log lines. Should it be a Loki label?
  Defend the answer.
- Convert "alert when error rate exceeds 5/s" into LogQL. Why might you prefer
  a real metric instead?

---

### Stage 3 — Alloy as the metrics pipeline

**Idea:** the agent/storage split. This is the stage that answers "why a
collector at all", and it introduces *no new product* — just a re-wiring.

**Concepts:** `prometheus.scrape` -> `prometheus.relabel` ->
`prometheus.remote_write`; remote-write as the push boundary; dropping series
at the agent to control cost; why large deployments separate scraping from
storage (and where Mimir/Thanos would go); the operational difference between
"Prometheus can't reach the target" and "the agent can't reach Prometheus".

**Build:** move one scrape job out of the Prometheus Operator and into Alloy,
remote-writing into the same Prometheus. Run both paths side by side and
compare the resulting series.

**Checkpoint:**

- What did you gain, and what did you lose, versus letting Prometheus scrape
  directly? Be honest — for a single cluster the answer may be "nothing".
- Where would you drop a high-cardinality label to save money, and why there?
- Prometheus pulls; remote-write pushes. What happens to each when the network
  between them is down for ten minutes?

---

### Stage 4 — OpenTelemetry: OTLP, SDKs, and traces

**Idea:** the third signal, and instrumentation from *inside* the application
rather than scraped from outside.

**Concepts:** the OTel data model (resource, scope, span, span context,
attributes); semantic conventions and why `service.name` matters; context
propagation via W3C `traceparent`, and why a missing propagator is the usual
reason a trace is broken in half; OTLP over gRPC vs. HTTP; auto- vs. manual
instrumentation; sampling (head vs. tail) and what each costs you;
`otelcol.receiver.otlp` -> `otelcol.processor.batch` ->
`otelcol.exporter.otlp` in Alloy.

**Build:** Tempo; Alloy configured as an OTLP receiver; a small
instrumented two-service app so you have a trace that actually crosses a
service boundary. A single service produces a boring trace — the whole point is
the hop. (The `opentelemetry-demo` chart is an option, but it's heavy and
you'll learn more from twenty lines you wrote yourself.)

**Checkpoint:**

- A trace arrives split into two disconnected halves. Name the three most
  likely causes.
- Your app emits metrics via the OTel SDK over OTLP. Name two routes into
  Prometheus and the trade-off between them.
- At 10k requests/sec you cannot store every trace. Head or tail sampling, and
  what does each make impossible?

---

### Stage 5 — Correlation: the actual payoff

**Idea:** three signals in one pane, navigable between. Everything before this
was setup; this is the reason the stack exists.

**Concepts:** exemplars (a trace ID attached to a histogram bucket — needs
`--enable-feature=exemplar-storage`) letting you jump metric -> trace; trace ID
in log lines letting you jump trace -> logs; Grafana *derived fields* and
datasource-linking configuration; TraceQL; the service graph.

**Build:** wire the three datasources together until you can start from a
latency spike on a dashboard, click into the exact slow trace, and land on that
request's logs — without typing a query.

**Checkpoint:**

- What has to be true of your instrumentation, end to end, for metric -> trace ->
  log to work? List every link in the chain.
- Why is an exemplar cheap where a high-cardinality `trace_id` label would be
  ruinous?

---

### Stage 6 — Alerting (optional)

**Idea:** turning signals into pages, and the SLO framing.

**Concepts:** Alertmanager (routing, grouping, inhibition, silences) vs.
Grafana unified alerting — they overlap and you should be able to say when to
use which; `PrometheusRule` CRDs; symptom-based vs. cause-based alerting;
SLOs, error budgets, multi-window burn-rate alerts.

**Checkpoint:**

- Why does multi-window burn-rate beat "error rate > 1% for 5 minutes"?
- One database dies and forty services alert. Which Alertmanager feature fixes
  that, and how?

---

## 8. Deliberately out of scope

- **Mimir / Thanos** — long-term horizontally-scalable metrics. Only meaningful
  once you have multiple clusters or retention beyond local disk. The concept
  ("remote-write into a shared store") is already covered by stage 3.
- **Pyroscope / continuous profiling** — the fourth signal. Genuinely
  interesting, but it answers a question you won't have until the first three
  are second nature.
- **Fluent Bit / Vector / Elasticsearch** — alternative log pipelines. Worth
  knowing they exist and that Elasticsearch makes the opposite index trade-off
  to Loki. Running them teaches nothing new here.
- **Grafana Cloud / k8s-monitoring-helm** — the batteries-included path. It
  works well and hides exactly the things you're trying to learn.

## 9. Suggested next step

Stage 0 is reading, not building. The first thing that touches this repo is
stage 1, and before that the two prerequisites from §5 are worth doing as a
single small change: trim the example replica counts, and generalise
`scripts/10-dns.sh` to take a hostname list (it'll need `grafana` shortly, and
the four webapp hosts are already missing).
