# Auto-generated training script for Gay.jl Enzyme color space
# Input:  /Users/bob/i/duck/synthetic_eeg_color_training.json (from enzyme_color_train.py export)
# Output: /Users/bob/i/duck/trained_okhsl_params.json (trained OkhslParameters + SeedProjection)

using JSON3
using Gay
using Gay.OkhslLearnable

# Load Enzyme extension if available
try
    using Enzyme
    @info "Enzyme.jl loaded — using true autodiff"
catch
    @warn "Enzyme.jl not found — falling back to finite differences"
end

# ─── Load training data ───────────────────────────────────────────────
data = JSON3.read(read("/Users/bob/i/duck/synthetic_eeg_color_training.json", String))
seeds = Float64.(data.seeds)
class_labels = Int.(data.class_labels)
n_classes = data.n_classes

println("Loaded $(length(seeds)) training samples, $n_classes classes")
println()

# ─── Initialize learnable color space ─────────────────────────────────
cs = LearnableOkhsl()

println("Initial parameters:")
println("  h_scale  = $(cs.params.h_scale)")
println("  h_offset = $(cs.params.h_offset)")
println("  gamma    = $(cs.params.gamma)")
println("  s_range  = [$(cs.params.s_min), $(cs.params.s_max)]")
println("  l_range  = [$(cs.params.l_min), $(cs.params.l_max)]")
println()

# ─── Train ────────────────────────────────────────────────────────────
if @isdefined(Enzyme)
    # Use Enzyme reverse-mode autodiff
    using Gay.GayEnzymeExt: enzyme_learn_colorspace!
    enzyme_learn_colorspace!(cs, seeds, class_labels;
        lr=0.01, epochs=100, verbose=true)
else
    # Fallback to finite-difference training
    learn_colorspace!(cs, seeds, class_labels;
        lr=0.01, epochs=100, verbose=true)
end

println()
println("Trained parameters:")
println("  h_scale  = $(round(cs.params.h_scale, digits=4))")
println("  h_offset = $(round(cs.params.h_offset, digits=4))")
println("  gamma    = $(round(cs.params.gamma, digits=4))")
println("  s_range  = [$(round(cs.params.s_min, digits=4)), $(round(cs.params.s_max, digits=4))]")
println("  l_range  = [$(round(cs.params.l_min, digits=4)), $(round(cs.params.l_max, digits=4))]")
println()

# ─── Show learned colors per class ────────────────────────────────────
println("Learned class colors:")
unique_labels = sort(unique(class_labels))
for label in unique_labels
    idx = findfirst(==(label), class_labels)
    seed = seeds[idx]
    r, g, b = forward_color(cs, seed)
    h = cs.last_h
    println("  Class $label: H=$(round(h, digits=1))° → RGB($(round(r,digits=2)), $(round(g,digits=2)), $(round(b,digits=2)))")
end

# ─── Export trained parameters ────────────────────────────────────────
final_loss = compute_loss(EquivalenceClassObjective(), cs, seeds, class_labels)

output = Dict(
    "params" => Dict(
        "h_scale" => cs.params.h_scale,
        "h_offset" => cs.params.h_offset,
        "s_min" => cs.params.s_min,
        "s_max" => cs.params.s_max,
        "l_min" => cs.params.l_min,
        "l_max" => cs.params.l_max,
        "gamma" => cs.params.gamma,
    ),
    "projection" => Dict(
        "w_h" => cs.projection.w_h,
        "w_s" => cs.projection.w_s,
        "w_l" => cs.projection.w_l,
        "bias" => cs.projection.bias,
    ),
    "training_loss" => final_loss,
    "training_epochs" => 100,
    "n_classes" => n_classes,
)

open("/Users/bob/i/duck/trained_okhsl_params.json", "w") do io
    JSON3.pretty(io, output)
end

println()
println("Wrote trained parameters to /Users/bob/i/duck/trained_okhsl_params.json")
println("Final loss: $(round(final_loss, digits=4))")
