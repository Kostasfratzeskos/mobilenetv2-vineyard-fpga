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
Line references updated after Phase 1 (`6efb02a`); the VALUES were unchanged there, because
Phase 1 changed no latency. Phases 2a–2d changed the values, and section 6 is the before/after.
The per-module tables cite files rather than line numbers now — four phases of edits proved the
line numbers go stale faster than anyone updates them, and a stale reference is worse than none.

---

## 1. The two latencies everything else is derived from

| Name | Where | Value | What it is |
|:--|:--|--:|:--|
| `MAC_LAT` | `mac_lane` | **6** (was 1) | `valid` → `acc` final and `done` high. Now `1 + clog2(TN) + 1`: one registered product stage, `clog2(TN)=4` adder-tree levels, one accumulate stage (**L-1**, Phase 2a). |
| `DW_LAT` | `dwconv3x3` / `dw_array` | **5** (was 0) | `win`/`valid` → `acc`/`valid_out`. `1 + clog2(K*K)`: one product stage plus 4 tree levels, and **no** accumulate stage — a depthwise window completes in one pass (**L-1**, Phase 2b). |
| `ST_LAT` | `conv3x3_std` / `stem_array` | **6** (was 0) | `win`/`valid` → `acc`/`valid_out`. `1 + clog2(K*K*3)` = `1 + clog2(27)`: one product stage plus 5 tree levels, no accumulate stage (**L-1**, Phase 2c). |
| `ARR_LAT` | `pe_array` | **7** (was = `MAC_LAT`) | `valid` → `done`/`acc` for the ARRAY, as opposed to the lane. A-1 registers `a`, `w` and the controls at the array input, so `ARR_LAT = 1 + MAC_LAT` (**A-1**, DD-022, Phase 3). This is the number every `pw_feeder` constant is sized from now; `MAC_LAT` is the intermediate it derives from. |
| `RQ_LAT` | `requantize` | **4** (was 1) | `en` → `q_valid`. Four register stages: `in_data` (absorbing `bias_add`), the M0 product, round+shift, clamp (**L-3**, Phase 2d). |
| `OS_LAT` | `out_stage` | **5** (was 2) | `acc_valid` → `q_valid`. Stage A registers `acc_q`/`vA` and issues the parameter read (1), then `RQ_LAT` — so `1 + RQ_LAT`, and it moves whenever `requantize` does (**L-3**, Phase 2d). |

Both are `localparam`s now, derived rather than written down: `MAC_LAT` from `TN` in
`mac_lane` (and restated by the same arithmetic in `pw_feeder`, which is the only module
that needs it and cannot see into the array), `OS_LAT` as a **parameter** of `accel_top`
passed down to each feeder, because `out_stage` is instantiated at the top and a feeder
cannot see its depth either.

Restating `MAC_LAT` is only safe because it is **measured**: `pw_feeder` times the real
distance from `v_d && l_d` to `acc_valid` in simulation and fails if it is not `MAC_LAT`,
and `mac_lane_tb`, `pe_array_tb` and `pw_feeder_tb` each assert the same number as an
equality rather than a ceiling. That is what stops the formula and the structure drifting.

A-2 was the observation that a zero cannot be written down in a port list, so making it
non-zero has no compile-time witness. `dw_array` and `stem_array` both have `clock`, `rst_n`,
`valid` and `valid_out` now, so their latency is a wire the feeder connects rather than an
equality the feeder asserts.

`OS_LAT` is the one that cannot be a wire: `out_stage` is instantiated in `accel_top`, not
inside the feeders, so each feeder is told its depth by parameter. That is the single most
load-bearing number in this file — **five** modules size a tag pipeline and a drain from it —
and it is why Phase 2d touched every feeder. Every default is the true value (5) in every
module, so a standalone testbench that omits the override cannot silently run a shallower
pipeline than `accel_top` builds.

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
| `a_q`/`w_q`/`v_q`/`f_q`/`l_q` input register | `pe_array.v` | 1 stage | **A-1 (DD-022 option B)**: the one register that separates the activation read from the fanout-115 broadcast. `a` and `w` move together or the lanes pair operands from different tiles — a wrong VALUE, not a wrong time. |
| `assign done = lane_done[0]` | `pe_array.v` | lane 0 | all lanes in lockstep (**A-3**), *checked* in simulation against all TM bits — which also gives the other TM−1 bits a reader (**A-6**). **A-1 did not break this**: the input register is in front of ALL lanes, so they still see the same controls on the same cycle. The grouped-broadcast de-skew A-3 was written for never became necessary. |

### `pw_feeder`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `v_d`/`f_d`/`l_d` control delay | `pw_feeder.v` | 1 stage | buffer read latency (1), **not** `MAC_LAT` |
| Tag pipeline `pix_sr[]` → `acc_pix`/`acc_oct` | `pw_feeder.v` | `TAG_LAT = 1 + ARR_LAT` = **8** (was 2) | stage 1 gated on `ag_valid` (the buffers it shadows are gated); stages 2..8 **free-running**, because `mac_lane`'s tree is |
| `drain` | `pw_feeder.v` | `DRAIN_CYC = ARR_LAT + OS_LAT` = **12** (was a literal 7) | derived: the distance from the `layer_done` cycle to the last write. `DRAIN_W = clog2(DRAIN_CYC+1)` = 4 bits. |
| `OS_LAT` parameter | `pw_feeder.v` | **5** | passed from `accel_top`; the drain is sized from it |

`ag_valid` → `acc_valid` is **8** (was 2); → `aw_en` in `pw_out` is **13** (was 4).
Phase 2d moved only the second (→ 12): `TAG_LAT` stops at `acc_valid`, and everything after it
is `OS_LAT`. Phase 3 moved both by one more, because A-1's register is in front of everything.

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
| `dw_array` `valid` → `valid_out` | `dw_array.v` | `DW_LAT` = **5** | **A-2 fixed**: one shift register for all TC channels, depth derived from K |
| `assign os_acc_valid = arr_valid` | `dw_feeder.v` | — | was `= win_valid`, i.e. 0. Now a **wire from the array**, so the latency cannot be asserted wrongly |
| `v_d1`/`real_d1`/`grp_d1` | `dw_feeder.v` | 1 stage | pool read latency |
| `grp_sr[]` group tag | `dw_feeder.v` | `GRP_WR = 2 + DW_LAT + OS_LAT` = **12** (was 4) | one shift register; `grp_arr` at `GRP_ARR = 2+DW_LAT` = 7 feeds `acc_wide` and the parameter address, `grp_wr` at 12 feeds the write |
| `ox_sr`/`oy_sr` C-2 witness | `dw_feeder.v` | `WIT_LAT = DW_LAT + OS_LAT` = **10** (was 2) | capturing a `line_buffer` output already costs one stage |
| `drain` | `dw_feeder.v` | `DRAIN_CYC = 1 + DW_LAT + OS_LAT` = **11** (was a literal 7) | derived: `layer_done` cycle → last write |
| `OS_LAT` parameter | `dw_feeder.v` | **5** | passed from `accel_top` |

`step` → `win_valid` is **2** (unchanged, that is `line_buffer`); → `arr_valid` is **7**
(was 2); → `aw_en` is **12** (was 4).

> Every depth above is declared in ONE place at the top of `dw_feeder`, next to `DW_LAT`,
> because they all move together. `dw_feeder` also **measures** the real `win_valid` →
> `arr_valid` distance in simulation and names all four derived constants in the failure
> message if it is not `DW_LAT` — which is what makes restating `DW_LAT` there safe.

### `stem_array` / `stem_feeder`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `stem_array` `valid` → `valid_out` | `stem_array.v` | `ST_LAT` = **6** | **A-2 shape fixed**: `clock`, `rst_n`, `valid`, `valid_out`, one shift register for all TS channels |
| `assign os_acc_valid = arr_valid` | `stem_feeder.v` | — | was `= sweeping`, i.e. 0. Now a **wire from the array** |
| `v_d1`/`real_d1`/`y_d1`/`x_d1` | `stem_feeder.v` | 1 stage | image read latency |
| `win_q` latch on `win_valid && !sweeping` | `stem_feeder.v` | 1 stage | `line_buffer` latency; sweep starts the cycle AFTER `win_valid`. **UNCHANGED by Phase 2b/2c/2d** — the review lists it as moving and measurement says it does not. |
| `wa_oct = win_valid && !sweeping ? 0 : oct+1` | `stem_feeder.v` | weights lead by 1 | `wgt_buffer` read latency (1) vs the sweep start. Also **unchanged**. |
| `oct_sr[]` octet tag | `stem_feeder.v` | `OCT_WR = ST_LAT + OS_LAT` = **11** (was 2) | one shift register; `oct_arr` at `OCT_ARR = ST_LAT` = 6 feeds `acc_wide` and the parameter address, `oct_wr` at 11 feeds the write |
| `ox_live` → `ox_sr[]` → `ox_e` C-2 witness | `stem_feeder.v` | rides `oct_sr` | the witness changed **shape**, not just depth: the hold was being overwritten before `entry_done` |
| `wr_go <= entry_done` | `stem_feeder.v` | 1 stage | lets the last `asm` fold land before the entry is stored |
| `drain` | `stem_feeder.v` | `DRAIN_CYC = ST_LAT + OS_LAT + 1` = **12** (was a literal 15) | derived; `DRAIN_W = clog2(DRAIN_CYC+1)` = 4 bits. `busy` already covers the sweep via `sweeping`. |
| `busy` includes `sweeping` | `stem_feeder.v` | — | the sweep is the reason `run` alone is not enough |
| `OS_LAT` parameter | `stem_feeder.v` | **5** | passed from `accel_top` |

`adv` → `win_valid` is **2**; → first `os_acc_valid` is **7**; the write is `OCT_WR` + the
`wr_go` cycle behind the octet that produced it.

> Doc drift found while building this table (not a review finding): the header's pipeline
> sketch says "C+8 one full 32-channel entry written". `wr_go` is `entry_done` delayed one
> cycle, so the write is at **C+9**. The sketch means `entry_done`.

### `res_feeder`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `sav_valid` / `sav_sl` | `res_feeder.v` | 1 stage | pool read latency |
| `tgt_sr`/`wa_sr`/`ws_sr` delay line | `res_feeder.v` | `TGT_LAT = 1 + OS_LAT` = **6** (was 3 named registers) | push is 1 cycle ahead of `sav_valid`, then `OS_LAT`. Three names would have become six — a shift register of a derived depth instead. |
| `drain` | `res_feeder.v` | `DRAIN_CYC = OS_LAT` = **5** (was a literal 6) | `sav_valid` is high in the SAME cycle as `layer_done`, so the last write is `OS_LAT` after it |
| `OS_LAT` parameter | `res_feeder.v` | **5** | passed from `accel_top` |

Read issued → `aw_en` is **7** (`ph=0` issue, `ph=1` target, then `OS_LAT`).

### `gap_feeder`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `v_d1`/`first_d1`/`last_d1`/`sl_d1` | `gap_feeder.v` | 1 stage | pool read latency |
| `sl_d2` | `gap_feeder.v` | 1 more | `avgpool` latency, which is **1** — it is a plain adder, not a MAC, and L-1 did not touch it |
| `sl_sr[0:OS_LAT-1]` | `gap_feeder.v` | `OS_LAT` = **5** more (was 2 named registers) | `sl_sr[OS_LAT-1]` must align with `q_valid` |
| `armed` sticky bit | `avgpool.v` | — | **L-10**, same fix as `mac_lane`: a `last` with no preceding `first` no longer announces a stale sum |
| `drain` | `gap_feeder.v` | `DRAIN_CYC = 1 + OS_LAT` = **6** (was a literal 7) | derived: `sums_ready` is one cycle after the `layer_done` cycle, the write `OS_LAT` after that |
| `OS_LAT` parameter | `gap_feeder.v` | **5** | passed from `accel_top` |

`run` → `sums_ready` is **2**; → `aw_en` is **7**. Total slice-tag depth: **7**.

> **Zero margin — the Phase 2d trap, and how it was avoided.** `avgpool`'s `acc` holds a
> channel's final sum for **exactly one cycle**: the next slice's first sample arrives with
> `first=1` on the very next cycle and clears it. `out_stage`'s stage A captures it on that
> one cycle. Nothing between `sums_ready` and `acc_q` may gain a cycle without also holding
> the sum. L-3's three new stages all land **after** that capture — stage A registers `acc_q`,
> `bias_add` is combinational on `acc_q`, and `requantize`'s stage 1 registers *its* output —
> so the one-cycle handoff is untouched and every added cycle is behind a register that
> already held the value. Had stage 1 gone in front of the capture instead, every pooled
> channel would have become the next channel's first sample. The review calls this handoff
> "correct (zero margin)" under Part A and does not carry the consequence into Phase 2.

### `out_stage` / `rq_bank` / `param_buffer`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `acc_q` / `vA` stage A | `out_stage.v` | 1 stage | `param_buffer` read latency (1) must match it |
| `param_buffer` registered read | `param_buffer.v` | 1 stage | fixed by the memory style |
| `requantize` pipeline | `requantize.v` | `RQ_LAT` = **4** (was 1) | stage 1 `in_data` (which is `bias_add`'s output, **L-12** absorbed), stage 2 the M0 product, stage 3 round+shift, stage 4 clamp. `en_sr` of depth `RQ_LAT` drives the new `q_valid` output. |
| `rq_bank` `q_valid` | `rq_bank.v` | `assign q_valid = lane_valid[0]` | **taken from `requantize`'s own output**, not a local register, so the bank cannot disagree with the module about its own depth. Lockstep across the TM lanes is checked in simulation. |
| `act` / `relu6_qmax` delayed inside `requantize` | `requantize.v` | `act_d1..d3`, `qmax_d1..d3` | **L-7 fixed** — they are consumed at stage 4 and now arrive there. `m0_d1` and `sh_d1`/`sh_d2` likewise ride to the stage that uses them. |
| `bias_add` combinational | `bias_add.v` | 0 stages | **L-12 absorbed**: it is now in front of `requantize`'s stage 1 register rather than in front of a multiply, so it costs a register-to-register hop of its own instead of extending the M0 path |

### `logit_out`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `lv = cls_valid[0] & lv_gate` | `logit_out.v` | `RQ_LAT` = **4** (was 1) | taken from its `requantize`'s own `q_valid`, the same way `rq_bank` now does. This path is a second copy of the requantize datapath (**T-8**) and after Phase 2c it is on the critical path, so it must not be able to drift from the original. `lv_gate` keeps `start` forcing it low. |
| `argmax_valid <= lv` | `logit_out.v` | 1 more | combinational 4-way argmax over `logits` |

`logits_valid` and `argmax_valid` are one cycle apart by construction. Note that this path
does **not** go through `out_stage`, so it is `RQ_LAT` and not `OS_LAT`: there is no stage-A
capture, because `pw_feeder`'s accumulators are read directly. T-8 proposes removing the
duplicate; until then the two depths are different numbers for a real reason.

### `top_seq` / `accel_top`

| Constant / structure | File:line | Value | Depends on |
|:--|:--|--:|:--|
| `GAP_CYC = OS_LAT` | `top_seq.v`, `accel_top.v` | **5** (was a literal 4) | **T-10 fixed**, and the honest derivation is that it is now *redundant*: every feeder's `busy` covers its own drain, and since Phase 2 every one of those drains is derived. Kept as a second line of defence, at one requantize pipeline's worth of cycles, and it **moves with `OS_LAT`**. `OS_LAT` must be declared above it in `accel_top`'s parameter list — Verilog-2001 resolves a parameter list strictly top to bottom, so the derived one first is a compile error. |
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

> **Measured after Phase 2d: it is needed, and it is now THE critical path.** All 25 of the
> worst post-route paths are one path, and synthesis agrees with route on it:
>
>     u_act/mem_reg_1_uram_13/CLK
>       -> u_pwf/u_array/lane[10].u_lane/prod_reg[12]/DSP_OUTPUT_INST/ALU_OUT[10]
>     6.066 ns (logic 4.179, route 1.887), 13 logic levels, WNS -2.126 at 4.000 ns
>
> Nothing in `requantize`, `out_stage` or `logit_out` appears in the worst-path list any
> more — in Phase 2c both the synthesis and the post-route worst path ended in a
> `quantized_reg`. So the review's 43 findings no longer contain the bottleneck, and this
> row does. It is a latency change of the same kind as L-1 and L-3, which means it gets its
> own phase and its own pass down this table rather than being folded into one.

---

## 3. What moves together — the Phase 2 checklist

Copied from the review's cross-cutting table and made concrete against the rows above.

| Trigger | Rows that change in the SAME commit |
|:--|:--|
| ~~**L-1/L-2** `mac_lane` gains `+LAT`~~ **DONE, Phase 2a** | ~~`pw_feeder` tag pipeline~~ 2 → **7**; ~~`pw_feeder` drain~~ 7 → **`MAC_LAT+OS_LAT`**; ~~`pe_array` `done` sourcing~~ (A-3 checked, unchanged until A-1); `avgpool` untouched, so `gap_feeder` `sl_d2` unchanged |
| ~~**L-1/L-2** `dwconv3x3` gains clock + LAT~~ **DONE, Phase 2b** | ~~`dw_array` port list (A-2)~~; ~~`os_acc_valid = win_valid`~~ → a wire from the array; ~~`grp_d2..d4`~~ → one `grp_sr[]` at `GRP_WR`=9; ~~drain~~ → `1+DW_LAT+OS_LAT`; **and the C-2 witness, which the review's table does not list** |
| ~~**L-1/L-2** `conv3x3_std` gains clock + LAT~~ **DONE, Phase 2c** | ~~`stem_array` port list~~; ~~`os_acc_valid = sweeping`~~ → a wire; ~~`oct_d1/d2`~~ → one `oct_sr[]` at `OCT_WR`=8; ~~drain~~ → `ST_LAT+OS_LAT+1`; **the C-2 witness changed shape, not just depth**. `win_q`, the sweep and the `wa_oct` weight lead are UNCHANGED — the review lists them as moving and measurement says they do not. |
| ~~**L-3** `requantize` +3 (`OS_LAT` 2 → 5)~~ **DONE, Phase 2d** | ~~`rq_bank` `q_valid` depth~~ → `requantize`'s own output; ~~L-7 `act`/`relu6_qmax`~~ pipelined inside `requantize`; ~~`pw_feeder` drain~~ → 11; ~~`dw_feeder` `grp_d3/d4` and drain~~ → `GRP_WR`=12, `WIT_LAT`=10, drain 11; ~~`stem_feeder` `oct_d1/d2` and drain~~ → `OCT_WR`=11, drain 12; ~~`res_feeder` delay line~~ → `TGT_LAT`=6, drain 5; ~~`gap_feeder` `sl_d3/d4` and drain~~ → `sl_sr` of `OS_LAT`, drain 6; ~~`GAP_CYC`~~ → `OS_LAT`; ~~`logit_out` `lv`~~ → its `requantize`'s `q_valid` |
| ~~**L-12** absorbed~~ **DONE, Phase 2d** | ~~`bias_add` folds into L-3's new stage 1~~ — it feeds `requantize`'s stage-1 register instead of the M0 multiply |
| ~~**A-1** registered broadcast~~ **DONE, Phase 3** | Not what this row predicted. DD-022 measured the path first and put ONE register at `pe_array`'s input instead of a grouped chain, so: `done` stays on lane 0, there is **no accumulator de-skew**, and `pw_feeder`'s tag depth grew by exactly **1** (`TAG_LAT` 7 → 8, `DRAIN_CYC` 11 → 12) rather than by a group count. ~~`pe_array` `done` from the last group~~; ~~accumulator de-skew~~ — both dropped as unnecessary, see DD-022. |

**No drain in the table is a hand-set constant any more.** The five were `7, 7, 15, 6, 7`
with 3–8 cycles of unexplained margin — which is why a too-small drain failed silently
rather than at elaboration, and why a `+1` could pass the golden vectors by luck where a `+3`
would not. They are now `11, 11, 12, 5, 6`, each derived from the stages it covers, and every
counter width is `clog2(DRAIN_CYC + 1)` rather than a number that happened to fit. `GAP_CYC`
went the same way, which settles T-10.

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

## 6. Where the numbers stand, Phase 0 → Phase 2d

| | Phase 0 (`716ea8e`) | after Phase 2d |
|:--|--:|--:|
| `MAC_LAT` (`mac_lane`) | 1 | **6** |
| `DW_LAT` (`dwconv3x3`) | 0 | **5** |
| `ST_LAT` (`conv3x3_std`) | 0 | **6** |
| `RQ_LAT` (`requantize`) | 1 | **4** |
| `OS_LAT` (`out_stage`) | 2 | **5** |
| `GAP_CYC` | 4 (literal) | **`OS_LAT`** = 5 |
| `pw_feeder` drain | 7 (literal, 3-bit) | **11** (derived, 4-bit) |
| `dw_feeder` drain | 7 (literal, 3-bit) | **11** (derived, 4-bit) |
| `stem_feeder` drain | 15 (literal, 4-bit) | **12** (derived, 4-bit) |
| `res_feeder` drain | 6 (literal, 3-bit) | **5** (derived) |
| `gap_feeder` drain | 7 (literal, 3-bit) | **6** (derived) |
| Feeder input → writeback | pw 4, dw 4, res 4, gap 4, stem 9 | pw **12**, dw **12**, res **7**, gap **7**, stem `OCT_WR`+1 |

Unchanged throughout: `TM=32`, `TN=16`, `TC=16`, `TS=8`, `ACC_W=26`, `SEL_W=1`, and every
golden vector. All 31 testbenches pass at each phase boundary, including `accel_tb` at
6,895,780 elements bit-exact over 64 ops — which is the only reason the table above is
believable: not one of these numbers changed a value, only when it arrives.

## 7. What Phases 4 and 5 changed in this inventory

Neither phase changed a latency. What they changed is who is allowed to still be in flight, and
that belongs here because it is the other half of the same bookkeeping.

| Change | Effect on this table |
|:--|:--|
| **C-10** `flush` reaches stage B | `requantize` gained a `flush` that clears `en_sr`, so a flush now drops all `RQ_LAT` = 4 stages instead of only `out_stage`'s stage A. Before, a flush with a result latched produced a `q_valid` `RQ_LAT` cycles later - into whichever feeder had since been selected. The depths are unchanged; what changed is that `OS_LAT`'s worth of pipeline can now be emptied on demand. |
| **T-9** `q_valid` gated per feeder | `os_q_valid` no longer advances all five feeders' output pipelines on every result. The tag depths are unchanged, but an idle feeder's pipeline no longer moves at all, which is what the C-2 witnesses were relying on `busy` to compensate for. |
| **C-3** shape/base latched at start | No depth changes. It does mean every feeder's addresses are now stable for the whole layer INCLUDING the drain, which is what `base_out` needed - it is consumed `DRAIN_CYC` cycles after `run` drops. |
| **T-7** stem tile count derived | `st_n_oct` is `TM/TS` (a constant), not a load field. No latency, but it removes a runtime input from the sweep length, which `DRAIN_CYC = ST_LAT + OS_LAT + 1` is sized against. |

The one thing to carry forward: **C-10's flush and the drain counters do the same job from
opposite ends.** A drain keeps `busy` high until the pipeline empties itself; a flush empties it
immediately. If a future change makes them disagree - a flush shorter than the pipeline, or a
drain that stops before it - the symptom is a write from one op landing during another, which is
exactly what C-10 was.
