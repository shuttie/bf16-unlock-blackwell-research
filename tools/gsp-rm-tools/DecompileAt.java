// Decompile specific addresses (creating functions if needed) and optionally
// follow callees to a given depth.
// Args:
//   0: output file path
//   1: comma-separated hex addresses
//   2: callee depth (default 1)
//   3: per-function decompile timeout seconds (default 120)

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.SourceType;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

public class DecompileAt extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        File outFile = new File(args[0]);
        String[] addrs = args[1].split(",");
        int depth = args.length > 2 ? Integer.parseInt(args[2]) : 1;
        int timeoutSeconds = args.length > 3 ? Integer.parseInt(args[3]) : 120;

        DecompInterface decompiler = new DecompInterface();
        DecompileOptions options = new DecompileOptions();
        decompiler.setOptions(options);
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(true);
        decompiler.setSimplificationStyle("decompile");
        if (!decompiler.openProgram(currentProgram)) {
            throw new RuntimeException("decompiler could not open program");
        }
        FunctionManager fm = currentProgram.getFunctionManager();
        Map<Address, Function> targets = new LinkedHashMap<>();
        ArrayDeque<Object[]> queue = new ArrayDeque<>();
        for (String s : addrs) {
            queue.add(new Object[]{currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(s.trim()), 0});
        }

        try (PrintWriter out = new PrintWriter(new BufferedWriter(new FileWriter(outFile), 1 << 20))) {
            while (!queue.isEmpty()) {
                Object[] item = queue.removeFirst();
                Address addr = (Address) item[0];
                int level = (Integer) item[1];
                if (targets.containsKey(addr)) {
                    continue;
                }
                Function f = fm.getFunctionAt(addr);
                if (f == null) {
                    // make sure instructions exist first
                    if (currentProgram.getListing().getInstructionAt(addr) == null) {
                        disassemble(addr);
                    }
                    f = createFunction(addr, null);
                }
                if (f == null) {
                    out.printf("/* no function at %s */%n", addr);
                    continue;
                }
                targets.put(addr, f);
                if (level < depth) {
                    for (Function callee : f.getCalledFunctions(monitor)) {
                        queue.add(new Object[]{callee.getEntryPoint(), level + 1});
                    }
                }
            }

            for (Map.Entry<Address, Function> e : targets.entrySet()) {
                Function f = e.getValue();
                out.printf("/* ==== %s  %s  size=0x%x  callers=%d ==== */%n",
                        f.getEntryPoint(), f.getName(), f.getBody().getNumAddresses(),
                        f.getCallingFunctions(monitor).size());
                try {
                    DecompileResults res = decompiler.decompileFunction(f, timeoutSeconds, monitor);
                    if (res != null && res.decompileCompleted()) {
                        out.println(res.getDecompiledFunction().getC());
                    } else {
                        out.printf("/* decompile failed: %s */%n",
                                res == null ? "null" : res.getErrorMessage());
                    }
                } catch (Exception ex) {
                    out.printf("/* exception: %s */%n", ex);
                }
            }
        } finally {
            decompiler.dispose();
        }
        println("wrote " + outFile);
    }
}
