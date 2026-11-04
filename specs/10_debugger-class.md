# Debugger class: the GT200_DEBUGGER surface

## At a glance

- **Scope.** The `GT200_DEBUGGER` (`0x83de`) RM class on GB202: how a session is
  allocated, the command surface, and what each command can reach.
- **Bench.** Two RTX 5090s (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
  CUDA 13, stock driver.
- **Evidence.** Measured claims link to the experiment that established them.
  Source-derived claims name the public header or the driver function.

**The short version.**

- The class is in the 117-class list, and CUDA allocates one per context. A
  valid object needs a compute or 3D class object under a channel; the session's
  channel is that object's parent
  ([the allocation](#the-class-and-its-allocation-model)).
- Register ops through the class read the FEAT bank and the write drops at the
  [PLM](02_privilege-and-rate-control.md#privilege-levels-and-the-plm). The
  class is an RM client path and runs at the caller's level, so it does not
  raise privilege.
- The non-register commands do not open a read into secure or engine memory.
  The SM error state is live and empty; `GET_MAPPINGS` returns no mappings;
  `READ_SURFACE` refuses every VA; `GET_HANDLES` is not supported
  ([the census](../experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path)).
- `READ_MEMORY` and `READ_BATCH_MEMORY` reach any Memory object in the
  debugger session's client handle database, including internal channel buffers
  the CUDA API does not map. They cannot reach another client's handles, the
  RM heap, GSP/engine memory, or the
  [WPR](07_memory-and-host-access.md#wpr-and-frts-layout).
- `SUSPEND_CONTEXT` and `RESUME_CONTEXT` work.

**In this spec.**

- [The class and its allocation model](#the-class-and-its-allocation-model)
- [Privilege and the register-op path](#privilege-and-the-register-op-path)
- [Command surface](#command-surface)
- [Read scoping](#read-scoping)
- [What it cannot reach](#what-it-cannot-reach)
- [Evidence map](#evidence-map)

## The class and its allocation model

`GT200_DEBUGGER` is an RM class at `0x83de`. Its public allocation parameters in
`cl83de.h` are three handles: an obsolete field that must be zero, `hAppClient`,
and `hClass3dObject`. The object is allocated as a child of the device, and
`hClass3dObject` must be a compute or 3D class object under a channel. The
`KernelSMDebuggerSession` constructor looks up the app client, resolves the
class object, and records the class object's parent as `hChannel`; it takes the
subdevice from the app client. A valid object therefore needs a live compute
context.

On a GSP client the constructor checks that the allocating client's and the app
client's security tokens match; on CPU-RM it checks `RS_ACCESS_DEBUG` on the
compute object. A CUDA process can allocate a debugger for its own context,
which is the object these experiments use. Rebuilding the context from scratch
needs the channel's GPFIFO, userd, and notifier memory, so the driver's object
is the usable one
([the class record](../experiments/10_debugger-class-and-fecs-ucode.md#101-the-class-is-exposed-and-allocatable)).

| Term | Meaning |
|---|---|
| Session client | The client that allocated the debugger object. Its handle database scopes `READ_MEMORY`. |
| App client | The debuggee (`hAppClient`). It owns the compute object and the channel VAS. |
| `hChannel` | The parent of `hClass3dObject`, i.e. the debuggee channel. |
| `hSubdevice` | The app client's subdevice. |

In the captured CUDA allocation, the device is `0x5c00000a`, the channel group
`0x5c00001d`, the channel `0x5c000024`, the compute object `0x5c000025`, and the
debugger `0x5c00007f`, with `hAppClient` set to the CUDA client and
`hClass3dObject` to the compute object. The values are per-process; the shape is
stable ([the capture](../experiments/10_debugger-class-and-fecs-ucode.md#101-the-class-is-exposed-and-allocatable)).

## Privilege and the register-op path

`NV83DE_CTRL_CMD_DEBUG_EXEC_REG_OPS` (`0x83de031d`) submits
`NV2080_CTRL_GPU_EXEC_REG_OPS` entries. The RM validates each offset before
execution, and the hardware [PLM](02_privilege-and-rate-control.md#privilege-levels-and-the-plm)
decides the write. The FEAT bank read works; the FEAT write returns success and
is dropped ([the write
test](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).
The class runs at the caller's level, so it remains an observability path and
cannot pass the gate. The `GR_CTX` register type is the one type the generic subdevice
path could not use; the debugger session has the channel context and reads it
([the context
record](../experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read)).

## Command surface

The command IDs and parameter sizes are in the public `ctrl83dedebug.h`. The
GB202 column is the measured behavior on the production GSP path; the
census record carries the run detail
([the census](../experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path)).

| ID | Command | Purpose | GB202 |
|---|---|---|---|
| `0x83de0301` / `02` | `SM_DEBUG_MODE_ENABLE` / `DISABLE` | Take the SMs in or out of debug mode | Not issued; state-changing |
| `0x83de0307` / `08` | `SET` / `GET_MODE_MMU_DEBUG` | MMU debug mode | Getter works, reads `2` (disabled) |
| `0x83de0309` | `SET_EXCEPTION_MASK` | Filter debug exceptions | The CUDA driver issues it at context creation |
| `0x83de030b` | `READ_SINGLE_SM_ERROR_STATE` | One SM's error registers | Works, all zero |
| `0x83de030c` | `READ_ALL_SM_ERROR_STATES` | Every SM's error registers | Works for all 170 SMs, all zero; a request past the SM count is refused |
| `0x83de0310` | `CLEAR_ALL_SM_ERROR_STATES` | Clear the error state | Not issued |
| `0x83de0313` / `14`, `0321`–`24` | Stop-trigger, single-step, skip-idle setters | Debugger control | Not issued |
| `0x83de0315` | `READ_MEMORY` | Read one memory object | Works on session-client Memory handles; refuses others |
| `0x83de0316` | `WRITE_MEMORY` | Write one memory object | Not issued; write |
| `0x83de0317` / `18` | `SUSPEND_CONTEXT` / `RESUME_CONTEXT` | Preempt and resume the context | Both work; `waitForEvent=1` |
| `0x83de0319` | `GET_HANDLES` | Return the session channel and subdevice | `0x56` [NOT_SUPPORTED](08_errors-and-logging.md#nv-status-codes) |
| `0x83de031a` | `READ_SURFACE` | Read a GPU VA range | [`0x1f`](08_errors-and-logging.md#nv-status-codes) for every VA, including the caller's own buffer |
| `0x83de031b` | `WRITE_SURFACE` | Write a GPU VA range | Not issued; write |
| `0x83de031c` | `GET_MAPPINGS` | Enumerate a VA range | Success with `count=0` |
| `0x83de031d` | `EXEC_REG_OPS` | Register read/write batch | Works; the FEAT write drops at the PLM |
| `0x83de031f` / `20` | `SET` / `GET_MODE_ERRBAR_DEBUG` | ERRbar debug mode | Getter works, reads `0` (disabled) |
| `0x83de0325` | `GET_SINGLE_SM_DEBUGGER_STATUS` | SM debugger flags | Works, all false |
| `0x83de0326` / `27` | `READ` / `WRITE_BATCH_MEMORY` | Batch memory operations | Read works on session-client Memory handles; write not issued |
| `0x83de0328` | `READ_MMU_FAULT_INFO` | Cached MMU faults | Works, `count=0` |

## Read scoping

**Memory reads.** `READ_MEMORY` resolves `hMemory` in the session client's
handle database and requires a `Memory` object; the access bounds are the
memdesc size. It does not require the object to be mapped into the caller's
address space. In a CUDA process that reaches the driver's internal system,
local, and virtual memory objects, including the channel's system-memory
pushbuffer and the RM user shared data
([the readable objects](../experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path)).
`READ_BATCH_MEMORY` is the same path with a list of entries: a valid batch
returns the data, and a batch that names a non-Memory handle returns `0x1f`.

**Surface reads and mappings.** `READ_SURFACE` and `GET_MAPPINGS` resolve the
debuggee channel's VAS. `READ_SURFACE` then looks up a DMA mapping registered by
the debugger client's parent in that VAS; a VA outside that set is refused.
`GET_MAPPINGS` runs the MMU trace over the range. On the CUDA context both
returned nothing usable: `READ_SURFACE` refused the caller's own buffer and
`GET_MAPPINGS` returned zero mappings at the buffer's VA
([the census](../experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path)).

**SM state.** `READ_ALL_SM_ERROR_STATES` and `READ_SINGLE_SM_ERROR_STATE` act on
the resident GR context. A call is bounded by the device's SM count: GB202 has
170 SMs, and `NV83DE_CTRL_DEBUG_MAX_SMS_PER_CALL` is 100, so 100 at SM 0 and 70
at SM 100 succeed; a 100-entry call at SM 100 is refused. The error registers
read zero when no exception is pending
([the census](../experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path)).

**Handles.** `GET_HANDLES` is documented as debug/develop-build only in the
public header; the production GSP path returns
[`0x56` NOT_SUPPORTED](08_errors-and-logging.md#nv-status-codes).

## What it cannot reach

- Another RM client's handles. The memory lookup runs against the session
  client, not the app client, so the debuggee's handles are not visible.
- The RM/kernel heap and the GSP-RM's own memory. They are not in the session
  client's database.
- GSP or engine memory, and the [WPR](07_memory-and-host-access.md#wpr-and-frts-layout).
  There is no handle for either, and the register-op path stays at the caller's
  level.
- The FEAT write. The PLM drops it.
- A selector copy. The SM error state and the readable client buffers held none
  in the scanned windows
  ([the scan](../experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path)).

## Evidence map

| Fact | Experiment or tool |
|---|---|
| Class exposure and allocation shape | [the class record](../experiments/10_debugger-class-and-fecs-ucode.md#101-the-class-is-exposed-and-allocatable) |
| Register spaces, FEAT read, dropped write | [the context record](../experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read), [the write test](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it) |
| Command census, scoping, readable objects | [the census](../experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path) |
| Probe and run steps | [the debugger-class tool](../tools/debugger-class/) |
| PLM and privilege levels | [privilege and rate control](02_privilege-and-rate-control.md#privilege-levels-and-the-plm) |
| NV status codes | [errors and logging](08_errors-and-logging.md#nv-status-codes) |
