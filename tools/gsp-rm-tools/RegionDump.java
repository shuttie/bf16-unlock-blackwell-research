// Dump every defined instruction in a region as TSV: addr<TAB>bytes<TAB>mnemonic
// Also reports undefined gaps so data islands are visible.
// Args: 0=out.tsv 1=start 2=end

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;

import java.io.PrintWriter;

public class RegionDump extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter out = new PrintWriter(a[0]);
        Address lo = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(a[1].trim());
        Address hi = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(a[2].trim());
        // brute-force disassembly first: same session, so results persist for the dump
        int made = 0, had = 0, failed = 0;
        for (Address a2 = lo; a2.compareTo(hi) < 0; a2 = a2.add(2)) {
            if (currentProgram.getListing().getInstructionAt(a2) != null) { had++; continue; }
            try {
                disassemble(a2);
                if (currentProgram.getListing().getInstructionAt(a2) != null) made++; else failed++;
            } catch (Exception e) { failed++; }
        }
        println(String.format("disasm pass: had=%d made=%d failed=%d", had, made, failed));
        InstructionIterator it = currentProgram.getListing().getInstructions(lo, true);
        Address prevEnd = lo;
        while (it.hasNext()) {
            Instruction insn = it.next();
            if (insn.getAddress().compareTo(hi) >= 0) break;
            if (insn.getAddress().compareTo(prevEnd) > 0) {
                out.printf("%s\tGAP\t%d%n", prevEnd, insn.getAddress().subtract(prevEnd));
            }
            out.printf("%s\t%s\t%s%n", insn.getAddress(),
                    java.util.HexFormat.of().formatHex(insn.getBytes()),
                    insn.toString());
            prevEnd = insn.getMaxAddress().add(1);
        }
        out.close();
        println("dumped " + a[0]);
    }
}
