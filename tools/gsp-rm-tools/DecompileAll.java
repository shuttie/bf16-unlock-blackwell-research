// Decompile every function in the current program to a single C file.
// Args:
//   0: output file path
//   1: max functions (0 = all)
//   2: per-function decompile timeout seconds (default 60)
// Optional environment is not used; output is deterministic by function order.

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompileAll extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outPath = args.length > 0 ? args[0] : "decompiled.c";
        long maxFunctions = args.length > 1 ? Long.parseLong(args[1]) : 0L;
        int timeoutSeconds = args.length > 2 ? Integer.parseInt(args[2]) : 60;

        File outFile = new File(outPath);
        File parent = outFile.getAbsoluteFile().getParentFile();
        if (parent != null) {
            parent.mkdirs();
        }

        PrintWriter out = new PrintWriter(new BufferedWriter(new FileWriter(outFile), 1 << 20));
        PrintWriter index = new PrintWriter(new BufferedWriter(
                new FileWriter(outPath + ".index.csv"), 1 << 20));
        index.println("address,name,size,status,chars");

        DecompInterface decompiler = new DecompInterface();
        DecompileOptions options = new DecompileOptions();
        decompiler.setOptions(options);
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(true);
        decompiler.setSimplificationStyle("decompile");

        if (!decompiler.openProgram(currentProgram)) {
            throw new RuntimeException("decompiler could not open program");
        }

        FunctionManager functions = currentProgram.getFunctionManager();
        long total = functions.getFunctionCount();
        long seen = 0;
        long ok = 0;
        long failed = 0;
        long skippedExternal = 0;

        out.println("/* GSP firmware decompilation");
        out.println(" * program: " + currentProgram.getName());
        out.println(" * image base: " + currentProgram.getImageBase());
        out.println(" * functions: " + total);
        out.println(" */");
        out.println();

        for (Function function : functions.getFunctions(true)) {
            if (monitor.isCancelled()) {
                println("cancelled by monitor");
                break;
            }
            if (maxFunctions > 0 && seen >= maxFunctions) {
                break;
            }
            if (function.isExternal()) {
                skippedExternal++;
                continue;
            }

            seen++;
            String entry = function.getEntryPoint().toString();
            long size = function.getBody().getNumAddresses();
            String code = null;
            String status;

            try {
                DecompileResults result = decompiler.decompileFunction(
                        function, timeoutSeconds, monitor);
                if (result != null && result.decompileCompleted()
                        && result.getDecompiledFunction() != null) {
                    code = result.getDecompiledFunction().getC();
                    status = "ok";
                    ok++;
                } else {
                    status = "failed:" + (result == null ? "null" : result.getErrorMessage());
                    failed++;
                }
            } catch (Exception e) {
                status = "exception:" + e.getClass().getSimpleName() + ":" + e.getMessage();
                failed++;
            }

            out.println("/* ==== " + entry + "  " + function.getName() + "  size=0x"
                    + Long.toHexString(size) + " ==== */");
            if (code != null) {
                out.println(code);
            } else {
                out.println("// decompilation " + status);
            }
            out.println();

            index.println(entry + "," + function.getName() + "," + size + ","
                    + status.replace(',', ';') + "," + (code == null ? 0 : code.length()));

            if (seen % 200 == 0) {
                out.flush();
                index.flush();
                println("progress: " + seen + "/" + total + " ok=" + ok + " failed=" + failed);
            }
        }

        out.flush();
        out.close();
        index.flush();
        index.close();
        decompiler.dispose();

        println("DONE seen=" + seen + " ok=" + ok + " failed=" + failed
                + " external=" + skippedExternal + " programTotal=" + total);
        println("output: " + outFile.getAbsolutePath());
    }
}
