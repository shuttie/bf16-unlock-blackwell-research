#!/usr/bin/env python3
"""Compile tensor_modes_issue_sm120.cu to PTX with NVRTC (no host compiler).

nvcc 13 rejects GCC 15's noexcept-qualified math declarations, so the device
source is compiled through NVRTC. Assemble the PTX with ptxas afterwards.
"""
import ctypes as C
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CUDA_HOME = os.environ.get("CUDA_HOME", "/usr/local/cuda")
NVRTC = f"{CUDA_HOME}/lib64/libnvrtc.so"
SRC = HERE / "tensor_modes_issue_sm120.cu"
OUT = HERE / "tensor_modes_issue_sm120.ptx"
ARCH = "--gpu-architecture=" + os.environ.get("CUDA_ARCH", "sm_120")


def main():
    lib = C.CDLL(NVRTC)
    source = SRC.read_bytes()
    program = C.c_void_p()
    rc = lib.nvrtcCreateProgram(C.byref(program), source, SRC.name.encode(), 0, None, None)
    if rc:
        sys.exit(f"nvrtcCreateProgram failed: {rc}")

    options = [ARCH.encode(), b"--std=c++17"]
    opt_array = (C.c_char_p * len(options))(*options)
    rc = lib.nvrtcCompileProgram(program, len(options), opt_array)

    log_size = C.c_size_t()
    lib.nvrtcGetProgramLogSize(program, C.byref(log_size))
    log = C.create_string_buffer(log_size.value)
    lib.nvrtcGetProgramLog(program, log)
    text = log.value.decode(errors="replace").strip()
    if text:
        print(text)

    if rc:
        sys.exit(f"nvrtcCompileProgram failed: {rc}")

    ptx_size = C.c_size_t()
    rc = lib.nvrtcGetPTXSize(program, C.byref(ptx_size))
    if rc:
        sys.exit(f"nvrtcGetPTXSize failed: {rc}")
    ptx = C.create_string_buffer(ptx_size.value)
    rc = lib.nvrtcGetPTX(program, ptx)
    if rc:
        sys.exit(f"nvrtcGetPTX failed: {rc}")

    data = ptx.raw[: ptx_size.value].rstrip(b"\x00")
    OUT.write_bytes(data)
    print(f"wrote {OUT} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
