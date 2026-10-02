# Visual Documentation for a Layered Terraform Monorepo: Tools, MCP Servers and an Executable Plan for Claude Code

**Recommendation: generate per-layer diagrams in CI with TerraVision, working from each layer's `terraform plan` JSON. Add a small script-generated D2 overview of how the foundation and app layers connect, and use the official draw.io MCP server only for curated, presentation-grade diagrams.** Of the Terraform-native visualizers checked for this report, TerraVision is the only one that is actively maintained, covers AWS, Azure and GCP with official icons, and outputs SVG, PNG, editable `.drawio` and an MCP server. Most of the well-known alternatives (Rover, Blast Radius, Pluralith) are dormant or abandoned.

## TL;DR

- **Primary engine: TerraVision** (AGPL-3.0, latest v0.51.1 on 1 October 2026). It reads `terraform plan` output for each layer and produces SVG/PNG plus editable draw.io files. It has a GitHub Action, a Docker image and an MCP server/agent skill for Claude Code. Run it once per root module (foundation, app-a, app-b) in plan-file mode so CI needs no extra cloud access.
- **Overview layer: generate it, don't draw it.** A short script parses each layer's `terraform_remote_state` and `output` blocks and writes a D2 (or Structurizr) diagram showing foundation to app-layer dependencies. That fixes the main weakness of every Terraform visualizer: none of them understands cross-state relationships. Mermaid `architecture-beta` works too, but GitHub does not render its custom cloud icons natively.\[1\]
- **MCP servers help with authoring, not with keeping things current.** The official draw.io MCP (`@drawio/mcp`, released 3 February 2026), the official Excalidraw MCP, the Lucid MCP and HashiCorp's `terraform-mcp-server` are all usable from Claude Code.\[2\]\[3\]\[4\] None of them reads Terraform state and produces a diagram on its own. The AWS Diagram MCP server is deprecated and has been yanked from PyPI. Use these servers for one-off curated diagrams and let CI own accuracy.

## Key Findings

1. **Terraform-native tools differ sharply in health.** TerraVision is in active development: 775 commits, 1.6k stars and 176 forks on its GitHub repo as of 2 October 2026, and releases through June to October 2026 (OpenTofu support, a native draw.io emitter, AI annotations). Inframap (MIT) still exists but is only lightly maintained. Rover (MIT, 3.3k stars) was last pushed on 13 July 2024 according to the ecosyste.ms index, and its Docker image was last updated about four years ago. Blast Radius is abandoned: it is pinned to Terraform 0.12.3 and its Docker image is over six years old.\[5\]\[6\]\[7\] Pluralith is effectively dead: last CLI update July 14, 2023, plus an open June 2025 issue titled "This project is Dropped? Why?".\[8\]\[9\]
2. **No tool natively models a multi-state layered repo.** Every tool works on one root module or one state file at a time. The connections between foundation and app layers (through remote state, data sources or outputs) have to be added either by a generated overview or by annotations.
3. **Plan JSON is the best input format.** It resolves `count`, `for_each`, conditionals and modules, which raw HCL cannot. You can also produce it in an existing pipeline step and render it later without credentials.\[10\] State files show what is actually deployed but carry secrets. Raw HCL needs no backend but cannot resolve dynamic constructs.
4. **Hand-drawn or MCP-generated diagrams drift unless CI regenerates or checks them.** The workable pattern is generated artifacts committed next to the code, with a CI job that regenerates them and fails on unexpected diffs.

## Details

### 1. Tools that generate diagrams from Terraform

| Tool | Input | Providers | Outputs | Status (Oct 2026) | License | Multi-layer handling |
|---|---|---|---|---|---|---|
| **TerraVision** (patrickchugh/terravision) | Runs `terraform plan`, or takes a pre-generated `plan.json` plus `graph.dot`. Also accepts a JSON graph | AWS, Azure, GCP with official icons | PNG, SVG, editable `.drawio`, interactive HTML, JSON graph data | **Active.** v0.51.1 on 1 October 2026; v0.42.0 (OpenTofu) on 6 June 2026\[11\]\[12\] | AGPL-3.0 | One root module per run. `--workspace` and `--varfile` flags; Terragrunt multi-module auto-detection\[13\] |
| **Inframap** (cycloidio/inframap) | tfstate (v3/v4) or HCL\[14\] | All providers, with provider-specific simplification for only a few (AWS among them) | DOT only (render with Graphviz) | **Low activity.** Latest tag v0.8.1; v0.8.0 published June 2024 | MIT\[15\] | One state or directory per run; `terraform state pull \| inframap generate` works with any backend. Grouping still listed as under investigation\[14\]\[16\] |
| **terraform graph** (built-in) | Config or saved plan | Any | DOT | Maintained with Terraform | BUSL (Terraform) | Per root module. A dependency graph, not an architecture diagram\[17\] |
| **Rover** (im2nguyen/rover) | Generates or reads plan JSON (`-planJSONPath`)\[18\] | Any (generic) | Interactive local web UI on :9000; SVG via `-genImage`\[19\]\[20\] | **Dormant** (v0.3.x; Docker image about 4 years old) | MIT | Nested modules supported; no multi-state support |
| **Blast Radius** (28mm) | `terraform graph` plus HCL | Any (generic) | Interactive d3 HTML, SVG, DOT | **Abandoned** (pinned to TF 0.12.3) | MIT | Not viable on Terraform 1.x\[7\]\[21\] |
| **Pluralith** | Plan | AWS only | PDF/PNG, PR comments | **Abandoned** (last update July 2023). CI tier was $250/month\[8\]\[22\] | MPL-2.0 CLI | Do not adopt |
| **tf2d2** | Terraform | AWS/GCP/Azure icons | D2 | **Tiny and stale** (12 stars, last update Oct 2024) | Apache-2.0 | Not recommended\[23\] |
| **Brainboard** | Terraform files/repos; cloud import on Enterprise | AWS, Azure, GCP, OCI, Scaleway | Web canvas; generates Terraform/OpenTofu | Commercial SaaS (from $25/month per a 2026 comparison)\[24\]\[25\] | Proprietary | Design-first tool; adds lock-in |
| **Cloudcraft (Datadog)** | Live cloud scan (resource collection), filterable by Terraform tags\[26\] | AWS, Azure, GCP (via Datadog resource collection) | Web diagrams, 2D/3D | Commercial, actively developed | Proprietary | Shows deployed reality, not code. Needs Datadog |
| **Hava.io** | Live cloud scan | AWS, Azure, GCP | Web, exports | Commercial | Proprietary | Shows deployed reality, not code |

**TerraVision in more detail.**
- **Inputs.** The diagram is derived from `terraform plan`, so conditionals, `count`, `for_each` and modules are resolved.\[10\] The credential-free route is `terraform plan -out=tfplan.bin`, then `terraform show -json tfplan.bin > plan.json` and `terraform graph > graph.dot`, then `terravision draw --planfile plan.json --graphfile graph.dot --source ./layer`. That last step needs no Terraform and no cloud access.\[13\]
- **Recent releases.**
  - v0.38.0 replaced graphviz2drawio with a pure-Python mxGraph emitter, so `.drawio` export works out of the box on all platforms.\[27\]
  - v0.42.0 added `--engine tofu` (OpenTofu), `--fontsize`, `--iconsize`, `--use-resource-names`, and auto-grouping of same-type resources.\[28\]
  - v0.51.1 fixed draw.io exports that drew 146 AWS and 176 Azure resource types as empty boxes. After the fix, icons map for AWS 388/390 types, Azure 298/303 and GCP 274/275.\[11\]\[29\]
- **Integrations.**
  - A GitHub Action, `patrickchugh/terravision-action@v2`, which needs Terraform or OpenTofu on PATH.\[30\]\[31\]
  - A Docker image, `patrickchugh/terravision`.\[32\]
  - A `--simplified` mode that strips VPC and subnet plumbing.\[33\]
  - `terravision.yml` annotations for titles, extra labels and resources defined outside Terraform.\[34\]
  - An MCP server listed in the GitHub MCP Registry, plus an agent skill for Claude Code.\[33\]\[35\]
- **Limitations.**
  - Its own docs say an automatically generated diagram gets you "80-90% of the way there".\[34\]
  - Unless you use plan-file mode, it needs a working `terraform plan`, and therefore credentials.\[36\]
  - Module paths must be resolvable.\[37\]
  - It has no notion of cross-layer remote-state edges.
  - Marketing claims of "100% client-side" sit next to documented credential requirements. Read them as "TerraVision itself never calls your cloud; Terraform may."\[36\]
- **License.** AGPL-3.0 is generally unproblematic for running a CLI internally. Get a check if your organization has an AGPL policy, or if you plan to modify and distribute it.

**Inframap in more detail.** It is the best lightweight choice when you want state-based truth (what is actually deployed) under an MIT license.\[38\]\[39\] Run `terraform state pull | inframap generate | dot -Tsvg > layer.svg`. It prunes non-essential resources and sensitive data. Visual quality is basic Graphviz, and output is DOT only.\[40\]

**`terraform graph`.** By default it produces a simplified dependency graph of resources only. `-type=plan|plan-destroy|apply` adds runtime internals.\[41\]\[42\] It is useful for debugging ordering, but unreadable as architecture documentation for real stacks.\[39\]\[43\]

### 2. Diagram-as-code options (for the overview and curated views)

| Approach | Status | Cloud icons | Programmatic generation | Rendering in GitHub | Verdict for this repo |
|---|---|---|---|---|---|
| **D2** | Active. Bundles dagre, ELK and TALA layouts | Hosted icon set (icons.terrastruct.com / icons.d2lang.com) | Easy: emit text from a script | Commit the rendered SVG | **Best for a generated overview**\[44\]\[45\] |
| **Structurizr (C4)** | "vNext" consolidated into one open-core tool; the cloud service is end-of-life; free OSS MCP server; Lite binaries v2026.09.19\[46\]\[47\]\[48\] | Themes include cloud icons | DSL is easy to emit; one model drives many views | Export to PNG/SVG/PlantUML/Mermaid | Best if you also want C4 context/container views of the apps |
| **Python `diagrams`** (mingrammer) | v0.25.1, 22 November 2025, MIT\[49\] | Excellent AWS/Azure/GCP/K8s | Python code, so a script reads `terraform show -json` and builds nodes | Commit PNG/SVG | Good alternative generator; layout control is weak |
| **Mermaid `architecture-beta`** | Beta. Custom icons through Iconify `registerIconPacks`\[50\] | `logos:aws-*` or the AWS icon pack | Easy to emit | GitHub renders Mermaid but **shows "?" for custom architecture icons**; pre-render with `mmdc --iconPacks`\[51\] | Fine for simple overviews; icon rendering is a gotcha\[1\]\[52\]\[53\] |
| **PlantUML** plus aws-icons-for-plantuml / Azure / GCP libraries | Active (v1.2025.4)\[54\] | Good | Easy to emit | Commit SVG | Workable; older aesthetic |
| **Graphviz DOT** | Stable | Manual | Every Terraform tool emits DOT | Commit SVG | Low-level rendering backend only |

A note on D2 licensing: older posts (2024) describe the TALA layout engine as a paid licence. D2's own blog announced on 7 September 2026 that "TALA (Terrastruct's AutoLayout Algorithm) is now open-source under the same license as D2 (MPL-2.0)", after Terrastruct announced it was shutting down and D2 moved to fiscal sponsorship by Hack Club; secondary reports say TALA is bundled from D2 v0.9.0. Confirm with `d2 --version` and `d2 layout tala` before relying on it. ELK is free and good enough for an overview either way.

### 3. MCP servers and AI-assisted options for Claude Code

| Server | Maturity | Setup in Claude Code | Reads | Writes | Git-friendly output |
|---|---|---|---|---|---|
| **TerraVision MCP / skill** | Active, listed in GitHub MCP Registry\[33\] | Via `uv`/`pipx` (see repo guide) | Terraform code, plan files, JSON graphs\[55\] | PNG, SVG, `.drawio`, CI workflow\[55\]\[56\] | Yes |
| **draw.io official** (`jgraph/drawio-mcp`, Apache-2.0) | Official, released 3 February 2026\[57\] | `claude mcp add drawio -- npx -y @drawio/mcp`, or `/plugin marketplace add jgraph/drawio-mcp` then `/plugin install drawio@drawio`\[58\]\[59\] | Prompts; XML, CSV and Mermaid input\[60\] | Opens diagrams in the draw.io editor (`open_drawio_xml`, `open_drawio_csv`, `open_drawio_mermaid`). Hosted App server at `https://mcp.draw.io/mcp` renders inline\[57\]\[61\] | `.drawio` XML and `.drawio.svg` are diffable; the tool server passes content in the URL fragment, not to the server\[58\] |
| **drawio-skill** (Agents365-ai, community) | Active | `npx skills add Agents365-ai/drawio-skill -g`\[62\] | Code, Terraform/K8s, SQL, OpenAPI\[62\] | `.drawio` with incremental sync and a `drawiodiff.py` drift diff\[62\]\[63\] | Yes. Good for diagram-vs-diagram diffs |
| **Excalidraw official** | Official (February 2026), remote at `mcp.excalidraw.com/mcp` | `claude mcp add --transport http ...` | Prompts | Inline hand-drawn diagrams | Weak for git. Community `yctimlin/mcp_excalidraw` exports `.excalidraw` files to the repo\[2\]\[64\]\[65\] |
| **Lucid MCP** | Official, launched November 2025 | Remote `https://mcp.lucid.app/mcp`, OAuth; an admin must enable it | Lucid documents | Creates/edits Lucid docs, exports images | Poor. Content lives in Lucid SaaS (lock-in)\[4\]\[66\] |
| **HashiCorp `terraform-mcp-server`** | Official. v1.1.0 cited July 2026; HashiCorp docs label it beta\[67\]\[68\] | `claude mcp add terraform -- docker run -i --rm hashicorp/terraform-mcp-server` (set `TFE_TOKEN`/`TFE_ADDRESS` for HCP)\[69\]\[70\] | Registry docs; HCP Terraform/TFE workspaces, runs, state versions\[70\] | Workspace/run operations (destructive ops gated by `ENABLE_TF_OPERATIONS`)\[68\]\[71\] | No diagram output. Use it to let Claude read workspace and state data that feeds the overview |
| **AWS Diagram MCP** (`awslabs.aws-diagram-mcp-server`) | **Deprecated and yanked from PyPI**\[72\]\[73\] | Do not use | n/a | n/a | Replaced by the diagram skill in `awslabs/agent-plugins` `deploy-on-aws`\[73\] |
| **Figma / Miro MCP** | Not verified in this research | n/a | n/a | n/a | Whiteboard-oriented and SaaS-hosted; not recommended as a source of truth |

### 4. Workflow patterns for keeping diagrams current

- **Generate in CI on every merge, per layer.** Use a matrix over `foundation`, `apps/app-a` and `apps/app-b`. Reuse the plan your pipeline already makes: export `plan.json` and `graph.dot` as artifacts, then render with TerraVision in plan-file mode. **Never commit `plan.json` or state.** Both can contain secrets.
- **Commit generated artifacts next to the code.** For each layer, commit `docs/diagrams/<layer>.svg` (for the README), `<layer>.drawio` (editable) and the JSON graph data. Reviewers can then see architecture changes as a diff in the pull request.
- **Detect drift on the graph JSON, not the image.** SVG layout may not be byte-stable between runs. TerraVision has a `graphdata` command, so commit the JSON graph and have CI regenerate it and run `git diff --exit-code`.\[74\] That fails a pull request whose diagram data is stale. For curated draw.io files, `drawiodiff.py` from drawio-skill can report added, removed and changed nodes.
- **Pre-commit hooks:** use these for terraform-docs and the overview generator, which are fast and offline. Keep TerraVision in CI, because it needs `terraform plan`.
- **Combine with terraform-docs:** terraform-docs v0.24.0 injects content between `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` markers. Use `--output-file README.md --output-mode inject`, or the `terraform-docs/gh-actions` action (v1.4.1, `output-method: inject`, `git-push: "true"`).\[75\]\[76\] Put the diagram image link *above* the markers so terraform-docs never overwrites it.
- **Layered structure:** one top-level `docs/architecture.md` holds the generated overview (foundation plus the two app layers and the outputs or remote-state edges between them). It links to each layer's README, which embeds that layer's TerraVision diagram and terraform-docs tables.

### 5. Provider coverage differences

- **AWS** has the deepest coverage everywhere: TerraVision, Python `diagrams`, Cloudcraft, Mermaid/PlantUML icon packs, and AWS's own agent skill.
- **Azure** is well covered by TerraVision (298/303 types mapped to draw.io shapes), Python `diagrams`, Brainboard and Cloudcraft.\[29\]
- **GCP** is covered by TerraVision (274/275 types, using draw.io gcp3 stencils) and Python `diagrams`. Cloudcraft supports it through Datadog resource collection.\[26\]\[29\]
- **Inframap**'s provider-specific simplification covers only a few providers. Others render every resource without refinement.\[15\]
- **Pluralith** was AWS-only.\[22\]

## Comparison and Ranking

| Criterion | 1. TerraVision per layer (CI) | 2. Generated D2/Structurizr overview | 3. draw.io MCP curated diagrams | Inframap (fallback) | SaaS (Cloudcraft/Hava/Brainboard) |
|---|---|---|---|---|---|
| Accuracy | High (from plan); misses cross-layer links | High for layer topology (parsed from code) | Only as good as the prompt; drifts | High (from state) | High for deployed reality |
| Maintenance effort | Low once wired into CI | Low (script) | Medium to high | Low | Low, but external |
| Visual quality | High (official icons) | Medium to high | Highest | Low to medium | High |
| Editability | `.drawio` export | Text source | Native draw.io | DOT | In-app |
| Cost | Free (AGPL) | Free | Free | Free (MIT) | $25 to $249/month |
| Lock-in | Low | None | Low | None | High |

**Ranked recommendation:**
1. **TerraVision per layer in CI.** Accurate, maintained, multi-cloud, editable outputs, works with Claude Code.
2. **A script-generated D2 overview.** The only reliable way to show the foundation and per-app layering and the remote-state contracts between layers.
3. **draw.io MCP (plus optional drawio-skill)** for one or two curated, presentation-grade diagrams. Keep them in `docs/diagrams/curated/` and label them "curated; may lag code".

## Implementation Plan for Claude Code

**Step 0: Assumptions to confirm.**
- Root modules live at `foundation/`, `apps/app-a/` and `apps/app-b/`.
- Shared modules live in `modules/`.
- CI is GitHub Actions and already runs `terraform plan` per layer.
- Adapt the paths if any of this differs.

**Step 1: Install tooling locally and in the devcontainer.**
```bash
brew install graphviz d2 terraform-docs        # or apt: graphviz; curl -fsSL https://d2lang.com/install.sh | sh -s --
pipx install terravision                       # or: uv tool install terravision
pip install python-hcl2                        # for the overview generator
terravision --help && d2 --version && terraform-docs --version
```

**Step 2: Repository layout.**
```
infra/
  foundation/            README.md  terravision.yml  *.tf
  apps/app-a/            README.md  terravision.yml  *.tf
  apps/app-b/            README.md  terravision.yml  *.tf
  modules/...
  docs/
    architecture.md      # embeds overview.svg, links to layer READMEs
    diagrams/
      overview.d2  overview.svg
      foundation.svg  foundation.drawio  foundation.graph.json
      app-a.svg ...  app-b.svg ...
      curated/           # draw.io MCP output, human-reviewed
  scripts/
    gen_overview.py
    render_layer.sh
  .terraform-docs.yml
  .pre-commit-config.yaml
  .github/workflows/diagrams.yml
```

**Step 3: Render one layer locally (plan-file mode).**
```bash
cd foundation
terraform init && terraform plan -out=tfplan.bin
terraform show -json tfplan.bin > /tmp/foundation.plan.json
terraform graph > /tmp/foundation.graph.dot
cd ..
terravision draw --planfile /tmp/foundation.plan.json --graphfile /tmp/foundation.graph.dot \
  --source ./foundation --format svg    --outfile docs/diagrams/foundation
terravision draw --planfile /tmp/foundation.plan.json --graphfile /tmp/foundation.graph.dot \
  --source ./foundation --format drawio --outfile docs/diagrams/foundation
terravision graphdata --source ./foundation --outfile docs/diagrams/foundation.graph.json  # check exact flags with --help
```
Add `--simplified` for an executive view. Add `--engine tofu` if you use OpenTofu.\[13\]\[28\] Put titles and external resources in each layer's `terravision.yml`.

**Step 4: Write `scripts/gen_overview.py`.** Claude Code should implement it to:
- parse every layer's `*.tf` with `python-hcl2`;
- collect `output` blocks and `data "terraform_remote_state"` blocks, mapping each remote-state `config` (bucket/key/workspace) back to the producing layer;
- collect which `data.terraform_remote_state.X.outputs.Y` references each layer uses;
- emit `docs/diagrams/overview.d2`, with one container per layer (foundation, app-a, app-b) listing key resources by type count, and edges from producer to consumer labeled with the output names;
- render it with `d2 --layout=elk docs/diagrams/overview.d2 docs/diagrams/overview.svg`.

Optionally, use the HashiCorp Terraform MCP server (HCP Terraform users) to pull workspace and state-version metadata to enrich the labels.

**Step 5: Configure terraform-docs injection.** Each layer README gets:
```markdown
![Foundation architecture](../docs/diagrams/foundation.svg)
<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
```
Then run `terraform-docs markdown table --output-file README.md --output-mode inject ./foundation`, and do the same for each layer.

**Step 6: Set up pre-commit for the fast, offline parts.**
```yaml
repos:
  - repo: https://github.com/terraform-docs/terraform-docs
    rev: v0.24.0
    hooks:
      - id: terraform-docs-go
        args: ["markdown", "table", "--output-file", "README.md", "--output-mode", "inject", "./foundation"]
  - repo: local
    hooks:
      - id: overview-diagram
        name: regenerate overview diagram
        entry: python scripts/gen_overview.py
        language: system
        pass_filenames: false
        files: '\.tf$'
```

**Step 7: CI workflow sketch (`.github/workflows/diagrams.yml`).**
```yaml
name: diagrams
on:
  pull_request: { paths: ["**/*.tf", "**/terravision.yml"] }
  push: { branches: [main] }
jobs:
  render:
    runs-on: ubuntu-latest
    strategy:
      matrix: { layer: [foundation, apps/app-a, apps/app-b] }
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      # configure cloud credentials via OIDC here (same as your plan job)
      - run: |
          cd ${{ matrix.layer }}
          terraform init -input=false
          terraform plan -input=false -out=tfplan.bin
          terraform show -json tfplan.bin > plan.json
          terraform graph > graph.dot
      - run: sudo apt-get install -y graphviz && pipx install terravision
      - run: |
          name=$(basename ${{ matrix.layer }})
          for fmt in svg drawio; do
            terravision draw --planfile ${{ matrix.layer }}/plan.json --graphfile ${{ matrix.layer }}/graph.dot \
              --source ./${{ matrix.layer }} --format $fmt --outfile docs/diagrams/$name
          done
      - uses: actions/upload-artifact@v4
        with: { name: diagrams-${{ strategy.job-index }}, path: docs/diagrams/ }
  commit:
    needs: render
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { path: docs/diagrams/, merge-multiple: true }
      - run: python scripts/gen_overview.py && d2 --layout=elk docs/diagrams/overview.d2 docs/diagrams/overview.svg
      - uses: terraform-docs/gh-actions@v1.4.1
        with: { working-dir: "foundation,apps/app-a,apps/app-b", output-method: inject, git-push: "false" }
      - run: |
          git config user.name "diagram-bot"; git config user.email "bot@users.noreply.github.com"
          git add docs/diagrams **/README.md && git commit -m "docs: regenerate architecture diagrams" || echo "no changes"
          git push
```
On pull requests, add a drift check step: regenerate `*.graph.json` and the overview, then run `git diff --exit-code docs/diagrams/*.graph.json docs/diagrams/overview.d2`. Do not upload `plan.json` as a long-lived artifact.

**Step 8: Optional MCP setup for curated diagrams.**
```bash
claude mcp add drawio -- npx -y @drawio/mcp
claude mcp add terraform -- docker run -i --rm -e TFE_TOKEN -e TFE_ADDRESS hashicorp/terraform-mcp-server
# TerraVision MCP/skill: follow the repo's MCP guide (uv-based) to register it in Claude Code
```
Prompt pattern: "Read docs/diagrams/overview.d2 and foundation.drawio; produce a curated draw.io diagram for stakeholders in docs/diagrams/curated/platform.drawio; do not invent resources not present in the graph JSON."

## Caveats

- **Version facts conflict across sources.** TerraVision's GitHub releases show v0.51.1 (1 October 2026), while a PyPI fetch showed 0.48.0.\[10\]\[11\] Pin a version in CI and check `--help` for exact flag names, especially `graphdata`. Hava's own pricing page lists Professional at $59 per month and Teams at $249 per month, while other listings still show $49, so check current pricing before budgeting.
- **TerraVision cannot see across states.** Cross-layer edges come only from the overview generator or from annotations. Cloud-scanning SaaS tools (Cloudcraft, Hava) show console-created resources that no Terraform-based tool can see.\[77\]
- **Secrets.** State and plan JSON can contain sensitive values. Render diagrams from them in CI, but never commit them.
- **Mermaid on GitHub.** `architecture-beta` custom icons render as "?" on GitHub, so pre-render to SVG if you choose Mermaid.\[51\]
- **Some MCP claims come from third-party directories,** for example the HashiCorp server's version and tool counts and the Excalidraw endpoint details.\[65\]\[78\] Verify against the official repos at setup time. The Figma and Miro MCP options were not evaluated here.

## Sources

1. [github.com](https://github.com/quarto-dev/quarto-cli/issues/13366)
2. [Official Excalidraw MCP Server](https://mcpservers.org/servers/excalidraw-app-demo-mcp)
3. [Using Excalidraw MCP to make Claude Code draw cute architecture diagrams](https://dev.classmethod.jp/en/articles/excalidraw-mcp-claude-code/)
4. [Lucid MCP vs Lucid API for AI Agents: Which to Build Against](https://www.scalekit.com/blog/lucid-mcp-vs-api)
5. [Issues · 28mm/blast-radius](https://github.com/28mm/blast-radius/issues)
6. [28mm/blast-radius - Docker Image](https://hub.docker.com/r/28mm/blast-radius)
7. [blast-radius not working with latest terraform version · Issue #71 · 28mm/blast-radius](https://github.com/28mm/blast-radius/issues/71)
8. [Pluralith · GitHub](https://github.com/Pluralith)
9. [Issues · Pluralith/pluralith-cli](https://github.com/Pluralith/pluralith-cli/issues)
10. [terravision](https://pypi.org/project/terravision/)
11. [Release v0.51.1 · patrickchugh/terravision](https://github.com/patrickchugh/terravision/releases/tag/v0.51.1)
12. [Releases · patrickchugh/terravision](https://github.com/patrickchugh/terravision/releases)
13. [terravision/README.md at main · patrickchugh/terravision](https://github.com/patrickchugh/terravision/blob/main/README.md)
14. [GitHub - cycloidio/inframap: Read your tfstate or HCL to generate a graph specific for each provider, showing only the resources that are most important/relevant. · GitHub](https://github.com/cycloidio/inframap)
15. [inframap command - github.com/cycloidio/inframap - Go Packages](https://pkg.go.dev/github.com/cycloidio/inframap)
16. [github.com](https://github.com/doytsujin/inframap)
17. [terraform graph command reference](https://developer.hashicorp.com/terraform/cli/commands/graph)
18. [https://github.com/im2nguyen/rover](https://awesome.ecosyste.ms/projects/github.com/im2nguyen/rover)
19. [im2nguyen/rover - Docker Image](https://hub.docker.com/r/im2nguyen/rover)
20. [Release v0.3.0 · im2nguyen/rover](https://github.com/im2nguyen/rover/releases/tag/v0.3.0)
21. [blast-radius/bin/blast-radius at master · 28mm/blast-radius](https://github.com/28mm/blast-radius/blob/master/bin/blast-radius)
22. [Tools to Visualise your Terraform Plan](https://overmind.tech/resources/terraform-tools/plan-comparisons)
23. [tf2d2 · GitHub](https://github.com/tf2d2)
24. [Best Cloud Architecture Diagram Tools 2026: 7 Tools Compared](https://infrasketch.net/blog/best-cloud-architecture-diagram-tools-2026)
25. [Top tools for creating deployment diagrams](https://icepanel.medium.com/top-tools-for-creating-deployment-diagrams-946250a11547)
26. [Cloudcraft in Datadog](https://docs.datadoghq.com/datadog_cloudcraft/)
27. [patrickchugh/terravision v0.38.0 on GitHub](https://newreleases.io/project/github/patrickchugh/terravision/release/v0.38.0)
28. [patrickchugh/terravision v0.42.0 on GitHub](https://newreleases.io/project/github/patrickchugh/terravision/release/v0.42.0)
29. [fix(drawio): every icon mapped, labels named and placed, no phantom arrows by patrickchugh · Pull Request #223 · patrickchugh/terravision](https://github.com/patrickchugh/terravision/pull/223)
30. [GitHub - patrickchugh/terravision: Professional cloud architecture diagrams with official AWS, Azure and GCP icons, from Terraform code or a plain JSON graph. MCP server + agent skill. · GitHub](https://t.co/YW8krQ4zjo)
31. [GitHub - patrickchugh/terravision-action: Terravision GitHub Actions step](https://github.com/patrickchugh/terravision-action)
32. [GitHub - patrickchugh/terravision: Terravision creates Professional Cloud Architecture Diagrams from your Terraform code automatically. Supports AWS, Google and Azure. · GitHub](https://github.com/patrickchugh/terravision?tab=readme-ov-file)
33. [MCP Registry](https://github.com/mcp/patrickchugh/terravision)
34. [TerraVision](https://patrickchugh.github.io/terravision/docs/)
35. [Claudepluginhub](https://www.claudepluginhub.com/plugins/patrickchugh-terravision-cloud-diagrams)
36. [GitHub - cxmlabs/terravision: Terravision creates Professional Cloud Architecture Diagrams from your Terraform code automatically. Supports AWS, Google and Azure. · GitHub](https://github.com/cxmlabs/terravision)
37. [Developer Guide](https://patrickchugh.github.io/terravision/docs/developer_guide.html)
38. [InfraMap - Cycloid](https://www.cycloid.io/open-source/inframap/)
39. [Tools to Visualize your Terraform plan](https://medium.com/vmacwrites/tools-to-visualize-your-terraform-plan-d421c6255f9f)
40. [InfraMap: Open-Source Cloud Diagram Maker - Cycloid](https://www.cycloid.io/blog/inframap-launch/)
41. [Terraform Graph Command - Generating Dependency Graphs](https://spacelift.io/blog/terraform-graph)
42. [www.terraform.io](https://www.terraform.io/docs/cli/commands/graph.html)
43. [How to Create AWS Architecture Diagrams in 2026: A Complete Guide — InfraSketch](https://infrasketch.cloud/blog/how-to-create-aws-architecture-diagrams.html)
44. [GitHub - d2lang/d2: D2 is a modern diagram scripting language that turns text to diagrams. · GitHub](https://github.com/terrastruct/d2)
45. [Document Networks as Code with D2! - DEV Community](https://dev.to/ngschmidt/document-networks-as-code-with-d2-40p)
46. [Introducing Structurizr vNext](https://www.patreon.com/posts/introducing-146923136)
47. [Structurizr Lite](https://docs.structurizr.com/lite)
48. [Structurizr](https://structurizr.com/)
49. [diagrams · PyPI](https://pypi.org/project/diagrams/)
50. [Support Mermaid icon pack registration for architecture diagrams · mintlify · Discussion #4224](https://github.com/orgs/mintlify/discussions/4224)
51. [Support icons for mermaid architecture diagrams · community · Discussion #146647](https://github.com/orgs/community/discussions/146647)
52. [Building and Using a Custom Iconify Image Set For Mermaid](https://blog.acederberg.io/posts/iconify/index.html)
53. [Mermaid Brand Icons - Architecture Diagrams with Real Logos](https://thesvg.org/integrations/mermaid)
54. [PlantUML](https://en.wikipedia.org/wiki/PlantUML)
55. [GitHub - TheTechOddBug/terravision: Terravision visualises Terraform code as live Professional Cloud Architecture Diagrams by analysing the code dynamically. Supports AWS, Google and Azure. · GitHub](https://github.com/TheTechOddBug/terravision)
56. [\[pull\] main from patrickchugh:main by pull\[bot\] · Pull Request #105 · TheTechOddBug/terravision](https://github.com/TheTechOddBug/terravision/pull/105)
57. [Vibe Diagramming with draw.io’s MCP Server](https://medium.com/@Modi_Rohan/vibe-diagramming-with-draw-ios-mcp-server-a6ae524f2b3a)
58. [GitHub - jgraph/drawio-mcp · GitHub](https://github.com/jgraph/drawio-mcp)
59. [drawio-mcp/mcp-tool-server/README.md at main · jgraph/drawio-mcp](https://github.com/jgraph/drawio-mcp/blob/main/mcp-tool-server/README.md)
60. [Draw.io MCP Server (jgraph/drawio-mcp)](https://context7.com/jgraph/drawio-mcp)
61. [drawio-mcp/mcp-app-server at main · jgraph/drawio-mcp](https://github.com/jgraph/drawio-mcp/tree/main/mcp-app-server)
62. [GitHub - Agents365-ai/drawio-skill: Agent skill that turns natural language, code, Terraform/K8s, SQL, OpenAPI, AsyncAPI, Protobuf and GraphQL sources into editable, tested draw.io architecture diagrams: incremental sync, multi-view projection, drift diff, CI architecture tests, whiteboard derasterize, interactive HTML/PPTX/Mermaid exports. · GitHub](https://github.com/Agents365-ai/drawio-skill)
63. [drawio-skill — Claude MCP Server](https://www.claudemarketplace.net/mcp/drawio-skill)
64. [GitHub - yctimlin/mcp\_excalidraw: MCP server and Claude Code skill for Excalidraw — programmatic canvas toolkit to create, edit, and export diagrams via AI agents with real-time canvas sync.](https://github.com/yctimlin/mcp_excalidraw)
65. [Excalidraw](https://mcp.so/servers/excalidraw-app-demo)
66. [Integrate Lucid with AI tools using the Lucid MCP server](https://help.lucid.co/hc/en-us/articles/42578801807508-Integrate-Lucid-with-AI-tools-using-the-Lucid-MCP-server)
67. [Best Terraform MCP Server: Scalr vs Spacelift vs HCP vs env0](https://scalr.com/learning-center/which-terraform-platform-has-the-best-mcp-server)
68. [Terraform MCP Server for Claude — HeyClaude](https://heyclau.de/entry/mcp/terraform-mcp-server)
69. [Terraform MCP Server](https://top-mcps.com/mcp/terraform)
70. [Mcpplaygroundonline](https://mcpplaygroundonline.com/mcp-servers/terraform)
71. [Terraform MCP server reference](https://developer.hashicorp.com/terraform/mcp-server/reference)
72. [Amazon ECR Public Gallery - AWS Labs MCP/awslabs/aws-diagram-mcp-server](https://gallery.ecr.aws/awslabs-mcp/awslabs/aws-diagram-mcp-server)
73. [The AWS Diagram MCP Server Was Deprecated — Here's the Updated Approach Using Agent Skills](https://builder.aws.com/content/3Dd4PzYvNS7knkGhX5qNvtkcbkf/the-aws-diagram-mcp-server-was-deprecated-heres-the-updated-approach-using-agent-skills)
74. [Usage Guide](https://patrickchugh.github.io/terravision/docs/USAGE_GUIDE.html)
75. [gh-actions/README.md at main · terraform-docs/gh-actions](https://github.com/terraform-docs/gh-actions/blob/main/README.md)
76. [GitHub - terraform-docs/terraform-docs: Generate documentation from Terraform modules in various output formats · GitHub](https://github.com/terraform-docs/terraform-docs)
77. [The Terraform MCP server has 35+ tools and none of them can see the resource I made in the console - DEV Community](https://dev.to/hitoshi1964/the-terraform-mcp-server-has-35-tools-and-none-of-them-can-see-the-resource-i-made-in-the-console-4c73)
78. [Excalidraw Official Remote MCP Server — Setup Guide](https://mcpservers.org/remote-mcp-servers/excalidraw-app-demo)
