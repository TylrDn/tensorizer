# Tensorizer End‑to‑End

Tensorizer converts PyTorch modules into a single `.tensors` file that can be
streamed from HTTP or S3 at wire speed.

## Five‑Minute Quickstart

```bash
python examples/tensorizer/serialize_and_load.py --local-only
```

The script serializes a tiny GPT‑2 model, serves it over HTTP, and lazily loads
it back into a fresh module.

## Fifteen‑Minute Deep Dive

1. `TensorSerializer.write_module` creates `tiny-gpt2.tensors`.
2. `upload_to_s3` (optional) pushes the file to CoreWeave Object Storage.
3. `TensorDeserializer(..., device=..., lazy_load=True, num_readers=8)` streams
the model directly to CPU or GPU memory.
4. KNative/KServe benefit from faster cold starts because weights are fetched
on demand rather than baked into the container.

## A note on throughput numbers

Deserialization is network-bound, so throughput tracks your link speed. The
often-quoted `~5GB/s` on 40GbE (GPT-J, `20GB`) and the letter-value plot in the
[README](../README.md) are **CoreWeave's published benchmarks** for upstream
`tensorizer` (release 2.5.0 methodology, `examples/benchmark_buffer_size`). They
have **not** been independently reproduced in this fork, and this deployment
layer ships no benchmark of its own. Measure your own cluster before quoting a
number — see [observability.md](observability.md) for what to watch.
