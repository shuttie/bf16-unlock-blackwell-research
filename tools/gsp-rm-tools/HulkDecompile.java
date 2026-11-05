// One-shot disassembly + function creation + decompilation for the FWSEC-LIC
// handler region. The gsp_full project is opened read-only, so all analysis
// must be produced and written to disk within this single run.
//
// Args:
//   0: output file path
//   1: region start (hex)
//   2: region end (hex, exclusive)
//   3: comma-separated extra function-start candidates (may be empty)

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.symbol.SourceType;

import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.TreeSet;

public class HulkDecompile extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        PrintWriter out = new PrintWriter(new BufferedWriter(
                new FileWriter(args[0]), 1 << 20));
        Address lo = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(args[1].trim());
        Address hi = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(args[2].trim());

        // 1. brute-force disassembly: every 2-byte boundary in the region
        long t0 = System.currentTimeMillis();
        int made = 0, had = 0, failed = 0;
        for (Address a = lo; a.compareTo(hi) < 0; a = a.add(2)) {
            if (monitor.isCancelled()) break;
            if (currentProgram.getListing().getInstructionAt(a) != null) { had++; continue; }
            try {
                disassemble(a);
                if (currentProgram.getListing().getInstructionAt(a) != null) made++; else failed++;
            } catch (Exception e) {
                failed++;
            }
        }
        println(String.format("disasm pass: had=%d made=%d failed=%d in %d ms",
                had, made, failed, System.currentTimeMillis() - t0));
        out.printf("/* disasm pass: had=%d made=%d failed=%d */%n", had, made, failed);

        // 2. collect function-start candidates:
        //    a) extra candidates from args
        //    b) instructions that follow a return (c.ret / jalr ra) or a
        //       register-indirect tail jump (jr via t1) within the region
        //    c) JAL targets into the region are included via (a) by caller
        Set<Address> cands = new LinkedHashSet<>();
        if (args.length > 3 && !args[3].isEmpty()) {
            for (String s : args[3].split(",")) {
                if (!s.trim().isEmpty())
                    cands.add(currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(s.trim()));
            }
        }
        InstructionIterator it = currentProgram.getListing().getInstructions(lo, true);
        while (it.hasNext()) {
            Instruction insn = it.next();
            if (insn.getAddress().compareTo(hi) >= 0) break;
            String m = insn.getMnemonicString();
            boolean term = m.equals("ret")
                    || (m.equals("jalr") && insn.getAddress().add(insn.getLength()).compareTo(hi) < 0
                        && insn.toString().contains("ra") && !insn.toString().startsWith("jalr ra"));
            // treat any unconditional j/jr that is not a call as a block end too
            Address next = insn.getMaxAddress().add(1);
            if (next.compareTo(hi) < 0 && (term || m.equals("ret"))) {
                cands.add(next);
            }
        }
        println("candidates: " + cands.size());

        // 3. create functions
        FunctionManager fm = currentProgram.getFunctionManager();
        Set<Function> funcs = new java.util.TreeSet<>((x, y) -> x.getEntryPoint().compareTo(y.getEntryPoint()));
        int created = 0;
        for (Address a : new TreeSet<>(cands)) {
            Function f = fm.getFunctionAt(a);
            if (f == null) {
                f = createFunction(a, null);
                if (f != null) created++;
            }
            if (f != null) funcs.add(f);
        }
        // also pull any pre-existing functions overlapping the region
        for (Function f : fm.getFunctions(lo, true)) {
            if (f.getEntryPoint().compareTo(hi) >= 0) break;
            funcs.add(f);
        }
        println("functions: " + funcs.size() + " (created " + created + ")");

        // 4. decompile all
        DecompInterface decompiler = new DecompInterface();
        decompiler.setOptions(new DecompileOptions());
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(true);
        decompiler.setSimplificationStyle("decompile");
        if (!decompiler.openProgram(currentProgram))
            throw new RuntimeException("decompiler could not open program");
        int ok = 0, bad = 0;
        for (Function f : funcs) {
            out.printf("/* ==== %s  %s  size=0x%x  callers=%d ==== */%n",
                    f.getEntryPoint(), f.getName(), f.getBody().getNumAddresses(),
                    f.getCallingFunctions(monitor).size());
            try {
                DecompileResults res = decompiler.decompileFunction(f, 180, monitor);
                if (res != null && res.decompileCompleted()) {
                    out.println(res.getDecompiledFunction().getC());
                    ok++;
                } else {
                    out.printf("/* decompile failed: %s */%n",
                            res == null ? "null" : res.getErrorMessage());
                    bad++;
                }
            } catch (Exception ex) {
                out.printf("/* exception: %s */%n", ex);
                bad++;
            }
        }
        out.printf("/* decompiled ok=%d failed=%d of %d */%n", ok, bad, funcs.size());
        println("decompiled ok=" + ok + " failed=" + bad);
        decompiler.dispose();
        out.close();
    }
}
