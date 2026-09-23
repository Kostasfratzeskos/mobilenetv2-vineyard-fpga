# Latency map — every constant that encodes a pipeline depth

This is the checklist for the review's Phase 2. `docs/references/rtl_review.md` L-1 and L-3
are latency changes, and the depths they change are written down in seven other modules as
plain numbers. The point of this file is that none of those numbers is searchable today:
`3'd7`, `>> 1`, `grp_d4`, `GAP_CYC` and "the tag pipeline is two deep" are all the same
fact stated five different ways.

**How to use it.** When a module's latency changes, every row whose *Depends on* column
mentions that module changes in the SAME commit. A golden-vector failure after a Phase 2
change is a bookkeeping error in one of these rows, not an arithmetic error — every Phase 2
transformation is a reassociation or a latency change, never a change of value.

Baseline measured 2026-09-23 on commit `716ea8e`, all 31 testbenches passing.
Line references updated after Phase 1 (`6efb02a`); the VALUES are unchanged, because
Phase 1 changed no latency.

---

## 1. The two latencies everything else is derived from

| Name | Where | Value | What it is |
|:--|:--|--:|:--|
| `MAC_LAT` | `mac_lane` | **6** (was 1) | `valid` → `acc` final and `done` high. Now `1 + clog2(TN) + 1`: one registered product stage, `clog2(TN)=4` adder-tree levels, one accumulate stage (**L-1**, Phase 2a). |
| `OS_LAT` | `out_stage` | **2** | `acc_valid` → `q_valid`. Stage A registers `acc_q`/`vA` and issues the parameter read (1); `rq_bank`'s `requantize` registers the result (1). **L-3 grows this to 5 in Phase 2d.** |

Both are `localparam`s now, derived rather than written down: `MAC_LAT` from `TN` in
`mac_lane` (and restated by the same arithmetic in `pw_feeder`, which is the only module
that needs it and cannot see into the array), `OS_LAT` as a **parameter** of `accel_top`
passed down to each feeder, because `out_stage` is instantiated at the top and a feeder
cannot see its depth either.

Restating `MAC_LAT` is only safe because it is **measured**: `pw_feeder` times the real
distance from `v_d && l_d` to `acc_valid` in simulation and fails if it is not `MAC_LAT`,
and `mac_lane_tb`, `pe_array_tb` and `pw_feeder_tb` each assert the same number as an
equality rather than a ceiling. That is what stops the formula and the structure drifting.

`dwconv3x3`, `conv3x3_std`, `dw_array` and `stem_array` still have a latency of **0** and no
clock port at all — Phase 2b and 2c change that. A-2 is the observation that a zero cannot be
written down in a port list, so making it non-zero has no compile-time witness.

---

## 2. Per-module pipeline inventory

### `mac_lane` / `pe_array` (pointwise MAC)

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `prod[]` product register | `mac_lane.v` | 1 stage | one per tap, `PROD_W = 2*DATA_W` wide (**L-9**) |
| `node[]` adder tree | `mac_lane.v` | `clog2(TN)` = 4 stages | balanced, one register per level, `TREE_W = PROD_W + LEVELS` (**L-1**) |
| `acc` accumulate | `mac_lane.v` | 1 stage | the only stage `valid` gates |
| `v_sr`/`f_sr`/`l_sr` control shift register | `mac_lane.v` | `CTRL_LAT = 1 + LEVELS` = 5 | **free-running**, because the tree is (**L-2**) |
| `armed` sticky bit | `mac_lane.v` | — | **L-10**: a `last` with no preceding `first` no longer announces a stale sum |
| `assign done = lane_done[0]` | `pe_array.v` | lane 0 | all lanes in lockstep (**A-3**), now *checked* in simulation against all TM bits — which also gives the other TM−1 bits a reader (**A-6**) |

### `pw_feeder`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `v_d`/`f_d`/`l_d` control delay | `pw_feeder.v` | 1 stage | buffer read latency (1), **not** `MAC_LAT` |
| Tag pipeline `pix_sr[]` → `acc_pix`/`acc_oct` | `pw_feeder.v` | `TAG_LAT = 1 + MAC_LAT` = **7** (was 2) | stage 1 gated on `ag_valid` (the buffers it shadows are gated); stages 2..7 **free-running**, because `mac_lane`'s tree is |
| `drain` | `pw_feeder.v` | `DRAIN_CYC = MAC_LAT + OS_LAT` = **8** (was a literal 7) | derived: the distance from the `layer_done` cycle to the last write. `DRAIN_W = clog2(DRAIN_CYC+1)` = 4 bits. |
| `OS_LAT` parameter | `pw_feeder.v` | 2 | passed from `accel_top`; the drain is sized from it |

`ag_valid` → `acc_valid` is **7** (was 2); → `aw_en` in `pw_out` is **9** (was 4).

> The old header said "each tag stage advances on ITS OWN valid, never on the bare clock, or
> a stall would slide the tags past the data". That was right for a combinational array and is
> now **backwards** for the stages inside a pipelined one: `mac_lane`'s tree is not
> clock-enabled, so a held buffer output propagates through it every cycle and a
> valid-gated tag would fall behind. Only the buffer-read stage stays gated.

### `pw_out`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `aw_addr` counter on `q_valid` | `pw_out.v:135-139` | — | pure counter; no depth encoded (that is T-6: the tag is checked but not used to form the address) |
| `exp_pix`/`exp_oct` advance on `acc_valid` | `pw_out.v:144-166` | 0 | compares at `acc_valid`, i.e. before `OS_LAT` |

### `dw_array` / `dw_feeder`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `dw_array` has no clock/valid ports | `dw_array.v:47-56` | 0 | **A-2** — the latency is expressed as the *absence* of ports |
| `assign os_acc_valid = win_valid` | `dw_feeder.v:274` | 0 | `dw_array` latency. One line, no width mismatch if it goes wrong. |
| `v_d1`/`real_d1`/`grp_d1` | `dw_feeder.v:201-217` | 1 stage | pool read latency |
| `grp_d2` | `dw_feeder.v:249-252` | 1 more | `line_buffer` window latency (1) |
| `grp_d3`, `grp_d4` | `dw_feeder.v:284-293` | 2 more | `OS_LAT` — `grp_d4` must be aligned with `q_valid` |
| `drain <= 3'd7` | `dw_feeder.v:399-405` | 7 | ≥ 1 + 1 + `OS_LAT` = 3 today |

`step` → `win_valid` is **2**; → `aw_en` is **4**. Total group-tag depth: **4** (`grp_d1..d4`).

### `stem_array` / `stem_feeder`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `stem_array` has no clock/valid ports | `stem_array.v:56-66` | 0 | same shape as A-2, one level up |
| `v_d1`/`real_d1`/`y_d1`/`x_d1` | `stem_feeder.v:170-183` | 1 stage | image read latency |
| `win_q` latch on `win_valid && !sweeping` | `stem_feeder.v:202-217` | 1 stage | `line_buffer` latency; sweep starts the cycle AFTER `win_valid` |
| `wa_oct = win_valid && !sweeping ? 0 : oct+1` | `stem_feeder.v:221-222` | weights lead by 1 | `wgt_buffer` read latency (1) vs the sweep start |
| `oct_d1`, `oct_d2` | `stem_feeder.v:263-267` | 2 stages | `OS_LAT` — `oct_d2` must align with `q_valid` |
| `wr_go <= entry_done` | `stem_feeder.v:286-301` | 1 stage | lets the last `asm` fold land before the entry is stored |
| `drain <= 4'd15` (4-bit counter) | `stem_feeder.v:370-376` | 15 | ≥ sweep (`n_oct`) + `OS_LAT` + 1 ≈ 7 today |
| `busy` includes `sweeping` | `stem_feeder.v:386` | — | the sweep is the reason `run` alone is not enough |

`adv` → `win_valid` is **2**; → first `os_acc_valid` is **3**; → `aw_en` is **9**.

> Doc drift found while building this table (not a review finding): the header's pipeline
> sketch says "C+8 one full 32-channel entry written". `wr_go` is `entry_done` delayed one
> cycle, so the write is at **C+9**. The sketch means `entry_done`.

### `res_feeder`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `sav_valid` / `sav_sl` | `res_feeder.v:197-207` | 1 stage | pool read latency |
| `tgt0/1/2`, `wa0/1/2`, `ws0/1/2` delay line | `res_feeder.v:168-188` | **3 stages** | push is 1 cycle ahead of `sav_valid`, then `OS_LAT` → 1 + 2 |
| `drain <= 3'd6` | `res_feeder.v:263-269` | 6 | ≥ 1 + `OS_LAT` = 3 today |

Read issued → `aw_en` is **4** (`ph=0` issue, `ph=1` target, `sav_valid`, +`OS_LAT`).

### `gap_feeder`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `v_d1`/`first_d1`/`last_d1`/`sl_d1` | `gap_feeder.v:147-162` | 1 stage | pool read latency |
| `sl_d2` | `gap_feeder.v:188-192` | 1 more | `avgpool` latency = `MAC_LAT` |
| `sl_d3`, `sl_d4` | `gap_feeder.v:211-219` | 2 more | `OS_LAT` — `sl_d4` must align with `q_valid` |
| `drain <= 3'd7` | `gap_feeder.v:231-237` | 7 | ≥ 1 + `MAC_LAT` + `OS_LAT` = 4 today |

`run` → `sums_ready` is **2**; → `aw_en` is **4**. Total slice-tag depth: **4** (`sl_d1..d4`).

> **Zero margin, and it is a Phase 2 trap.** `avgpool`'s `acc` holds a channel's final sum
> for **exactly one cycle**: the next slice's first sample arrives with `first=1` on the very
> next cycle and clears it. `out_stage`'s stage A captures it on that one cycle. Nothing
> between `sums_ready` and `acc_q` may gain a cycle without also holding the sum — if L-3's
> new stage 1 is inserted *before* the capture rather than after it, every pooled channel
> becomes the next channel's first sample. The review calls this handoff "correct (zero
> margin)" under Part A and does not carry the consequence into Phase 2.

### `out_stage` / `rq_bank` / `param_buffer`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `acc_q` / `vA` stage A | `out_stage.v:88-98` | 1 stage | `param_buffer` read latency (1) must match it |
| `param_buffer` registered read | `param_buffer.v:105-110` | 1 stage | fixed by the memory style |
| `rq_bank` `q_valid <= en` | `rq_bank.v:118-122` | 1 stage | `requantize`'s output register. **L-3 grows this to 4.** |
| `requantize` output register | `requantize.v:141-145` | 1 stage | the whole multiply→round→shift→clamp chain is in front of it |
| `act` / `relu6_qmax` arrive combinationally | `out_stage.v:63-64`, `rq_bank.v:70-71` | 0 stages | **L-7** — per-channel params are delayed 1, these are not. Breaks the moment L-3 adds stages. |
| `bias_add` combinational | `bias_add.v:42` | 0 stages | in `requantize`'s timing cone; L-12 folds it into L-3's new stage 1 |

### `logit_out`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `lv <= acc_valid` | `logit_out.v:144-149` | **1 stage** | its own `requantize` output register — **not** `OS_LAT`. This path is a second copy of the requantize datapath (T-8). |
| `argmax_valid <= lv` | `logit_out.v:168-177` | 1 more | combinational 4-way argmax over `logits` |

`logits_valid` and `argmax_valid` are one cycle apart by construction.

### `top_seq` / `accel_top`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `GAP_CYC = 4` | `top_seq.v:84`, `accel_top.v:117` | 4 (⇒ 5 idle cycles) | **T-10**: asserted, not derived. Nominally covers the worst feeder drain; nothing ties it to one. |
| `S_FETCH` word counter `fw` | `top_seq.v:298-302` | 8 cycles | instruction width, not a datapath latency |
| `S_WAIT` → `S_RUN` on `op_busy` rising | `top_seq.v:324` | — | a feeder cannot raise `busy` until the cycle after `op_start` |
| `WDOG_W = 20` (T-2, Phase 1) | `top_seq.v`, `accel_top.v` | 2²⁰ cycles | **derived**: 10.4× the longest legitimate op (the stem, 100,801 cycles) and 41× the worst weight fill (25,600). Recompute if a layer gets longer, not if a latency changes. |

### Memories — read latency 1, assumed everywhere

`act_buffer`, `wgt_buffer`, `param_buffer`, `img_buffer` are all registered-read, 1 cycle.
`line_buffer` adds 1 (its window register). Every `v_d1` above is paying for exactly one of
these. **None of them changes in Phase 2 as the review has it** — but one of them may have to,
and it is not on any list in the review:

> `WARNING: [Synth 8-6057] Memory: "mem_reg" ... implemented as Ultra-Ram has no pipeline`
> `registers. It is recommended to use pipeline registers to achieve high performance.`

`act_buffer`'s URAM is read with one register (`dout`) and no URAM **output** pipeline
register. At 25 ns that is free; at 4.000 ns a 52-URAM array read in one cycle is unlikely
to close, and the fix — `CASCADE_ORDER`/output register, i.e. read latency 1 → 2 — is a
latency change that moves **every feeder's stage-1 delay** (`v_d`, `v_d1`) and every tag
pipeline behind it. Whether it is needed is a measurement, and the 4.000 ns run is what
answers it; it is listed here so that it is not discovered in the middle of Phase 2.

---

## 3. What moves together — the Phase 2 checklist

Copied from the review's cross-cutting table and made concrete against the rows above.

| Trigger | Rows that change in the SAME commit |
|:--|:--|
| ~~**L-1/L-2** `mac_lane` gains `+LAT`~~ **DONE, Phase 2a** | ~~`pw_feeder` tag pipeline~~ 2 → **7**; ~~`pw_feeder` drain~~ 7 → **`MAC_LAT+OS_LAT`**; ~~`pe_array` `done` sourcing~~ (A-3 checked, unchanged until A-1); `avgpool` untouched, so `gap_feeder` `sl_d2` unchanged |
| **L-1/L-2** `dwconv3x3` gains clock + LAT | `dw_array` port list (A-2); `dw_feeder` `os_acc_valid = win_valid` → delayed by LAT; `grp_d2..d4` → +LAT stages; `dw_feeder` drain |
| **L-1/L-2** `conv3x3_std` gains clock + LAT | `stem_array` port list; `stem_feeder` `win_q` latch and sweep timing; `wa_oct` weight lead; `oct_d1/d2` → +LAT; `stem_feeder` drain |
| **L-3** `requantize` +3 (`OS_LAT` 2 → 5) | `rq_bank` `q_valid` depth; L-7 `act`/`relu6_qmax` pipelined inside `requantize`; `pw_feeder` drain; `dw_feeder` `grp_d3/d4` and drain; `stem_feeder` `oct_d1/d2` and drain; `res_feeder` delay line 3 → 3+3 and drain; `gap_feeder` `sl_d3/d4` and drain; `GAP_CYC`; `logit_out` `lv` |
| **L-12** absorbed | `bias_add` folds into L-3's new stage 1 |
| **A-1** registered broadcast | `pe_array` `done` from the last group; accumulator de-skew; `pw_feeder` tag depth grows by the group count |

**Every drain in the table is a hand-set constant with slack, not a derived value.** That is
why a too-small drain fails silently rather than at elaboration: today's values (7, 7, 15, 6, 7)
happen to have 3–8 cycles of margin, so a `+1` or `+2` latency change may pass the golden
vectors by luck and a `+3` may not. Phase 2 should derive each drain from the stage count it
covers, which also settles T-10's `GAP_CYC`.

---

## 4. What Phase 1 added, and why none of it is in the table above

Phase 1 changed no latency. Every row in sections 1–3 has the same value it had
at commit `716ea8e`. What it added is **witnesses for the rows**, which is the part
that matters for Phase 2:

| Check | Where | What it watches |
|:--|:--|:--|
| C-2 address witness | `dw_feeder`, `stem_feeder` | the writeback counter against `line_buffer`'s own `out_x`/`out_y`. **This is the check that will catch a wrong tag depth in Phase 2** — a feeder whose `grp_dN`/`oct_dN` depth is off by one writes to the wrong entry, and this says so by name instead of producing a shifted feature map. |
| T-3 tag comparator | `pw_out` | the pointwise result's `(pix, oct)` against the emission order, now terminating the run |
| L-12 bias range | `rq_bank`, `logit_out` | `acc + bias` at full width against ACC_W |
| L-4/L-5 shift guard | `requantize` | `shift ≥ 1 OR m0 == 0`, and `shift ≤ ROUND_W-1` |
| C-4 collision trap | `act_buffer` | same-address read/write, which simulates optimistically |
| C-6 depth guards | `wgt_buffer` (elab), `pw_feeder` (runtime), `gen_program.py` (build) | the weight rectangle against the address width |
| T-1/T-2 | `top_seq`, `gen_program.py` | the instruction ceiling and three hang causes |

Two of these are directly load-bearing for Phase 2:

- **C-2 is the tag-depth oracle.** Section 3's checklist says "a golden-vector failure
  means a tag pipeline or a `*_valid` depth is wrong". Before Phase 1 that meant
  bisecting by hand. Now `dw_feeder` and `stem_feeder` name the pixel where the counter
  and the window disagree, which is exactly the symptom a wrong `grp_dN`/`oct_dN` depth
  produces. `pw_feeder` already had this in the form of `pw_out`'s tag comparator; T-3
  made its verdict terminating.
- **Both C-2 checks are qualified by the feeder's own `busy`**, and that is a Phase 2
  constraint in itself. `os_q_valid` is broadcast to all five feeders (T-9), so an idle
  feeder's output pipeline advances on another op's results; it is harmless only because
  `start` resets the counters. If Phase 2 changes a drain such that a feeder's `busy`
  drops before its last result lands, these checks stop covering that result — so `busy`
  and the real pipeline depth must stay consistent, which is what the drain rows are for.

## 5. A testbench idiom that Phase 2a broke, and will break again

`wait (!busy)` appeared in all six datapath testbenches, and it is **delta-cycle sensitive**.
`addr_gen`'s `run` drops and `layer_done` rises on the SAME clock edge, and `busy` is a
continuous OR of the two, so inside the non-blocking update region `busy` can momentarily
read 0. A real consumer samples `busy` at a clock edge and never sees it — `top_seq`'s
`S_RUN: if (!op_busy)` is inside `always @(posedge clock)`, so the RTL is fine.

It went unnoticed while the pipeline drained in 1–2 cycles, because the fixed
`repeat (8) @(negedge clock)` after it covered the difference. `MAC_LAT = 6` made the drain
8 cycles and `pw_datapath_tb` started losing **the last write of the layer** — 12,543 of
12,544 pixels, every one of them correct, which is exactly the shape of failure this phase
was warned to expect. All six now sample it the way hardware does:

```systemverilog
do @(negedge clock); while (busy);
```

Phase 2b and 2c grow the depthwise and stem latencies, so the same trap was waiting there
twice more.

## 6. Baseline facts this table was measured against

- `TM=32`, `TN=16`, `TC=16`, `TS=8`, `ACC_W=26`, `SEL_W=1`, `GAP_CYC=4`.
- Drains: `pw_feeder` 7 (3-bit), `dw_feeder` 7 (3-bit), `stem_feeder` 15 (4-bit),
  `res_feeder` 6 (3-bit), `gap_feeder` 7 (3-bit).
- Feeder input-to-writeback latency: pointwise 4, depthwise 4, residual 4, pooling 4,
  stem 9.
- All 31 testbenches pass, including `accel_tb` at 6,895,780 elements bit-exact over 64 ops.
