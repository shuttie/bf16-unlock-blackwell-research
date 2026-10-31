// Decompile every function using Ghidra's parallel decompiler.
// The worker count is controlled by the headless -max-cpu option.
//
// Args:
//   0: output file path
//   1: max functions (0 = all)
//   2: per-function decompile timeout seconds (default 60)

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.decompiler.DecompiledFunction;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.parallel.DecompileConfigurer;
import ghidra.app.decompiler.parallel.DecompilerCallback;
import ghidra.app.decompiler.parallel.ParallelDecompiler;
import ghidra.program.model.listing.Function;
import ghidra.util.task.TaskMonitor;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

public class ParallelDecompileAll extends GhidraScript {

    private static class Result {
        final String address;
        final String name;
        final long size;
        final String status;
        final String block;

        Result(String address, String name, long size, String status, String block) {
            this.address = address;
            this.name = name;
            this.size = size;
            this.status = status;
            this.block = block;
        }
    }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outPath = args.length > 0 ? args[0] : "decompiled.c";
        int maxFunctions = args.length > 1 ? Integer.parseInt(args[1]) : 0;
        int timeoutSeconds = args.length > 2 ? Integer.parseInt(args[2]) : 60;

        List<Function> functions = new ArrayList<>();
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            if (function.isExternal()) {
                continue;
            }
            functions.add(function);
            if (maxFunctions > 0 && functions.size() >= maxFunctions) {
                break;
            }
        }
        println("functions to decompile: " + functions.size());

        DecompileConfigurer configurer = new DecompileConfigurer() {
            @Override
            public void configure(DecompInterface decompiler) {
                DecompileOptions options = new DecompileOptions();
                decompiler.setOptions(options);
                decompiler.toggleCCode(true);
                decompiler.toggleSyntaxTree(true);
                decompiler.setSimplificationStyle("decompile");
            }
        };

        DecompilerCallback<Result> callback = new DecompilerCallback<Result>(currentProgram, configurer) {
            @Override
            public Result process(DecompileResults results, TaskMonitor monitor) {
                if (results == null) {
                    return new Result("?", "?", 0, "null",
                            "/* ==== unknown : decompiler returned null ==== */\n\n");
                }

                Function function = results.getFunction();
                String address = function.getEntryPoint().toString();
                String name = function.getName();
                long size = function.getBody().getNumAddresses();
                String status;
                String code = null;

                if (results.decompileCompleted()) {
                    DecompiledFunction decompiled = results.getDecompiledFunction();
                    if (decompiled != null) {
                        code = decompiled.getC();
                        status = "ok";
                    } else {
                        status = "failed:no-decompiled-function";
                    }
                } else {
                    status = "failed:" + results.getErrorMessage();
                }

                String block = "/* ==== " + address + "  " + name
                        + "  size=0x" + Long.toHexString(size) + " ==== */\n"
                        + (code != null ? code : "// decompilation " + status)
                        + "\n\n";
                return new Result(address, name, size, status, block);
            }
        };
        callback.setTimeout(timeoutSeconds);

        File outFile = new File(outPath);
        File parent = outFile.getAbsoluteFile().getParentFile();
        if (parent != null) {
            parent.mkdirs();
        }
        PrintWriter out = new PrintWriter(new BufferedWriter(new FileWriter(outFile), 1 << 20));
        PrintWriter index = new PrintWriter(new BufferedWriter(
                new FileWriter(outPath + ".index.csv"), 1 << 20));
        index.println("address,name,size,status,chars");

        Object lock = new Object();
        AtomicLong count = new AtomicLong();
        AtomicLong ok = new AtomicLong();
        AtomicLong failed = new AtomicLong();

        out.println("/* GSP firmware decompilation (parallel)");
        out.println(" * program: " + currentProgram.getName());
        out.println(" * functions: " + functions.size());
        out.println(" */");
        out.println();

        ParallelDecompiler.decompileFunctions(callback, currentProgram, functions.iterator(),
                result -> {
                    synchronized (lock) {
                        out.print(result.block);
                        index.println(result.address + "," + result.name + "," + result.size + ","
                                + result.status.replace(',', ';') + ","
                                + (result.status.equals("ok")
                                        ? result.block.length() - result.address.length()
                                        : 0));
                        long done = count.incrementAndGet();
                        if (result.status.equals("ok")) {
                            ok.incrementAndGet();
                        } else {
                            failed.incrementAndGet();
                        }
                        if (done % 500 == 0) {
                            out.flush();
                            index.flush();
                            println("progress: " + done + "/" + functions.size()
                                    + " ok=" + ok.get() + " failed=" + failed.get());
                        }
                    }
                }, monitor);

        out.flush();
        out.close();
        index.flush();
        index.close();
        callback.dispose();

        println("DONE seen=" + count.get() + " ok=" + ok.get() + " failed=" + failed.get()
                + " of " + functions.size());
        println("output: " + outFile.getAbsolutePath());
    }
}
