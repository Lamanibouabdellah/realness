# BMAD v6.12 - OpenRouter Free Model Mapping

Generated automatically by setup-omp-bmad.sh.

All selected models are verified free variants.

## OMP workload assignments

| OMP role | Model |
|---|---|
| default | `cohere/north-mini-code:free` |
| plan | `nvidia/nemotron-3-ultra-550b-a55b:free` |
| slow | `nvidia/nemotron-3-ultra-550b-a55b:free` |
| smol | `nvidia/nemotron-3.5-lightning:free` |
| commit | `nvidia/nemotron-3.5-lightning:free` |
| task | `cohere/north-mini-code:free` |
| advisor | `nvidia/nemotron-3-ultra-550b-a55b:free` |
| vision | `nvidia/nemotron-3.5-super-vl:free` |

## BMAD persona recommendations

| BMAD persona | Recommended OMP workload |
|---|---|
| Analyst | plan / slow |
| Product Manager | plan / slow |
| Architect | plan / slow |
| UX Designer | plan / slow |
| Scrum Master | plan / smol |
| Developer | default / task |
| QA | default / task |

## Important distinction

BMAD personas are methodology agents, not native OMP model roles.

This mapping documents the recommended model workload. It does not
automatically change the active model when BMAD activates a persona.

Use the OMP model-role picker or the appropriate OMP workload to
select the configured model.

## Free fallbacks

### code

- `particle-ai/particle-1:free`
- `recursive/flint-v1.0:free`

### reasoning

- `baidu/ernie-5.5-flash-preview:free`

### fast

- `particle-ai/particle-1:free`

### vision

- No verified alternative currently available.


## Cost policy

Only model IDs ending in `:free` are configured.

The project `enabledModels` allowlist contains only models verified
as free when this script was executed.

OpenRouter free models are subject to provider availability and
rate limits. A free model can become unavailable or be removed
from the catalog. Re-run the installer to refresh the selection.
