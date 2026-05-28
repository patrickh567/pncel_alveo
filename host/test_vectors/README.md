# Bundled Mini_Dice test vectors

Vendored from `~/repos/Mini_Dice_Backend/Mini_Dice/tb/test_vectors/`
(commit-time copy — re-run `gen_memfile.py` upstream and `cp` here if
you regenerate them).  The host script (`../run_kernel.py`) defaults to
this directory so the package is self-contained — no PATH or git
submodule needed at runtime.

| Vector                              | Files                                                       | CTAs | Expected writes |
|-------------------------------------|-------------------------------------------------------------|------|-----------------|
| `full_mul_array_test_vector`        | `*_{bitstream,cta_desc,meta}.mem` + `_runtime.json`         | 1    | 64              |
| `simple_branching_test_vector`      | same                                                        | 1    | 64              |
| `gemm/gemm`                          | `gemm/gemm_*`                                               | 4    | 64              |
| `nn_cuda/nn_cuda`                    | `nn_cuda/nn_cuda_*`                                         | 4    | 64              |

Each vector's `_runtime.json` is the ground truth the host verifier
diffs against (`verifier.py::check`).  Authored upstream by Mini_Dice's
generator against the EP-mock memory model
(`axi_read16(addr) = addr & 0xFFFF`), which is why the host preloads
the dfetch DATA region with the address-echo pattern before launching
each kernel — that pattern stands in for the EP-mock's response data
when the chip reads operands from real BRAM.

To use a different vector tree at runtime:

```bash
python3 run_kernel.py --vectors-dir /path/to/other/vectors --test my_kernel
```
